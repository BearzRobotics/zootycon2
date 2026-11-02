//! The interactive zoo: a world you can look at, change with build tools and
//! save, with the simulation running in it.
//!
//! Controls (also shown in the window title):
//!   right-drag orbit, wheel zoom, WASD pan, Esc quit
//!   1 select (Delete/X removes)   2 place object   3 fence line   4 paths
//!   5 raise terrain   6 lower terrain   7 flatten   8 place animal/guest
//!   [ ]  previous/next item (hold Shift to jump ten)   R rotate (Shift: back)
//!   Tab pause simulation   , . slower/faster   Z undo
//!   F5 save   F9 load the last save

const std = @import("std");
const Io = std.Io;
const viewer = @import("viewer.zig");
const world_mod = @import("world.zig");
const sim_mod = @import("sim.zig");
const entity = @import("entity.zig");
const platform = @import("platform.zig");
const map_mod = @import("map.zig");
const terrain_mod = @import("terrain.zig");
const environment = @import("environment.zig");
const xml = @import("xml.zig");
const audio_mod = @import("audio.zig");
const uilayout = @import("uilayout.zig");
const ai = @import("ai.zig");
const vfs_mod = @import("vfs.zig");
const scenario_mod = @import("scenario.zig");
const loc_mod = @import("loc.zig");
const uistate = @import("uistate.zig");

const Mat4 = viewer.Mat4;

// SDL scancodes used by the tools.
const sc = struct {
    const c: u32 = 6;
    const g: u32 = 10;
    const p: u32 = 19;
    const r: u32 = 21;
    const x: u32 = 27;
    const z: u32 = 29;
    const k1: u32 = 30;
    const k8: u32 = 37;
    const k9: u32 = 38;
    const f: u32 = 9;
    const tab: u32 = 43;
    const lbracket: u32 = 47;
    const rbracket: u32 = 48;
    const comma: u32 = 54;
    const period: u32 = 55;
    const t: u32 = 23;
    const m: u32 = 16;
    const o: u32 = 18;
    const b: u32 = 5;
    const i: u32 = 12;
    const esc: u32 = 41;
    const f1: u32 = 58;
    const f2: u32 = 59;
    const f3: u32 = 60;
    const f5: u32 = 62;
    const f9: u32 = 66;
    const f10: u32 = 67;
    const delete: u32 = 76;
    const lshift: u32 = 225;
    const rshift: u32 = 229;
};

pub const Tool = enum {
    select,
    prop,
    fence,
    path,
    raise,
    lower,
    flatten,
    cliff,
    ditch,
    smooth,
    actor,
    food,
    /// Any entity from the buy panel's item tabs (buildings, scenery, toys, shelters, plants...).
    item,

    fn label(self: Tool) []const u8 {
        return switch (self) {
            .select => "select",
            .prop => "place object",
            .fence => "fence line",
            .path => "paths",
            .raise => "raise terrain",
            .lower => "lower terrain",
            .flatten => "flatten terrain",
            .cliff => "raise a cliff",
            .ditch => "dig a ditch",
            .smooth => "smooth terrain",
            .actor => "place animal/guest",
            .food => "place food or water",
            .item => "place item",
        };
    }
};

/// A clickable rectangle in pixel coordinates.
const Hit = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    action: union(enum) { tool: Tool, pick: usize, none, menu: MenuAction, entry: usize, buy_cat: u8, buy_tab: BuyTab, buy_item: usize, info_tab: u8, del_save: usize, status_tab: u8 },
};

/// A short message in the top message bar.
const Alert = struct {
    text: [72]u8 = undefined,
    len: usize = 0,
    /// 0 normal, 1 good, 2 bad.
    kind: u8 = 0,
    t: f64 = -1000,
};

/// Tabs of the buy panel, as in the game's own panel.
pub const BuyTab = enum { fence, path, building, scenery, animal, food, staff, deform, enrich, shelter, tree, plant, rock };

/// Which full-screen menu is open (if any).
/// One scenario of a campaign, from `scenario/campaign/*.xml`.
const CampEntry = struct {
    name: []const u8,
    key: []const u8,
    scenario: []const u8,
    map: []const u8,
    cash: f64,
    description: []const u8,
    /// The campaign file starts it unlocked.
    open: bool,
};

const Campaign = struct {
    name: []const u8,
    tutorial: bool,
    entries: []const CampEntry,
};

const Menu = enum { none, result, pause, maps, saves, settings, finances, new_zoo, save_as, main, goals, campaigns, scenarios };

const MenuAction = enum {
    close_menu,
    save,
    open_saves,
    open_maps,
    open_settings,
    open_finances,
    open_goals,
    open_challenge,
    challenge_accept,
    challenge_decline,
    tutorial_continue,
    gender_male,
    gender_female,
    open_campaigns,
    open_pause,
    toggle_pause,
    undo,
    zoom_in,
    zoom_out,
    rot_left,
    rot_right,
    toggle_hud,
    open_new_zoo,
    open_save_as,
    open_main,
    price_up,
    price_down,
    open_status,
    confirm_save_as,
    new_zoo_size,
    new_zoo_biome,
    new_zoo_start,
    ui_size,
    toggle_delete,
    close_selection,
    track_camera,
    back,
    quit,
    toggle_help,
    toggle_arrivals,
    toggle_clock,
    toggle_sound,
    toggle_modern,
    toggle_shadows,
    toggle_ssao,
    toggle_bloom,
    toggle_fxaa,
    speed_up,
    speed_down,
    delete_selected,
    refill_selected,
};

const SelKind = enum { prop, fence, path, actor };
const Sel = struct { kind: SelKind, id: u32 };

/// Something the undo key can reverse.
const UndoOp = union(enum) {
    /// Remove records that were added.
    added: struct { ids: []u32, cost: f64 },
    /// Put back a removed record.
    removed_prop: world_mod.Prop,
    removed_fence: world_mod.Fence,
    removed_path: world_mod.PathTile,
    removed_actor: world_mod.Actor,
};

pub const Options = struct {
    viewer: viewer.Options = .{},
    /// Build tools on (otherwise it is a viewer with the simulation).
    tools: bool = true,
    sim: bool = true,
    seed: u64 = 1,
    /// Time of day to start at (0..1; 0.42 is noon) and whether it advances.
    tod: f32 = 0.42,
    tod_auto: bool = false,
    /// Directory saves are written to.
    save_dir: []const u8,
    /// Turn on the optional modern rendering features.
    modern: bool = false,
    no_shadows: bool = false,
    no_post: bool = false,
    no_sound: bool = false,
    /// Open the map picker at startup (no map was named on the command line).
    pick_map: bool = false,
    /// Build commands run at startup, separated by `;` (for tests and demos):
    ///   prop X Y | actor X Y | path X Y | fence X1 Y1 X2 Y2 | raise X Y SECS
    ///   lower X Y SECS | flatten X Y SECS | delete X Y | undo | save | load
    ///   wait SECS | propname TEXT | actorname NAME | fencekind NAME | yaw RAD
    script: []const u8 = "",
    /// Goals file of a scenario to play on the loaded map.
    scenario: []const u8 = "",
    scenario_log: bool = false,
    /// Virtual mouse and keyboard, played through the real event queue one
    /// action per frame, separated by `;`:
    ///   move X Y        pointer to window position
    ///   at X Y [Z]      pointer over a world position (Z defaults to the ground)
    ///   down|up|click [BUTTON]   mouse button (1 left, 3 right; default 1)
    ///   key NAME | keydown NAME | keyup NAME     (a-z, 0-9, tab, delete, f5, f9, [ ] , . shift)
    ///   wheel N         scroll
    ///   wait FRAMES     pause the script
    ///   cam YAW PITCH DIST [CX CY]   set the camera
    ///   info            print tool, counts and selection
    ///   shot            capture the screenshot now
    ///   quit
    /// If the script finishes and a screenshot was requested, it is taken.
    input: []const u8 = "",
};

pub const App = struct {
    gpa: std.mem.Allocator,
    io: Io,
    vfs: *vfs_mod.Vfs,
    gfx: *viewer.Gfx,
    scene: *viewer.Scene,
    world: world_mod.World,
    reg: entity.Registry,
    sim: sim_mod.Sim,
    look: viewer.TerrainLook,
    opts: Options,

    env: ?environment.Environment = null,
    tod: f32 = 0.42,
    tod_auto: bool = false,
    /// Real seconds per simulated day when the clock runs.
    day_len: f32 = 480,

    synced_rev: u32 = std.math.maxInt(u32),
    synced_actor_rev: u32 = std.math.maxInt(u32),
    synced_terrain_rev: u32 = std.math.maxInt(u32),
    last_terrain_secs: f32 = -1,

    // Instance bookkeeping: instance i shows actor `actor_ids[i]`.
    actor_ids: std.ArrayList(u32) = .empty,
    actor_scales: std.ArrayList(f32) = .empty,
    inst_anim: std.ArrayList([]const u8) = .empty,
    /// Behaviour data per species (null when none loads), keyed by species.
    ai_libs: std.StringHashMapUnmanaged(*ai.Library) = .empty,
    actor_defs: std.StringHashMapUnmanaged(?viewer.ActorModel) = .empty,

    // Tool state.
    tool: Tool = .select,
    hover: ?[3]f32 = null,
    selected: ?Sel = null,
    yaw: f32 = 0,
    fence_start: ?[2]f32 = null,
    lmb: bool = false,
    shift: bool = false,
    flatten_to: f32 = 0,
    brush_touched: bool = false,
    brush_center: [2]f32 = .{ 0, 0 },
    paused: bool = false,
    show_help: bool = true,
    speed: f32 = 1.0,
    message: [96]u8 = undefined,
    message_len: usize = 0,
    title_dirty: bool = true,
    undo: std.ArrayList(UndoOp) = .empty,

    // Menus.
    menu: Menu = .none,
    /// First visible row of a list menu.
    menu_first: usize = 0,
    /// Maps in the game data (paths) and their display names.
    map_paths: std.ArrayList([]const u8) = .empty,
    map_labels: std.ArrayList([]const u8) = .empty,
    /// Saves found on disk (full paths) and their names.
    save_paths: std.ArrayList([]const u8) = .empty,
    /// "3 HOURS AGO  1.2 MB" for each save, and the save awaiting delete confirmation.
    save_info: std.ArrayList([]const u8) = .empty,
    confirm_delete: ?usize = null,
    save_labels: std.ArrayList([]const u8) = .empty,
    save_arena: std.heap.ArenaAllocator,
    reset_camera: bool = false,
    /// Where a new zoo's camera looks (the entrance) instead of the map middle.
    start_focus: ?[2]f32 = null,
    /// Rows of a list menu that fit on screen (set when drawing).
    menu_rows: usize = 8,

    // Clickable interface, rebuilt each frame by `overlay`.
    hits: std.ArrayList(Hit) = .empty,
    feeder_state: u64 = 0,
    /// Zoo fame in stars (fractional); see updateFame.
    fame: f32 = 1,
    /// The next zoo started is a Challenge Mode zoo.
    challenge_next: bool = false,
    /// Canvas scale and offset of the last HUD draw (UI rects are kept in canvas units).
    cv_scale: f32 = 0,
    cv_off: [2]f32 = .{ 0, 0 },
    /// Scenario goals: localized strings and the running goal tree.
    strings: ?loc_mod.Loc = null,
    scen: ?*scenario_mod.Manager = null,
    /// State of UI nodes that scenario scripts read and drive.
    ui_state: ?uistate.State = null,
    /// Key of the campaign scenario being played (for saving progress).
    scen_key: [64]u8 = undefined,
    scen_key_len: usize = 0,
    /// The goal the player has been on, and since when (to offer a skip in tutorials).
    scen_tutorial: bool = false,
    breed_acc: f32 = 0,
    hint_node: ?*const scenario_mod.Node = null,
    hint_since: f64 = 0,
    /// The outcome already announced for the running scenario's goals.
    scen_result: scenario_mod.Outcome = .running,
    camp_arena: std.heap.ArenaAllocator = undefined,
    camp_ready: bool = false,
    campaigns: std.ArrayList(Campaign) = .empty,
    camp_labels: std.ArrayList([]const u8) = .empty,
    scen_labels: std.ArrayList([]const u8) = .empty,
    camp_sel: usize = 0,
    /// Keys of finished scenarios.
    done_keys: std.StringHashMapUnmanaged(void) = .empty,
    over_ui: bool = false,

    // Virtual input.
    input_cmds: std.ArrayList([]const u8) = .empty,
    input_i: usize = 0,
    wait_frames: u32 = 0,
    vmouse: [2]f32 = .{ 0, 0 },

    // Catalogs.
    props: std.ArrayList([]const u8) = .empty,
    prop_i: usize = 0,
    fence_kinds: std.ArrayList([]const u8) = .empty,
    fence_i: usize = 0,
    path_textures: std.ArrayList([]const u8) = .empty,
    path_i: usize = 0,
    actor_names: std.ArrayList([]const u8) = .empty,
    actor_i: usize = 0,
    /// Entity names visitors are made from (adults and children with a model).
    guest_names: std.ArrayList([]const u8) = .empty,
    /// Food and water containers (entity names) and the chosen one.
    food_names: std.ArrayList([]const u8) = .empty,
    food_i: usize = 0,
    /// Entity names whose task files are already in the animal libraries.
    food_loaded: std.StringHashMapUnmanaged(void) = .empty,
    chains: std.StringHashMapUnmanaged([]const *const entity.Binder) = .empty,
    arrivals_on: bool = true,
    /// From `ai/guestmgr.xml`: the visitor cap is base + per_star * stars.
    guests_base: f32 = 30,
    guests_per_star: f32 = 20,
    catalog_arena: std.heap.ArenaAllocator,
    /// Sound, created after the app so it can borrow the data files.
    audio: ?audio_mod.Engine = null,
    audio_biome_dirty: bool = true,
    /// The game's own HUD, drawn from its layout files.
    hud: ?struct { shell: uilayout.Layout, bucks: ?uilayout.Layout, info: ?uilayout.Layout = null, status: ?uilayout.Layout = null, mainmenu: ?uilayout.Layout = null, tutorial: ?uilayout.Layout = null, goals: ?uilayout.Layout = null } = null,
    hud_on: bool = true,
    /// A name the player gave the zoo's save (empty: derived from the map).
    custom_name: [48]u8 = undefined,
    custom_len: usize = 0,
    /// Text being typed on the save screen.
    name_buf: [40]u8 = undefined,
    name_len: usize = 0,
    blink: u32 = 0,
    status_tab: u8 = 1,
    /// The menus were opened from the main menu, so Back returns to it.
    in_main: bool = false,
    main_hover: []const u8 = "",
    app_time: f64 = 0,
    alerts: [4]Alert = @splat(.{}),
    alert_cool: [8]f64 = @splat(-1000),
    alert_check: f64 = 0,
    last_stars: f32 = 0,
    last_months: u32 = 0,
    cur_ctx: ?*viewer.FrameCtx = null,
    nz_size: u8 = 1,
    nz_biome: u8 = 6,
    /// Interface size multiplier (settings: UI SIZE).
    ui_zoom: f32 = 1.0,
    delete_mode: bool = false,
    hud_text: [64]u8 = undefined,
    /// The buy panel: which main category is open (0 construction, 1 animals,
    /// 2 terraform, 3 staff; null = closed), its tab, and scroll position.
    buy_cat: ?u8 = null,
    buy_tab: BuyTab = .fence,
    buy_scroll: usize = 0,
    /// Animal tab shows females (otherwise males).
    buy_female: bool = false,
    buy_rect: [4]f32 = .{ 0, 0, 0, 0 },
    buy_lists: [13]std.ArrayList(u32) = @splat(.empty),
    /// Every entity offered on the item tabs, by name; lists hold indices into this.
    item_names: std.ArrayList([]const u8) = .empty,
    item_sel: usize = 0,
    /// Item icon files by name (`lion_adult_f` -> .../lion_adult_f_icon.dds).
    icons: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The game's entity info panel: which tab, whether it drew this frame,
    /// and an entity the camera follows.
    info_tab: u8 = 0,
    info_drawn: bool = false,
    track_id: ?u32 = null,
    buy_hover: ?struct { tab: BuyTab, pos: usize } = null,

    pub fn deinit(self: *App) void {
        if (self.audio) |*a| a.deinit();
        for (&self.buy_lists) |*l| l.deinit(self.gpa);
        self.item_names.deinit(self.gpa);
        self.icons.deinit(self.gpa);
        if (self.hud) |*h| {
            h.shell.deinit();
            if (h.bucks) |*b| b.deinit();
            if (h.info) |*b| b.deinit();
            if (h.status) |*b| b.deinit();
            if (h.mainmenu) |*b| b.deinit();
        }
        for (self.undo.items) |op| if (op == .added) self.gpa.free(op.added.ids);
        self.undo.deinit(self.gpa);
        self.input_cmds.deinit(self.gpa);
        self.hits.deinit(self.gpa);
        self.map_paths.deinit(self.gpa);
        self.map_labels.deinit(self.gpa);
        self.save_paths.deinit(self.gpa);
        self.save_info.deinit(self.gpa);
        self.save_labels.deinit(self.gpa);
        self.save_arena.deinit();
        self.props.deinit(self.gpa);
        self.fence_kinds.deinit(self.gpa);
        self.path_textures.deinit(self.gpa);
        self.actor_names.deinit(self.gpa);
        self.guest_names.deinit(self.gpa);
        self.food_names.deinit(self.gpa);
        if (self.scen) |m| m.destroy();
        if (self.ui_state) |*u| u.deinit();
        if (self.camp_ready) {
            self.campaigns.deinit(self.gpa);
            self.camp_labels.deinit(self.gpa);
            self.scen_labels.deinit(self.gpa);
            self.done_keys.deinit(self.gpa);
            self.camp_arena.deinit();
        }
        if (self.strings) |*st| st.deinit();
        var fl = self.food_loaded.keyIterator();
        while (fl.next()) |k| self.gpa.free(k.*);
        self.food_loaded.deinit(self.gpa);
        var ch = self.chains.iterator();
        while (ch.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.chains.deinit(self.gpa);
        self.catalog_arena.deinit();
        var it = self.actor_defs.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.actor_defs.deinit(self.gpa);
        self.actor_ids.deinit(self.gpa);
        self.actor_scales.deinit(self.gpa);
        self.inst_anim.deinit(self.gpa);
        var lit = self.ai_libs.iterator();
        while (lit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.*.deinit();
            self.gpa.destroy(e.value_ptr.*);
        }
        self.ai_libs.deinit(self.gpa);
        self.sim.deinit();
        if (self.env) |*e| e.deinit();
        self.look.deinit(self.gpa);
        self.reg.deinit();
        self.world.deinit();
    }

    fn say(self: *App, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.message, fmt, args) catch self.message[0..0];
        self.message_len = text.len;
        self.title_dirty = true;
        std.debug.print("{s}\n", .{text});
    }

    // ------------------------------------------------------------ catalogs

    const Scan = struct {
        app: *App,
        fn add(self: Scan, path: []const u8) anyerror!void {
            const a = self.app;
            const ca = a.catalog_arena.allocator();
            if (std.mem.startsWith(u8, path, "entities/") and std.mem.endsWith(u8, path, "_icon.dds")) {
                const base = std.fs.path.basename(path);
                try a.icons.put(a.gpa, try ca.dupe(u8, base[0 .. base.len - 9]), try ca.dupe(u8, path));
                return;
            }
            if (std.mem.startsWith(u8, path, "entities/objects/") and std.mem.endsWith(u8, path, ".nif")) {
                const dirs = [_][]const u8{ "foliage/", "rocks/", "scenery/", "buildings/", "shelters/", "items/", "enrichment/", "props/" };
                const rest = path["entities/objects/".len..];
                var ok = false;
                for (dirs) |d| if (std.mem.startsWith(u8, rest, d)) {
                    ok = true;
                };
                const skip = [_][]const u8{ "/low/", "docknode", "_tap", "/materials/", "_lod", "turntable", "_dock", "_lo.", "_shadow" };
                for (skip) |s| if (std.mem.indexOf(u8, path, s) != null) {
                    ok = false;
                };
                if (ok) try a.props.append(a.gpa, try ca.dupe(u8, path));
            } else if (std.mem.startsWith(u8, path, "entities/objects/paths/") and std.mem.endsWith(u8, path, "_128.dds")) {
                if (std.mem.indexOf(u8, std.fs.path.basename(path), "path_") != null)
                    try a.path_textures.append(a.gpa, try ca.dupe(u8, path));
            } else if ((std.mem.startsWith(u8, path, "entities/objects/fences/ai/") or std.mem.startsWith(u8, path, "entities/objects/paths/ai/")) and std.mem.endsWith(u8, path, ".xml")) {
                const base = std.fs.path.basename(path);
                const kind = base[0 .. base.len - 4];
                const bad = [_][]const u8{ "broken", "_end", "_mm" };
                var ok = true;
                for (bad) |b| if (std.mem.indexOf(u8, kind, b) != null) {
                    ok = false;
                };
                if (ok) try a.fence_kinds.append(a.gpa, try ca.dupe(u8, kind));
            }
        }
    };

    fn lessStr(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    fn buildCatalogs(self: *App) !void {
        try self.vfs.forEach(Scan{ .app = self }, Scan.add);
        std.mem.sort([]const u8, self.props.items, {}, lessStr);
        std.mem.sort([]const u8, self.fence_kinds.items, {}, lessStr);
        std.mem.sort([]const u8, self.path_textures.items, {}, lessStr);
        const ca = self.catalog_arena.allocator();
        var it = self.reg.binders.valueIterator();
        while (it.next()) |b| {
            const bd = b.*;
            if (bd.abstract) continue;
            var is_actor = false;
            var is_creature = false;
            for (bd.type_path) |t| {
                if (std.ascii.eqlIgnoreCase(t, "actor")) is_actor = true;
                if (std.ascii.eqlIgnoreCase(t, "animal") or std.ascii.eqlIgnoreCase(t, "people")) is_creature = true;
            }
            if (is_actor and is_creature) try self.actor_names.append(self.gpa, try ca.dupe(u8, bd.name));
        }
        std.mem.sort([]const u8, self.actor_names.items, {}, lessStr);
        for (self.actor_names.items) |n| {
            if (!sim_mod.isGuest(n)) continue;
            // Only whole-person guest types (not abstract groups) with a model.
            if (std.mem.indexOf(u8, n, "Adult") == null and std.mem.indexOf(u8, n, "Young") == null) continue;
            if (self.actorDef(n) != null) try self.guest_names.append(self.gpa, n);
        }
        self.sim.guest_binders = self.guest_names.items;
        // Food and water containers that have a model.
        var bit = self.reg.binders.valueIterator();
        while (bit.next()) |b| {
            const bd = b.*;
            if (bd.abstract or (self.feederKind(bd.name) == null and venueNeed(bd) == null)) continue;
            if (viewer.binderModel(self.gpa, &self.reg, bd.name, "mainObj") == null) continue;
            try self.food_names.append(self.gpa, try ca.dupe(u8, bd.name));
        }
        std.mem.sort([]const u8, self.food_names.items, {}, lessStr);
        self.buildBuyLists();
        // Start on a sensible default: the first path texture that is a concrete path.
        for (self.path_textures.items, 0..) |t, i| if (std.mem.indexOf(u8, t, "concrete") != null) {
            self.path_i = i;
            break;
        };
        // A guest first, since they are what the simulation shows best.
        for (self.actor_names.items, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, "Guest_Adult_F_05")) {
            self.actor_i = i;
            break;
        };
        for (self.fence_kinds.items, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, "zoowall")) {
            self.fence_i = i;
            break;
        };
    }

    // --------------------------------------------------------------- sync

    fn actorDef(self: *App, binder: []const u8) ?viewer.ActorModel {
        var buf: [128]u8 = undefined;
        if (binder.len > buf.len) return null;
        const key = std.ascii.lowerString(&buf, binder);
        if (self.actor_defs.get(key)) |c| return c;
        const def = viewer.actorModel(self.gpa, &self.reg, binder);
        const owned = self.gpa.dupe(u8, key) catch return def;
        self.actor_defs.put(self.gpa, owned, def) catch self.gpa.free(owned);
        return def;
    }

    fn propMatrix(p: world_mod.Prop) Mat4 {
        return viewer.fromTransform(.{ .translation = p.position, .rotation = p.rotation, .scale = p.scale });
    }

    fn fenceMatrix(self: *App, f: world_mod.Fence) Mat4 {
        const z0 = self.world.terrain.zAt(f.position[0], f.position[1]);
        const z1 = self.world.terrain.zAt(f.position[0] + @cos(f.rotation) * 3.0, f.position[1] + @sin(f.rotation) * 3.0);
        // Tilt the segment so it follows the ground instead of cutting straight across.
        const alpha = std.math.atan2(z1 - z0, 3.0);
        const c = @cos(f.rotation);
        const sn = @sin(f.rotation);
        const ca = @cos(alpha);
        const sa = @sin(alpha);
        return viewer.fromTransform(.{
            .translation = .{ f.position[0], f.position[1], z0 },
            .rotation = .{ c * ca, -sn, -c * sa, sn * ca, c, -sn * sa, sa, 0, ca },
            .scale = 1,
        });
    }

    /// Rebuilds every static draw from the world.
    fn rebuildStatic(self: *App) !void {
        const scene = self.scene;
        scene.clearStatic();
        for (self.world.props.items) |p| {
            const draws = (try scene.loadModel(self.displayModel(p))) orelse continue;
            try scene.place(draws, propMatrix(p), p.swaps);
        }
        for (self.world.fences.items) |f| {
            const pieces = try scene.fenceModels(f.kind);
            const m = self.fenceMatrix(f);
            if (pieces.segment) |d| try scene.place(d, m, &.{});
            if (pieces.post) |d| try scene.place(d, m, &.{});
        }
        var decals: std.ArrayList(map_mod.PathDecal) = .empty;
        defer decals.deinit(self.gpa);
        for (self.world.paths.items) |p| try decals.append(self.gpa, .{
            .texture = p.texture,
            .position = p.position,
            .width = p.width,
            .height = p.height,
        });
        try scene.addPaths(&self.world.terrain, decals.items);
    }

    fn rebuildActors(self: *App) !void {
        const scene = self.scene;
        scene.clearActors();
        self.actor_ids.clearRetainingCapacity();
        self.actor_scales.clearRetainingCapacity();
        self.inst_anim.clearRetainingCapacity();
        for (self.world.actors.items) |a| {
            const def = self.actorDef(a.binder) orelse continue;
            const m = viewer.fromTransform(.{ .translation = a.position, .rotation = a.rotation, .scale = def.scale });
            const phase = @mod(a.position[0] * 0.37 + a.position[1] * 0.61, 3.0);
            var head: ?viewer.ActorHead = null;
            if (a.head) |h| {
                head = .{ .model = h.model, .yaw = h.yaw, .swaps = h.swaps };
            } else if (viewer.actorHead(self.gpa, &self.reg, a.binder)) |hm| {
                head = .{ .model = hm };
            }
            if (!try scene.addActor(def.file, m, phase, a.swaps, head)) continue;
            try self.actor_ids.append(self.gpa, a.id);
            try self.actor_scales.append(self.gpa, def.scale);
            try self.inst_anim.append(self.gpa, "");
        }
    }

    fn rebuildTerrain(self: *App) !void {
        try self.scene.addTerrain(&self.world.terrain, .{ 1, 1, 1, 1 }, self.look.flat, self.look.steep, self.look.slot_of);
        // On a blank zoo the sea covers the whole map, so dug-out ground fills with water.
        const t = &self.world.terrain;
        if (t.water.len == 1 and t.water[0].verts.len == @as(usize, t.width) * t.height) {
            viewer.waterLook(self.gpa, self.vfs, self.scene, t) catch {};
        }
    }

    fn syncScene(self: *App, secs: f32) !void {
        const statics_changed = self.synced_rev != self.world.revision;
        const actors_changed = self.synced_actor_rev != self.world.actors_revision;
        if (statics_changed) {
            try self.rebuildStatic();
            self.synced_rev = self.world.revision;
        }
        if (statics_changed or actors_changed) {
            try self.rebuildActors();
            try self.sim.sync(&self.world);
            // Match walking speed to the walk animation so feet do not slide.
            for (self.actor_ids.items, 0..) |id, i| {
                const ag = self.sim.agentFor(id) orelse continue;
                if (self.scene.walkSpeed(i)) |sp| ag.speed = sp * self.actor_scales.items[i];
            }
            self.synced_actor_rev = self.world.actors_revision;
            self.loadFoodTasks();
        }
        if (self.synced_terrain_rev != self.world.terrain_revision and secs - self.last_terrain_secs > 0.1) {
            try self.rebuildTerrain();
            self.synced_terrain_rev = self.world.terrain_revision;
            self.last_terrain_secs = secs;
        }
    }

    // --------------------------------------------------------- picking

    fn terrainHit(t: *const terrain_mod.Terrain, origin: [3]f32, dir: [3]f32) ?[3]f32 {
        const step: f32 = 0.5;
        var s: f32 = 0;
        var prev: f32 = 0;
        while (s < 1500) : (s += step) {
            const p = [3]f32{ origin[0] + dir[0] * s, origin[1] + dir[1] * s, origin[2] + dir[2] * s };
            const inside = p[0] >= 0 and p[1] >= 0 and p[0] <= t.world_width and p[1] <= t.world_height;
            if (inside and p[2] <= t.zAt(p[0], p[1])) {
                var lo = prev;
                var hi = s;
                for (0..24) |_| {
                    const mid = (lo + hi) / 2;
                    const q = [3]f32{ origin[0] + dir[0] * mid, origin[1] + dir[1] * mid, origin[2] + dir[2] * mid };
                    if (q[2] <= t.zAt(q[0], q[1])) hi = mid else lo = mid;
                }
                const q = [3]f32{ origin[0] + dir[0] * hi, origin[1] + dir[1] * hi, origin[2] + dir[2] * hi };
                return .{ q[0], q[1], t.zAt(q[0], q[1]) };
            }
            prev = s;
        }
        return null;
    }

    /// Distance along the ray to a sphere, if it is hit.
    fn raySphere(origin: [3]f32, dir: [3]f32, center: [3]f32, r: f32) ?f32 {
        const oc = [3]f32{ origin[0] - center[0], origin[1] - center[1], origin[2] - center[2] };
        const b = oc[0] * dir[0] + oc[1] * dir[1] + oc[2] * dir[2];
        const c = oc[0] * oc[0] + oc[1] * oc[1] + oc[2] * oc[2] - r * r;
        const disc = b * b - c;
        if (disc < 0) return null;
        const t = -b - @sqrt(disc);
        return if (t >= 0) t else null;
    }

    fn pick(self: *App, origin: [3]f32, dir: [3]f32) ?Sel {
        var best: ?Sel = null;
        var best_t: f32 = std.math.inf(f32);
        for (self.world.props.items) |p| {
            const b = self.scene.modelBounds(p.model) orelse .{ 1.0, 2.0 };
            const r = @max(0.9, b[0] * p.scale);
            const h = @max(0.5, b[1] * p.scale);
            const c = [3]f32{ p.position[0], p.position[1], p.position[2] + h / 2 };
            if (raySphere(origin, dir, c, @max(r, h / 2))) |t| if (t < best_t) {
                best_t = t;
                best = .{ .kind = .prop, .id = p.id };
            };
        }
        for (self.world.actors.items) |a| {
            const c = [3]f32{ a.position[0], a.position[1], a.position[2] + 1.0 };
            if (raySphere(origin, dir, c, 1.2)) |t| if (t < best_t) {
                best_t = t;
                best = .{ .kind = .actor, .id = a.id };
            };
        }
        for (self.world.fences.items) |f| {
            const z = self.world.terrain.zAt(f.position[0], f.position[1]);
            const c = [3]f32{ f.position[0] + @cos(f.rotation) * 1.5, f.position[1] + @sin(f.rotation) * 1.5, z + 1.0 };
            if (raySphere(origin, dir, c, 1.4)) |t| if (t < best_t) {
                best_t = t;
                best = .{ .kind = .fence, .id = f.id };
            };
        }
        if (best == null) {
            // Fall back to a path tile under the ground hit.
            if (terrainHit(&self.world.terrain, origin, dir)) |g| {
                var best_d: f32 = 1.6;
                for (self.world.paths.items) |p| {
                    const d = @max(@abs(p.position[0] - g[0]), @abs(p.position[1] - g[1]));
                    if (d < best_d) {
                        best_d = d;
                        best = .{ .kind = .path, .id = p.id };
                    }
                }
            }
        }
        return best;
    }

    // ------------------------------------------------------------- tools

    fn snap(v: f32, grid: f32) f32 {
        return @round(v / grid) * grid;
    }

    fn pushAdded(self: *App, ids: []const u32, cost: f64) void {
        const copy = self.gpa.dupe(u32, ids) catch return;
        self.undo.append(self.gpa, .{ .added = .{ .ids = copy, .cost = cost } }) catch self.gpa.free(copy);
    }

    /// Purchase price of an entity: the `cost` of its `ZTEconomyComponent`
    /// (most specific binder wins), or `fallback` when the data has none.
    fn costOf(self: *App, name: []const u8, fallback: f64) f64 {
        const b = self.reg.get(name) orelse return fallback;
        const ch = self.reg.chain(self.gpa, b) catch return fallback;
        defer self.gpa.free(ch);
        var i = ch.len;
        while (i > 0) {
            i -= 1;
            if (findCost(ch[i].root)) |v| return v;
        }
        return fallback;
    }

    fn findCost(e: *const xml.Element) ?f64 {
        if (std.ascii.eqlIgnoreCase(e.name, "ZTEconomyComponent")) {
            if (e.attr("cost")) |c| return std.fmt.parseFloat(f64, c) catch null;
        }
        for (e.children) |c| if (findCost(c)) |v| return v;
        return null;
    }

    /// Takes `cost` from the budget; refuses (and says so) when it cannot be paid.
    fn charge(self: *App, cost: f64, what: []const u8, cat: sim_mod.Cat) bool {
        if (cost <= 0) return true;
        if (self.sim.zoo.income < cost) {
            self.sfx("noplacement");
            self.say("cannot afford {s}: ${d:.0}, have ${d:.0}", .{ what, cost, self.sim.zoo.income });
            return false;
        }
        self.sim.zoo.spend(cat, cost);
        return true;
    }

    fn soundOn(self: *const App) bool {
        return if (self.audio) |a| a.enabled else false;
    }

    fn toggleSound(self: *App) void {
        const a = &(self.audio orelse return self.say("sound is off (--no-sound)", .{}));
        a.setEnabled(!a.enabled);
        self.audio_biome_dirty = true;
        self.say("sound {s}{s}", .{ if (a.enabled) "on" else "off", if (a.enabled and !a.hasDevice()) " (no audio device)" else "" });
    }

    /// Plays a UI sound tag from the game's `ui/sound/config.xml`.
    fn sfx(self: *App, name: []const u8) void {
        if (self.audio) |*a| _ = a.play(name, null);
    }

    /// The most common natural biome painted on the terrain, for ambience.
    fn dominantBiome(self: *const App) []const u8 {
        const t = &self.world.terrain;
        var counts: [sim_mod.habitat_biomes.len]u32 = @splat(0);
        for (t.paint) |idx| {
            if (idx >= t.biomes.len) continue;
            for (sim_mod.habitat_biomes, 0..) |b, i| if (std.ascii.eqlIgnoreCase(b, t.biomes[idx])) {
                counts[i] += 1;
            };
        }
        var best: usize = 0;
        for (counts, 0..) |c, i| if (c > counts[best]) {
            best = i;
        };
        return sim_mod.habitat_biomes[best];
    }

    fn placeProp(self: *App, at: [3]f32) !void {
        if (self.props.items.len == 0) return;
        const model = self.props.items[self.prop_i];
        if (!self.charge(prop_cost, std.fs.path.basename(model), .construction)) return;
        const id = try self.world.addProp(model, at, world_mod.yawRotation(self.yaw), 1.0, &.{});
        self.pushAdded(&.{id}, prop_cost);
        self.sfx("placement");
        self.say("placed {s} (${d:.0})", .{ std.fs.path.basename(model), prop_cost });
    }

    fn placeActor(self: *App, at: [3]f32) !void {
        if (self.actor_names.items.len == 0) return;
        const name = self.actor_names.items[self.actor_i];
        const def = self.actorDef(name) orelse {
            self.say("{s} has no model", .{name});
            return;
        };
        _ = def;
        const cost = self.costOf(name, 100);
        if (!self.charge(cost, name, if (sim_mod.classify(name) == .person) .staff else .animals)) return;
        const id = try self.world.addActor(name, at, world_mod.yawRotation(self.yaw), &.{});
        self.pushAdded(&.{id}, cost);
        self.sfx("placement");
        self.say("placed {s} (${d:.0})", .{ name, cost });
    }

    /// Places any entity chosen on the buy panel's item tabs: its main model,
    /// its price from the data, and its binder so shops, feeders and shelters
    /// behave as the data says.
    fn placeItem(self: *App, at: [3]f32) !void {
        if (self.item_sel >= self.item_names.items.len) return;
        const name = self.item_names.items[self.item_sel];
        const m = viewer.binderModel(self.gpa, &self.reg, name, "mainObj") orelse return;
        const cost = self.costOf(name, 50);
        if (!self.charge(cost, name, .construction)) return;
        const food: f32 = if (self.feederKind(name) != null) 100 else -1;
        const id = try self.world.addPropEx(m.file, at, world_mod.yawRotation(self.yaw), m.scale, &.{}, name, food);
        self.pushAdded(&.{id}, cost);
        self.sfx("placement");
        self.say("placed {s} (${d:.0})", .{ name, cost });
    }

    fn placeFood(self: *App, at: [3]f32) !void {
        if (self.food_names.items.len == 0) return;
        const name = self.food_names.items[self.food_i];
        const m = viewer.binderModel(self.gpa, &self.reg, name, "mainObj") orelse return;
        const cost = self.costOf(name, 50);
        if (!self.charge(cost, name, .construction)) return;
        const id = try self.world.addPropEx(m.file, at, world_mod.yawRotation(self.yaw), m.scale, &.{}, name, 100);
        self.pushAdded(&.{id}, cost);
        self.sfx("place_building");
        self.say("placed {s} (${d:.0})", .{ name, cost });
    }

    /// The model a prop is drawn with: feeders show a full or empty look.
    fn displayModel(self: *App, p: world_mod.Prop) []const u8 {
        if (p.binder.len == 0 or self.feederKind(p.binder) == null) return p.model;
        for (self.sim.feeders.items) |f| if (f.prop_id == p.id) {
            if (f.food >= 1) if (viewer.binderModel(self.gpa, &self.reg, p.binder, "full")) |m| return m.file;
            return p.model;
        };
        if (p.food >= 1) if (viewer.binderModel(self.gpa, &self.reg, p.binder, "full")) |m| return m.file;
        return p.model;
    }

    const refill_cost: f64 = 10;
    const prop_cost: f64 = 50;
    const path_cost: f64 = 5;

    /// Refills the selected feeder (Shift: every feeder) for a small fee.
    fn refill(self: *App) void {
        var filled: u32 = 0;
        for (self.sim.feeders.items) |*f| {
            const wanted = if (self.shift) true else if (self.selected) |sel| sel.kind == .prop and sel.id == f.prop_id else false;
            if (!wanted or f.food >= 99) continue;
            f.food = 100;
            filled += 1;
        }
        if (filled == 0) return self.say("select a feeder first (tool 1), then press F", .{});
        self.sim.zoo.spend(.supplies, refill_cost * @as(f64, @floatFromInt(filled)));
        self.say("refilled {d} feeder(s) for ${d:.0}", .{ filled, refill_cost * @as(f64, @floatFromInt(filled)) });
    }

    fn placePath(self: *App, at: [3]f32) !void {
        if (self.path_textures.items.len == 0) return;
        const x = snap(at[0], 1.5);
        const y = snap(at[1], 1.5);
        for (self.world.paths.items) |p| {
            if (@abs(p.position[0] - x) < 1.0 and @abs(p.position[1] - y) < 1.0) return;
        }
        if (!self.charge(path_cost, "path", .construction)) return;
        const id = try self.world.addPath(self.path_textures.items[self.path_i], .{ x, y }, 6, 6);
        self.pushAdded(&.{id}, path_cost);
        self.sfx("place_path");
    }

    fn isGateKind(self: *const App) bool {
        if (self.fence_kinds.items.len == 0) return false;
        return std.ascii.findIgnoreCase(self.fence_kinds.items[self.fence_i], "gate") != null;
    }

    /// Puts a gate in the fence: it replaces a fence segment that starts at
    /// this spot (keeping its direction), or goes in as a new piece facing `yaw`.
    fn placeGate(self: *App, at: [2]f32) !void {
        const kind = self.fence_kinds.items[self.fence_i];
        var rot: f32 = self.yaw;
        var replaced: ?world_mod.Fence = null;
        for (self.world.fences.items) |f| {
            const dx = f.position[0] - at[0];
            const dy = f.position[1] - at[1];
            if (dx * dx + dy * dy < 1.6 * 1.6 and std.ascii.findIgnoreCase(f.kind, "gate") == null) {
                replaced = f;
                rot = f.rotation;
                break;
            }
        }
        const cost = self.costOf(kind, 150);
        if (!self.charge(cost, kind, .construction)) return;
        if (replaced) |f| {
            _ = self.world.remove(f.id);
        }
        const id = try self.world.addFence(kind, .{ at[0], at[1], 0 }, rot);
        self.pushAdded(&.{id}, cost);
        self.sfx("place_fence");
        self.say("gate: {s} (${d:.0}){s}", .{ kind, cost, if (replaced != null) " replacing a fence piece" else "" });
    }

    fn placeFenceLine(self: *App, a: [2]f32, b: [2]f32) !void {
        if (self.fence_kinds.items.len == 0) return;
        const kind = self.fence_kinds.items[self.fence_i];
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const horizontal = @abs(dx) >= @abs(dy);
        const len = if (horizontal) dx else dy;
        const n: usize = @intFromFloat(@round(@abs(len) / 3.0));
        if (n == 0) return;
        const theta: f32 = if (horizontal) (if (dx >= 0) 0 else std.math.pi) else (if (dy >= 0) std.math.pi / 2.0 else 3.0 * std.math.pi / 2.0);
        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(self.gpa);
        const each = self.costOf(kind, 20);
        const total = each * @as(f64, @floatFromInt(n));
        if (!self.charge(total, kind, .construction)) return;
        for (0..n) |i| {
            const k = @as(f32, @floatFromInt(i)) * 3.0;
            const x = a[0] + @cos(theta) * k;
            const y = a[1] + @sin(theta) * k;
            const id = try self.world.addFence(kind, .{ x, y, 0 }, theta);
            try ids.append(self.gpa, id);
        }
        self.pushAdded(ids.items, total);
        self.sfx("place_fence");
        self.say("fence: {d} x {s} (${d:.0})", .{ n, kind, total });
    }

    fn deleteSelected(self: *App) void {
        const sel = self.selected orelse return;
        switch (sel.kind) {
            .prop => for (self.world.props.items) |p| if (p.id == sel.id) {
                self.undo.append(self.gpa, .{ .removed_prop = p }) catch {};
                break;
            },
            .fence => for (self.world.fences.items) |p| if (p.id == sel.id) {
                self.undo.append(self.gpa, .{ .removed_fence = p }) catch {};
                break;
            },
            .path => for (self.world.paths.items) |p| if (p.id == sel.id) {
                self.undo.append(self.gpa, .{ .removed_path = p }) catch {};
                break;
            },
            .actor => for (self.world.actors.items) |p| if (p.id == sel.id) {
                if (sim_mod.classify(p.binder) == .animal) {
                    // Putting an animal up for adoption: half its price back, and no undo.
                    const back = self.costOf(p.binder, 100) * 0.5;
                    self.sim.zoo.earn(.animals, back);
                    self.sim.zoo.adopted_out += 1;
                    self.say("{s} adopted out (+${d:.0})", .{ p.binder, back });
                } else self.undo.append(self.gpa, .{ .removed_actor = p }) catch {};
                break;
            },
        }
        if (self.world.remove(sel.id)) {
            self.sfx("delete");
            self.say("deleted", .{});
        }
        self.selected = null;
    }

    fn doUndo(self: *App) void {
        const op = self.undo.pop() orelse return self.say("nothing to undo", .{});
        switch (op) {
            .added => |a| {
                for (a.ids) |id| _ = self.world.remove(id);
                self.sim.zoo.income += a.cost;
                self.sim.zoo.month.spent[@intFromEnum(sim_mod.Cat.construction)] -= a.cost;
                self.gpa.free(a.ids);
            },
            .removed_prop => |p| _ = self.world.addProp(p.model, p.position, p.rotation, p.scale, p.swaps) catch {},
            .removed_fence => |f| _ = self.world.addFence(f.kind, f.position, f.rotation) catch {},
            .removed_path => |p| _ = self.world.addPath(p.texture, p.position, p.width, p.height) catch {},
            .removed_actor => |a| _ = self.world.addActor(a.binder, a.position, a.rotation, a.swaps) catch {},
        }
        self.selected = null;
        self.say("undone", .{});
    }

    /// Applies the terrain brush at (x, y).
    fn brush(self: *App, x: f32, y: f32, dt: f32) void {
        const t = &self.world.terrain;
        const radius: f32 = if (self.tool == .cliff or self.tool == .ditch) 4.0 else 7.0;
        const sx = t.spacingX();
        const sy = t.spacingY();
        const x0: usize = @intFromFloat(@max(0, (x - radius) / sx));
        const x1: usize = @min(t.width - 1, @as(usize, @intFromFloat(@max(0, (x + radius) / sx))) + 1);
        const y0: usize = @intFromFloat(@max(0, (y - radius) / sy));
        const y1: usize = @min(t.height - 1, @as(usize, @intFromFloat(@max(0, (y + radius) / sy))) + 1);
        var j = y0;
        while (j <= y1) : (j += 1) {
            var i = x0;
            while (i <= x1) : (i += 1) {
                const dx = @as(f32, @floatFromInt(i)) * sx - x;
                const dy = @as(f32, @floatFromInt(j)) * sy - y;
                const d = @sqrt(dx * dx + dy * dy);
                if (d >= radius) continue;
                const f = (1 - (d / radius) * (d / radius));
                // cliffs and ditches have a steep, nearly flat-topped profile
                const w = if (self.tool == .cliff or self.tool == .ditch) std.math.clamp(f * 3, 0, 1) else f * f;
                const z = &t.z[j * t.width + i];
                switch (self.tool) {
                    .raise => z.* += 6.0 * dt * w,
                    .lower => z.* -= 6.0 * dt * w,
                    .flatten => z.* += (self.flatten_to - z.*) * @min(1.0, 8.0 * dt) * w,
                    .cliff => z.* += 14.0 * dt * w,
                    .ditch => z.* -= 14.0 * dt * w,
                    .smooth => {
                        const l = if (i > 0) t.z[j * t.width + i - 1] else z.*;
                        const r = if (i + 1 < t.width) t.z[j * t.width + i + 1] else z.*;
                        const u = if (j > 0) t.z[(j - 1) * t.width + i] else z.*;
                        const dn = if (j + 1 < t.height) t.z[(j + 1) * t.width + i] else z.*;
                        z.* += ((l + r + u + dn) / 4 - z.*) * @min(1.0, 6.0 * dt) * w;
                    },
                    else => {},
                }
            }
        }
        self.world.terrainEdited();
        self.brush_touched = true;
        self.brush_center = .{ x, y };
    }

    /// After terrain edits, puts things back on the ground.
    fn resettle(self: *App) void {
        const t = &self.world.terrain;
        const r = 12.0;
        const c = self.brush_center;
        for (self.world.props.items) |*p| {
            if (@abs(p.position[0] - c[0]) < r and @abs(p.position[1] - c[1]) < r)
                p.position[2] = t.zAt(p.position[0], p.position[1]);
        }
        for (self.world.actors.items) |*a| {
            if (@abs(a.position[0] - c[0]) < r and @abs(a.position[1] - c[1]) < r)
                a.position[2] = t.zAt(a.position[0], a.position[1]);
        }
        self.world.revision += 1;
        self.brush_touched = false;
    }

    // ------------------------------------------------------- save and load

    fn saveName(self: *const App, buf: []u8) []const u8 {
        var name: []const u8 = if (self.custom_len > 0) self.custom_name[0..self.custom_len] else self.world.name;
        if (std.mem.indexOfScalar(u8, name, ':')) |i| name = name[i + 1 ..];
        if (name.len == 0) name = "zoo";
        var n: usize = 0;
        for (name) |ch| {
            if (n >= buf.len) break;
            buf[n] = if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') ch else '_';
            n += 1;
        }
        return buf[0..n];
    }

    fn setCustomName(self: *App, name: []const u8) void {
        var n: usize = 0;
        for (name) |ch| {
            if (n >= self.custom_name.len) break;
            self.custom_name[n] = if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') ch else '_';
            n += 1;
        }
        self.custom_len = n;
    }

    /// The character a key types on the save screen, if it types one.
    fn typedChar(scancode: u32, shift: bool) ?u8 {
        if (scancode >= 4 and scancode <= 29) return @intCast('a' + (scancode - 4));
        if (scancode >= 30 and scancode <= 38) return @intCast('1' + (scancode - 30));
        if (scancode == 39) return '0';
        if (scancode == 45) return if (shift) '_' else '-';
        if (scancode == 44) return '_';
        return null;
    }

    fn saveWorld(self: *App) !void {
        self.world.income = self.sim.zoo.income;
        self.world.guests_total = self.sim.zoo.guests_total;
        self.world.views = self.sim.zoo.views;
        var nb: [64]u8 = undefined;
        const name = self.saveName(&nb);
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(self.io, self.opts.save_dir);
        var terr_name_buf: [96]u8 = undefined;
        const terr_name = try std.fmt.bufPrint(&terr_name_buf, "{s}.dat", .{name});
        const terr_path = try std.fs.path.join(self.gpa, &.{ self.opts.save_dir, terr_name });
        defer self.gpa.free(terr_path);
        const dat = try self.world.terrain.encode(self.gpa);
        defer self.gpa.free(dat);
        try cwd.writeFile(self.io, .{ .sub_path = terr_path, .data = dat });

        var out: Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try self.world.save(&out.writer, terr_name);
        var zt2_buf: [96]u8 = undefined;
        const zt2_name = try std.fmt.bufPrint(&zt2_buf, "{s}.zt2", .{name});
        const zt2_path = try std.fs.path.join(self.gpa, &.{ self.opts.save_dir, zt2_name });
        defer self.gpa.free(zt2_path);
        try cwd.writeFile(self.io, .{ .sub_path = zt2_path, .data = out.written() });
        self.say("saved {s}", .{zt2_path});
    }

    fn loadSaved(self: *App) !void {
        var nb: [64]u8 = undefined;
        const name = self.saveName(&nb);
        var zt2_buf: [96]u8 = undefined;
        const zt2_name = try std.fmt.bufPrint(&zt2_buf, "{s}.zt2", .{name});
        const zt2_path = try std.fs.path.join(self.gpa, &.{ self.opts.save_dir, zt2_name });
        defer self.gpa.free(zt2_path);
        try self.loadPath(zt2_path);
    }

    /// Replaces the world with the map or save at `zt2_path` (a game-data
    /// path or a file on disk).
    fn loadPath(self: *App, zt2_path: []const u8) !void {
        const fresh = loadWorld(self.gpa, self.io, self.vfs, zt2_path) catch |e| {
            self.say("could not load ({s})", .{@errorName(e)});
            return;
        };
        try self.installWorld(fresh);
        self.say("loaded {s}", .{std.fs.path.basename(zt2_path)});
    }

    const zoo_sizes = [_]struct { tiles: u32, name: []const u8 }{
        .{ .tiles = 96, .name = "SMALL 96 (STOCK MAX)" },
        .{ .tiles = 144, .name = "LARGE 144" },
        .{ .tiles = 192, .name = "HUGE 192" },
        .{ .tiles = 256, .name = "ENORMOUS 256" },
    };
    /// Biomes offered for a blank zoo (indices into `terrain.blank_biomes`).
    const zoo_biomes = [_]u8{ 0, 1, 2, 3, 4, 6, 7, 8, 9, 10 };

    /// Starts a flat, empty zoo of the chosen size and biome.
    const freeform_cash: f64 = 100000;
    /// Game seconds an animal survives with hunger or thirst at the limit.
    const starve_secs: f32 = 240;
    /// Game seconds for a young animal to grow up, and between a female's litters.
    const young_secs: f32 = 600;
    const breed_gap: f32 = 900;

    /// Animals left without food or water for too long die and are removed.
    fn lifeTick(self: *App, dt: f32) void {
        self.checkNeglect(dt);
        self.breedAndGrow(dt);
    }

    /// Splits "Giraffe_Adult_F" into its species and age/sex parts.
    fn animalParts(binder: []const u8) ?struct { species: []const u8, adult: bool, female: bool } {
        const adult = std.mem.indexOf(u8, binder, "_Adult_");
        const young = std.mem.indexOf(u8, binder, "_Young_");
        const at = adult orelse young orelse return null;
        const tail = binder[at + 7 ..];
        if (tail.len != 1 or (tail[0] != 'F' and tail[0] != 'M')) return null;
        return .{ .species = binder[0..at], .adult = adult != null, .female = tail[0] == 'F' };
    }

    /// Adults of a species that are near each other and well looked after
    /// have young; young animals grow up after a while.
    fn breedAndGrow(self: *App, dt: f32) void {
        self.breed_acc += dt;
        if (self.breed_acc < 1) return;
        const step = self.breed_acc;
        self.breed_acc = 0;
        var grow: ?u32 = null;
        var born: ?struct { species: []const u8, pos: [3]f32, id: u32 } = null;
        var total: usize = 0;
        for (self.sim.agents.items) |*ag| {
            if (ag.is_guest or ag.is_keeper or ag.brain == null) continue;
            total += 1;
            const parts = animalParts(ag.binder) orelse continue;
            ag.age += step;
            if (!parts.adult) {
                if (ag.age >= young_secs and grow == null) grow = ag.id;
                continue;
            }
            if (!parts.female) continue;
            ag.breed_cd -= step;
            if (ag.breed_cd > 0 or born != null) continue;
            const b = ag.brain.?;
            if (b.needs[5] > 70 or b.needs[6] > 70 or ag.hab_score < 40) continue;
            // a male of the species close by
            for (self.sim.agents.items) |*m| {
                if (m.brain == null) continue;
                const mp = animalParts(m.binder) orelse continue;
                if (!mp.adult or mp.female or !std.mem.eql(u8, mp.species, parts.species)) continue;
                const dx = m.pos[0] - ag.pos[0];
                const dy = m.pos[1] - ag.pos[1];
                if (dx * dx + dy * dy > 45 * 45) continue;
                born = .{ .species = parts.species, .pos = ag.pos, .id = ag.id };
                break;
            }
        }
        if (born) |bn| {
            if (self.sim.agentFor(bn.id)) |f| f.breed_cd = breed_gap;
            if (total < 150) self.spawnYoung(bn.species, bn.pos);
        }
        if (grow) |id| self.growUp(id);
    }

    fn spawnYoung(self: *App, species: []const u8, pos: [3]f32) void {
        var nb: [96]u8 = undefined;
        const sex: u8 = if (self.sim.rng.random().boolean()) 'F' else 'M';
        const name = std.fmt.bufPrint(&nb, "{s}_Young_{c}", .{ species, sex }) catch return;
        if (self.reg.get(name) == null or self.actorDef(name) == null) return;
        const id = self.world.addActor(name, self.groundAt(pos[0] + 1.5, pos[1] + 1.5), world_mod.yawRotation(0), &.{}) catch return;
        _ = id;
        self.pushAlert(1, "A {s} WAS BORN", .{species[0..@min(species.len, 30)]});
        self.sim.zoo.births += 1;
    }

    fn growUp(self: *App, id: u32) void {
        const ag = self.sim.agentFor(id) orelse return;
        const parts = animalParts(ag.binder) orelse return;
        var nb: [96]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "{s}_Adult_{c}", .{ parts.species, @as(u8, if (parts.female) 'F' else 'M') }) catch return;
        if (self.reg.get(name) == null or self.actorDef(name) == null) {
            ag.age = -1e9;
            return;
        }
        const pos = ag.pos;
        _ = self.world.remove(id);
        _ = self.world.addActor(name, self.groundAt(pos[0], pos[1]), world_mod.yawRotation(0), &.{}) catch return;
    }

    fn checkNeglect(self: *App, dt: f32) void {
        var dead: ?u32 = null;
        for (self.sim.agents.items) |*ag| {
            const b = ag.brain orelse continue;
            if (ag.is_guest or ag.is_keeper) continue;
            const hunger = b.needs[5];
            const thirst = b.needs[6];
            if (hunger >= 99.5 or thirst >= 99.5) ag.neglect += dt else ag.neglect = @max(0, ag.neglect - dt * 2);
            if (ag.neglect >= starve_secs and dead == null) dead = ag.id;
        }
        const id = dead orelse return;
        var name: []const u8 = "ANIMAL";
        if (self.sim.agentFor(id)) |ag| name = ag.binder;
        self.pushAlert(2, "{s} DIED OF NEGLECT", .{name});
        self.sim.zoo.deaths += 1;
        self.fame = @max(1, self.fame - 0.5);
        _ = self.world.remove(id);
    }

    fn startBlankZoo(self: *App) void {
        const tiles = zoo_sizes[self.nz_size].tiles;
        const biome = zoo_biomes[self.nz_biome];
        const fresh = loadBlankWorld(self.gpa, self.io, self.vfs, tiles, biome) catch |e| {
            self.say("could not create the zoo ({s})", .{@errorName(e)});
            return;
        };
        self.installWorld(fresh) catch |e| {
            self.say("could not start the zoo ({s})", .{@errorName(e)});
            return;
        };
        self.custom_len = 0;
        // Animals cost thousands (an elephant is $20,000), so a freeform zoo starts well funded.
        self.sim.zoo.income = freeform_cash;
        self.placeStarterEntrance();
        self.say("new {d}x{d} tile zoo", .{ tiles, tiles });
    }

    /// A blank zoo opens with a front gate and a short path, as the game's
    /// freeform start does, so guests can arrive as soon as there is something to see.
    fn placeStarterEntrance(self: *App) void {
        const gate = "frontgate_df";
        const m = viewer.binderModel(self.gpa, &self.reg, gate, "mainObj") orelse return;
        const t = &self.world.terrain;
        const cx = snap(t.world_width / 2, 1.5);
        const gy: f32 = 24;
        _ = self.world.addPropEx(m.file, self.groundAt(cx, gy), world_mod.yawRotation(0), m.scale, &.{}, gate, -1) catch return;
        if (self.path_textures.items.len > 0) {
            var y: f32 = gy + 9;
            while (y < gy + 9 + 15 * 1.5) : (y += 1.5) {
                var dx: f32 = -3;
                while (dx <= 3) : (dx += 1.5) {
                    _ = self.world.addPath(self.path_textures.items[self.path_i], .{ cx + dx, y }, 6, 6) catch return;
                }
            }
        }
        self.start_focus = .{ cx, gy + 30 };
    }

    fn installWorld(self: *App, fresh: world_mod.World) !void {
        if (self.scen) |m| {
            m.destroy();
            self.scen = null;
        }
        self.scen_key_len = 0;
        self.world.deinit();
        self.world = fresh;
        self.look.deinit(self.gpa);
        self.look = try viewer.terrainLook(self.gpa, self.vfs, self.scene, &self.world.terrain);
        viewer.waterLook(self.gpa, self.vfs, self.scene, &self.world.terrain) catch {};
        for (self.undo.items) |op| if (op == .added) self.gpa.free(op.added.ids);
        self.undo.clearRetainingCapacity();
        self.selected = null;
        self.fence_start = null;
        self.synced_rev = std.math.maxInt(u32);
        self.synced_actor_rev = std.math.maxInt(u32);
        self.synced_terrain_rev = std.math.maxInt(u32);
        self.sim.deinit();
        self.sim = sim_mod.Sim.init(self.gpa, self.opts.seed);
        self.sim.zoo.income = self.world.income;
        self.sim.zoo.guests_total = self.world.guests_total;
        self.sim.zoo.views = self.world.views;
        self.loadGuestConfig();
        self.installHooks();
        // The new map has its own environment and needs the camera moved to it.
        if (self.env) |*e| e.deinit();
        self.env = loadEnvironment(self.gpa, self.vfs, self.world.environment);
        self.reset_camera = true;
    }

    // ------------------------------------------------------------ scripting

    fn num(tok: ?[]const u8) !f32 {
        return std.fmt.parseFloat(f32, tok orelse return error.BadScript);
    }

    fn groundAt(self: *App, x: f32, y: f32) [3]f32 {
        return .{ x, y, self.world.terrain.zAt(x, y) };
    }

    /// Runs the `--script` commands. Errors in a command are reported and
    /// skipped so a demo keeps going.
    pub fn runScript(self: *App, text: []const u8) void {
        var cmds = std.mem.tokenizeScalar(u8, text, ';');
        while (cmds.next()) |cmd| {
            self.runCommand(std.mem.trim(u8, cmd, " \t\r\n")) catch |e| self.say("script '{s}' failed: {s}", .{ cmd, @errorName(e) });
        }
    }

    fn pickByName(list: []const []const u8, text: []const u8) ?usize {
        for (list, 0..) |item, i| if (std.ascii.eqlIgnoreCase(item, text)) return i;
        var buf: [160]u8 = undefined;
        if (text.len > buf.len) return null;
        const want = std.ascii.lowerString(&buf, text);
        for (list, 0..) |item, i| {
            var b2: [256]u8 = undefined;
            if (item.len > b2.len) continue;
            if (std.mem.indexOf(u8, std.ascii.lowerString(&b2, item), want) != null) return i;
        }
        return null;
    }

    fn runCommand(self: *App, cmd: []const u8) !void {
        if (cmd.len == 0) return;
        var it = std.mem.tokenizeScalar(u8, cmd, ' ');
        const verb = it.next() orelse return;
        if (std.mem.eql(u8, verb, "prop")) {
            const x = try num(it.next());
            const y = try num(it.next());
            try self.placeProp(self.groundAt(x, y));
        } else if (std.mem.eql(u8, verb, "actor")) {
            const x = try num(it.next());
            const y = try num(it.next());
            try self.placeActor(self.groundAt(x, y));
        } else if (std.mem.eql(u8, verb, "path")) {
            const x = try num(it.next());
            const y = try num(it.next());
            try self.placePath(self.groundAt(x, y));
        } else if (std.mem.eql(u8, verb, "fence")) {
            const a = [2]f32{ snap(try num(it.next()), 3.0), snap(try num(it.next()), 3.0) };
            const b = [2]f32{ snap(try num(it.next()), 3.0), snap(try num(it.next()), 3.0) };
            try self.placeFenceLine(a, b);
        } else if (std.mem.eql(u8, verb, "raise") or std.mem.eql(u8, verb, "lower") or std.mem.eql(u8, verb, "flatten")) {
            const x = try num(it.next());
            const y = try num(it.next());
            const secs = try num(it.next());
            self.tool = if (std.mem.eql(u8, verb, "raise")) .raise else if (std.mem.eql(u8, verb, "lower")) .lower else .flatten;
            self.flatten_to = self.world.terrain.zAt(x, y);
            var t: f32 = 0;
            while (t < secs) : (t += 1.0 / 30.0) self.brush(x, y, 1.0 / 30.0);
            self.resettle();
        } else if (std.mem.eql(u8, verb, "food")) {
            const x = try num(it.next());
            const y = try num(it.next());
            try self.placeFood(self.groundAt(x, y));
        } else if (std.mem.eql(u8, verb, "item")) {
            const x = try num(it.next());
            const y = try num(it.next());
            try self.placeItem(self.groundAt(x, y));
        } else if (std.mem.eql(u8, verb, "itemname")) {
            self.item_sel = pickByName(self.item_names.items, it.rest()) orelse return error.NotFound;
        } else if (std.mem.eql(u8, verb, "foodname")) {
            self.food_i = pickByName(self.food_names.items, it.rest()) orelse return error.NotFound;
        } else if (std.mem.eql(u8, verb, "drain")) {
            try self.sim.sync(&self.world);
            for (self.sim.feeders.items) |*f| f.food = 20;
        } else if (std.mem.eql(u8, verb, "newzoo")) {
            const size: usize = @intFromFloat(try num(it.next()));
            const biome: usize = @intFromFloat(try num(it.next()));
            if (size >= zoo_sizes.len or biome >= zoo_biomes.len) return error.NotFound;
            self.nz_size = @intCast(size);
            self.nz_biome = @intCast(biome);
            self.startBlankZoo();
        } else if (std.mem.eql(u8, verb, "pathz")) {
            var lo: f32 = 1e9;
            var hi: f32 = -1e9;
            for (self.world.paths.items) |pt| {
                const z = self.world.terrain.zAt(pt.position[0], pt.position[1]);
                lo = @min(lo, z);
                hi = @max(hi, z);
            }
            var plo: f32 = 1e9;
            for (self.world.props.items) |pr| plo = @min(plo, pr.position[2]);
            std.debug.print("pathz: {d} tiles, ground z {d:.2}..{d:.2}; lowest prop z {d:.2}\n", .{ self.world.paths.items.len, lo, hi, plo });
        } else if (std.mem.eql(u8, verb, "needy")) {
            try self.sim.sync(&self.world);
            for (self.sim.agents.items) |*ag| if (ag.is_guest) {
                ag.needs[0] = 95;
            };
        } else if (std.mem.eql(u8, verb, "lua")) {
            const m = self.scen orelse return error.NotFound;
            m.eng.load("scenario/scripts/entity.lua") catch {};
            m.eng.runString(it.rest()) catch std.debug.print("lua error: {s}\n", .{m.eng.errorText()});
        } else if (std.mem.eql(u8, verb, "count")) {
            const kind = it.next() orelse return error.BadScript;
            var ids: std.ArrayList(u32) = .empty;
            defer ids.deinit(self.gpa);
            scenEntities(self, self.gpa, kind, false, &ids);
            std.debug.print("count {s}: {d} (props {d}, actors {d})\n", .{ kind, ids.items.len, self.world.props.items.len, self.world.actors.items.len });
        } else if (std.mem.eql(u8, verb, "thirsty")) {
            try self.sim.sync(&self.world);
            for (self.sim.agents.items) |*ag| if (ag.brain) |*b| {
                b.needs[6] = 95;
            };
        } else if (std.mem.eql(u8, verb, "waterat")) {
            const x = try num(it.next());
            const y = try num(it.next());
            std.debug.print("water depth at {d:.0},{d:.0}: {d:.2} (ground {d:.2})\n", .{ x, y, self.world.terrain.waterDepth(x, y), self.world.terrain.zAt(x, y) });
        } else if (std.mem.eql(u8, verb, "hungry")) {
            try self.sim.sync(&self.world);
            for (self.sim.agents.items) |*ag| if (ag.brain) |*b| {
                b.needs[5] = 95;
            };
        } else if (std.mem.eql(u8, verb, "delete")) {
            const x = try num(it.next());
            const y = try num(it.next());
            const g = self.groundAt(x, y);
            self.selected = self.pick(.{ g[0], g[1], g[2] + 60 }, .{ 0, 0, -1 });
            self.deleteSelected();
        } else if (std.mem.eql(u8, verb, "undo")) {
            self.doUndo();
        } else if (std.mem.eql(u8, verb, "save")) {
            try self.saveWorld();
        } else if (std.mem.eql(u8, verb, "load")) {
            try self.loadSaved();
        } else if (std.mem.eql(u8, verb, "tasks")) {
            for (self.sim.agents.items) |ag| if (ag.brain) |b| {
                for (b.lib.tasks.items) |t| if (t.target != null) std.debug.print("  task {s} target={s} supported={} subjects={d} flags={d}/{d} quals={d}\n", .{ t.name, t.target.?, t.supported, t.subjects.len, t.flags_and.len, t.flags_or.len, t.quals.len });
                break;
            };
        } else if (std.mem.eql(u8, verb, "brains")) {
            for (self.sim.agents.items) |ag| if (ag.brain) |b| {
                const tn = if (b.task) |ti| b.lib.tasks.items[ti].name else "-";
                std.debug.print("  #{d} {s}: task={s} anim={s} pos={d:.1},{d:.1} needs=", .{ ag.id, ag.binder, tn, ag.anim_name, ag.pos[0], ag.pos[1] });
                for (b.needs) |nv| std.debug.print("{d:.0} ", .{nv});
                std.debug.print("\n", .{});
            };
        } else if (std.mem.eql(u8, verb, "wait") or std.mem.eql(u8, verb, "sim")) {
            const secs = try num(it.next());
            try self.sim.sync(&self.world);
            self.rebuildActors() catch {};
            self.loadFoodTasks();
            var t: f32 = 0;
            while (t < secs) : (t += 0.2) {
                self.sim.advance(&self.world, 0.2);
                self.lifeTick(0.2);
                if (self.scen) |m| {
                    self.syncUiState();
                    m.update(0.2);
                }
            }
        } else if (std.mem.eql(u8, verb, "propname")) {
            self.prop_i = pickByName(self.props.items, it.rest()) orelse return error.NotFound;
        } else if (std.mem.eql(u8, verb, "actorname")) {
            self.actor_i = pickByName(self.actor_names.items, it.rest()) orelse return error.NotFound;
        } else if (std.mem.eql(u8, verb, "fencekind")) {
            self.fence_i = pickByName(self.fence_kinds.items, it.rest()) orelse return error.NotFound;
        } else if (std.mem.eql(u8, verb, "yaw")) {
            self.yaw = try num(it.next());
        } else if (std.mem.eql(u8, verb, "tod")) {
            self.tod = try num(it.next());
        } else return error.UnknownCommand;
    }

    // ------------------------------------------------------------ behaviour

    fn fileExists(self: *App, comptime fmt: []const u8, args: anytype) ?[]u8 {
        var buf: [160]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, fmt, args) catch return null;
        if (!self.vfs.exists(path)) return null;
        return self.vfs.read(self.gpa, path) catch null;
    }

    /// Loads the species' behaviour data (plus the generic actor tasks), once.
    fn brainFor(self: *App, binder: []const u8) ?sim_mod.BrainSetup {
        const b = self.reg.get(binder) orelse return null;
        // The species is the most specific name on the type path that has a task file.
        var species: []const u8 = "";
        var i = b.type_path.len;
        while (i > 0) {
            i -= 1;
            var lower: [64]u8 = undefined;
            if (b.type_path[i].len > lower.len) continue;
            const l = std.ascii.lowerString(&lower, b.type_path[i]);
            var pbuf: [128]u8 = undefined;
            const p = std.fmt.bufPrint(&pbuf, "ai/tasks/animals/{s}.tsk", .{l}) catch continue;
            if (self.vfs.exists(p)) {
                species = b.type_path[i];
                break;
            }
        }
        var key_buf: [64]u8 = undefined;
        if (species.len > key_buf.len) return null;
        const key = std.ascii.lowerString(&key_buf, species);
        if (self.ai_libs.get(key)) |lib| return .{ .lib = lib, .groups = b.type_path };

        const lib = self.gpa.create(ai.Library) catch return null;
        lib.* = ai.Library.init(self.gpa);
        if (species.len > 0) {
            if (self.fileExists("ai/tasks/animals/{s}.beh", .{key})) |d| {
                defer self.gpa.free(d);
                lib.addSets(d) catch {};
            }
            if (self.fileExists("ai/tasks/animals/{s}.tsk", .{key})) |d| {
                defer self.gpa.free(d);
                lib.addTasks(d) catch {};
            }
        }
        // Generic tasks every actor has (a default idle).
        if (self.fileExists("ai/tasks/actor.beh", .{})) |d| {
            defer self.gpa.free(d);
            lib.addSets(d) catch {};
        }
        if (self.fileExists("ai/tasks/actor.tsk", .{})) |d| {
            defer self.gpa.free(d);
            lib.addTasks(d) catch {};
        }
        const owned = self.gpa.dupe(u8, key) catch return null;
        self.ai_libs.put(self.gpa, owned, lib) catch {
            self.gpa.free(owned);
            return null;
        };
        return .{ .lib = lib, .groups = b.type_path };
    }

    fn hookBrain(ctx: *anyopaque, binder: []const u8) ?sim_mod.BrainSetup {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.brainFor(binder);
    }

    fn hookAnimLen(ctx: *anyopaque, actor_id: u32, name: []const u8) ?f32 {
        const self: *App = @ptrCast(@alignCast(ctx));
        for (self.actor_ids.items, 0..) |id, i| if (id == actor_id) return self.scene.animDuration(i, name);
        return null;
    }

    /// Reads the game's guest manager settings (cap, arrival delays, prices).
    fn loadGuestConfig(self: *App) void {
        const bytes = self.vfs.read(self.gpa, "ai/guestmgr.xml") catch return;
        defer self.gpa.free(bytes);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const root = xml.parse(arena.allocator(), bytes, null) catch return;
        const f = struct {
            fn get(e: *const xml.Element, name: []const u8, default: f32) f32 {
                const v = e.attr(name) orelse return default;
                return std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch default;
            }
        };
        self.guests_base = f.get(root, "MaxGuestsBase", self.guests_base);
        self.guests_per_star = f.get(root, "MaxGuestsPerStar", self.guests_per_star);
        self.sim.spawn_delay = .{ f.get(root, "MinDelaySecs", 1), f.get(root, "MaxDelaySecs", 6) };
        self.sim.adult_price = f.get(root, "NormalAdultAdmission", 24);
        self.sim.child_price = f.get(root, "NormalChildAdmission", 12);
    }

    /// Star rating from how happy guests are: 1 to 5.
    pub fn stars(self: *const App) f32 {
        return std.math.clamp(@floor(self.fame), 1, 5);
    }

    /// Fame drifts slowly towards what the zoo deserves: guest happiness,
    /// capped by how many animals there are to see (a new zoo starts at one star).
    fn updateFame(self: *App, dt: f32) void {
        const guests = self.sim.liveGuests();
        var target: f32 = 1;
        if (guests > 0) {
            const animals: f32 = @floatFromInt(self.countAnimals());
            const cap = 1 + animals * 0.5;
            target = @min(1 + self.sim.happiness() / 25.0, cap);
        }
        target = std.math.clamp(target, 1, 5.99);
        const step = 0.03 * dt;
        self.fame += std.math.clamp(target - self.fame, -step, step);
    }

    /// The inheritance chain of an entity, cached.
    fn chainFor(self: *App, binder: []const u8) ?[]const *const entity.Binder {
        var buf: [128]u8 = undefined;
        if (binder.len > buf.len) return null;
        const key = std.ascii.lowerString(&buf, binder);
        if (self.chains.get(key)) |c| return c;
        const b = self.reg.get(binder) orelse return null;
        const chain = self.reg.chain(self.gpa, b) catch return null;
        const owned = self.gpa.dupe(u8, key) catch {
            self.gpa.free(chain);
            return null;
        };
        self.chains.put(self.gpa, owned, chain) catch {
            self.gpa.free(owned);
            self.gpa.free(chain);
            return null;
        };
        return chain;
    }

    fn hookFlag(ctx: *anyopaque, binder: []const u8, name: []const u8) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        const chain = self.chainFor(binder) orelse return false;
        const v = entity.Registry.attr(chain, .shared, "BFAIEntityDataShared", name) orelse return false;
        return std.ascii.eqlIgnoreCase(v, "true") or std.mem.eql(u8, v, "1");
    }

    /// A food container's kind (`FoodDish`, `Trough`...): the type name just
    /// below `food` on its type path.
    fn feederKind(self: *App, binder: []const u8) ?[]const u8 {
        const b = self.reg.get(binder) orelse return null;
        for (b.type_path, 0..) |t, i| if (std.ascii.eqlIgnoreCase(t, "food") and i + 1 < b.type_path.len) {
            return b.type_path[i + 1];
        };
        return null;
    }

    /// Toys, shelters and rocks animals can use: any such entity with a task
    /// file of its own. The name is the binder, which behaviour sets key on.
    fn usableKind(self: *App, binder: []const u8) ?[]const u8 {
        const b = self.reg.get(binder) orelse return null;
        if (b.type_path.len < 2) return null;
        const group = b.type_path[1];
        const dir = if (std.ascii.eqlIgnoreCase(group, "enrichment")) "enrichment" else if (std.ascii.eqlIgnoreCase(group, "shelters")) "shelters" else if (std.ascii.eqlIgnoreCase(group, "rock")) "rocks" else return null;
        var lower: [96]u8 = undefined;
        if (binder.len > lower.len) return null;
        const l = std.ascii.lowerString(&lower, binder);
        var pb: [160]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "ai/tasks/{s}/{s}.tsk", .{ dir, l }) catch return null;
        if (!self.vfs.exists(path)) return null;
        return b.name;
    }

    fn hookUsable(ctx: *anyopaque, binder: []const u8) ?[]const u8 {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.usableKind(binder);
    }

    /// Shops and facilities, classified by their entity type names.
    fn venueNeed(b: *const entity.Binder) ?sim_mod.Need {
        for (b.type_path) |t| {
            var buf: [64]u8 = undefined;
            if (t.len > buf.len) continue;
            const l = std.ascii.lowerString(&buf, t);
            if (std.mem.startsWith(u8, l, "bathroom")) return .bathroom;
            if (std.mem.startsWith(u8, l, "foodstand_")) {
                if (std.mem.indexOf(u8, l, "soda") != null or std.mem.indexOf(u8, l, "coffee") != null or std.mem.indexOf(u8, l, "water") != null) return .thirst;
                return .hunger;
            }
            if (std.mem.startsWith(u8, l, "restaurant")) return .hunger;
            if (std.mem.startsWith(u8, l, "snackcart")) return .dessert;
            if (std.mem.startsWith(u8, l, "giftcart") or std.mem.startsWith(u8, l, "giftshop")) return .gift;
        }
        return null;
    }

    fn findTransaction(e: *const xml.Element, name: []const u8) ?*const xml.Element {
        if (std.ascii.eqlIgnoreCase(e.name, "ZTTransaction")) {
            if (e.attr("name")) |n| if (std.ascii.eqlIgnoreCase(n, name)) return e;
        }
        for (e.children) |c| if (findTransaction(c, name)) |v| return v;
        return null;
    }

    fn hookVenue(ctx: *anyopaque, binder: []const u8) ?sim_mod.VenueInfo {
        const self: *App = @ptrCast(@alignCast(ctx));
        const b = self.reg.get(binder) orelse return null;
        const need = venueNeed(b) orelse return null;
        const ch = self.reg.chain(self.gpa, b) catch return null;
        defer self.gpa.free(ch);
        var price: f32 = 0;
        var upkeep: f32 = 0;
        var i = ch.len;
        while (i > 0) {
            i -= 1;
            if (price == 0) if (findTransaction(ch[i].root, "Buy_Item")) |t| {
                // "costChoice" lists the prices the player may set; take the middle.
                if (t.attr("costChoice")) |cc| {
                    var vals: [8]f32 = undefined;
                    var n: usize = 0;
                    var tk = std.mem.tokenizeAny(u8, cc, " ,");
                    while (tk.next()) |v| if (n < vals.len) {
                        vals[n] = std.fmt.parseFloat(f32, v) catch continue;
                        n += 1;
                    };
                    if (n > 0) price = vals[n / 2];
                } else if (t.attr("cost")) |c| price = std.fmt.parseFloat(f32, c) catch 0;
            };
            if (upkeep == 0) if (findTransaction(ch[i].root, "upkeep")) |t| {
                if (t.attr("cost")) |c| upkeep = std.fmt.parseFloat(f32, c) catch 0;
            };
        }
        return .{ .need = need, .price = price, .upkeep = upkeep };
    }

    fn findElem(e: *const xml.Element, name: []const u8) ?*const xml.Element {
        if (std.ascii.eqlIgnoreCase(e.name, name)) return e;
        for (e.children) |c| if (findElem(c, name)) |v| return v;
        return null;
    }

    /// A species' biome sensitivities and space needs from its entity data.
    fn hookHabitat(ctx: *anyopaque, binder: []const u8) ?sim_mod.Habitat {
        const self: *App = @ptrCast(@alignCast(ctx));
        const b = self.reg.get(binder) orelse return null;
        const ch = self.reg.chain(self.gpa, b) catch return null;
        defer self.gpa.free(ch);
        var h: sim_mod.Habitat = .{};
        var found = false;
        var got_first = false;
        var got_more = false;
        var got_species = false;
        var i = ch.len;
        // Most specific binder first; each value is taken once.
        while (i > 0) {
            i -= 1;
            const root = ch[i].root;
            if (!found) if (findElem(root, "BFGBiomeData")) |bd| {
                found = true;
                for (bd.children, 0..) |_, ci| {
                    const c = bd.children[ci];
                    for (sim_mod.habitat_biomes, 0..) |name, bi| if (std.ascii.eqlIgnoreCase(c.name, name)) {
                        if (c.attr("sensitivity")) |sv| h.sens[bi] = std.fmt.parseFloat(f32, sv) catch 0;
                    };
                }
            };
            if (findElem(root, "BFAIEntityDataShared")) |sh| {
                if (!got_first) if (sh.attr("f_RequiredInitialSpace")) |v| {
                    h.space_first = std.fmt.parseFloat(f32, v) catch 0;
                    got_first = true;
                };
                if (!got_more) if (sh.attr("f_RequiredAdditionalSpace")) |v| {
                    h.space_more = std.fmt.parseFloat(f32, v) catch 0;
                    got_more = true;
                };
                if (!got_species) if (sh.attr("s_Species")) |v| {
                    h.species = v;
                    got_species = true;
                };
            }
        }
        if (!found and !got_first) return null;
        return h;
    }

    fn hookWage(ctx: *anyopaque, binder: []const u8) f32 {
        const self: *App = @ptrCast(@alignCast(ctx));
        const b = self.reg.get(binder) orelse return 0;
        const ch = self.reg.chain(self.gpa, b) catch return 0;
        defer self.gpa.free(ch);
        var i = ch.len;
        while (i > 0) {
            i -= 1;
            if (findSalary(ch[i].root)) |v| return @floatCast(v);
        }
        return 0;
    }

    fn findSalary(e: *const xml.Element) ?f64 {
        if (std.ascii.eqlIgnoreCase(e.name, "ZTTransaction")) {
            if (e.attr("name")) |n| if (std.ascii.eqlIgnoreCase(n, "salary")) {
                if (e.attr("cost")) |c| return std.fmt.parseFloat(f64, c) catch null;
            };
        }
        for (e.children) |c| if (findSalary(c)) |v| return v;
        return null;
    }

    fn hookFeeder(ctx: *anyopaque, binder: []const u8) ?[]const u8 {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.feederKind(binder);
    }

    /// Loads the feeding tasks of every feeder in the world into the animal
    /// libraries (the tasks live with the food, not the animal).
    fn loadFoodTasks(self: *App) void {
        for (self.world.props.items) |p| {
            if (p.binder.len == 0 or (self.feederKind(p.binder) == null and self.usableKind(p.binder) == null)) continue;
            var lit = self.ai_libs.iterator();
            while (lit.next()) |e| {
                var kb: [200]u8 = undefined;
                var lower: [96]u8 = undefined;
                if (p.binder.len > lower.len) continue;
                const l = std.ascii.lowerString(&lower, p.binder);
                const key = std.fmt.bufPrint(&kb, "{s}|{s}", .{ e.key_ptr.*, l }) catch continue;
                if (self.food_loaded.contains(key)) continue;
                const owned = self.gpa.dupe(u8, key) catch continue;
                self.food_loaded.put(self.gpa, owned, {}) catch {
                    self.gpa.free(owned);
                    continue;
                };
                for ([_][]const u8{ "food", "enrichment", "shelters", "rocks" }) |dir| {
                    if (self.fileExists("ai/tasks/{s}/{s}.tsk", .{ dir, l })) |d| {
                        defer self.gpa.free(d);
                        e.value_ptr.*.addTasks(d) catch {};
                        break;
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------ campaigns

    fn ensureStrings(self: *App) void {
        if (self.strings != null) return;
        var st = loc_mod.Loc.init(self.gpa);
        st.load(self.vfs, "lang/1033/") catch {};
        self.strings = st;
    }

    /// Text for a localized id, upper-cased for the font (the id itself if unknown).
    fn locUpper(self: *App, a: std.mem.Allocator, id: []const u8) []const u8 {
        const t = if (self.strings) |*st| st.get(id) orelse id else id;
        return std.ascii.allocUpperString(a, t) catch t;
    }

    fn campaignFile(self: *const App, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/campaign.txt", .{self.opts.save_dir}) catch "campaign.txt";
    }

    /// Reads the campaign index, every campaign's scenarios and the saved progress.
    fn loadCampaigns(self: *App) void {
        if (self.camp_ready) return self.buildCampaignLabels();
        self.camp_arena = .init(self.gpa);
        self.camp_ready = true;
        self.ensureStrings();
        const a = self.camp_arena.allocator();
        const idx_bytes = self.vfs.read(self.gpa, "scenario/campaign/index.xml") catch return;
        defer self.gpa.free(idx_bytes);
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const idx = xml.parse(scratch.allocator(), idx_bytes, null) catch return;
        for (idx.children) |ce| {
            if (!std.ascii.eqlIgnoreCase(ce.name, "campaign")) continue;
            var pb: [160]u8 = undefined;
            const path = std.fmt.bufPrint(&pb, "scenario/campaign/{s}", .{std.mem.trim(u8, ce.text, " \t\r\n")}) catch continue;
            const bytes = self.vfs.read(self.gpa, path) catch continue;
            defer self.gpa.free(bytes);
            const root = xml.parse(scratch.allocator(), bytes, null) catch continue;
            var entries: std.ArrayList(CampEntry) = .empty;
            for (root.children) |e| {
                if (!std.ascii.eqlIgnoreCase(e.name, "entry")) continue;
                const cash = std.fmt.parseFloat(f64, e.attr("cash") orelse "0") catch 0;
                entries.append(a, .{
                    .name = a.dupe(u8, e.attr("name") orelse "") catch continue,
                    .key = a.dupe(u8, e.attr("key") orelse "") catch continue,
                    .scenario = a.dupe(u8, e.attr("scenario") orelse "") catch continue,
                    .map = a.dupe(u8, e.attr("map") orelse "") catch continue,
                    .cash = cash,
                    .description = a.dupe(u8, e.attr("description") orelse "") catch continue,
                    .open = !(if (e.attr("state")) |st| std.ascii.eqlIgnoreCase(st, "locked") else false),
                }) catch {};
            }
            if (entries.items.len == 0) continue;
            self.campaigns.append(self.gpa, .{
                .name = a.dupe(u8, root.attr("name") orelse "") catch continue,
                .tutorial = if (root.attr("tutorial")) |t| std.ascii.eqlIgnoreCase(t, "true") else false,
                .entries = entries.toOwnedSlice(a) catch continue,
            }) catch {};
        }
        // Progress.
        var fb: [200]u8 = undefined;
        if (std.Io.Dir.cwd().readFileAlloc(self.io, self.campaignFile(&fb), self.gpa, .limited(64 * 1024)) catch null) |data| {
            defer self.gpa.free(data);
            var lines = std.mem.tokenizeAny(u8, data, "\r\n");
            while (lines.next()) |ln| {
                const k = a.dupe(u8, std.mem.trim(u8, ln, " ")) catch continue;
                self.done_keys.put(self.gpa, k, {}) catch {};
            }
        }
        self.buildCampaignLabels();
    }

    fn buildCampaignLabels(self: *App) void {
        const a = self.camp_arena.allocator();
        self.camp_labels.clearRetainingCapacity();
        for (self.campaigns.items) |cp| {
            self.camp_labels.append(self.gpa, self.locUpper(a, cp.name)) catch {};
        }
    }

    /// A scenario can be played when its campaign opens it, or the one
    /// before it has been finished.
    fn entryOpen(self: *const App, cp: Campaign, i: usize) bool {
        if (cp.entries[i].open or self.done_keys.contains(cp.entries[i].key)) return true;
        return i > 0 and self.done_keys.contains(cp.entries[i - 1].key);
    }

    fn buildScenarioLabels(self: *App) void {
        const a = self.camp_arena.allocator();
        self.scen_labels.clearRetainingCapacity();
        const cp = self.campaigns.items[self.camp_sel];
        for (cp.entries, 0..) |e, i| {
            const state: []const u8 = if (self.done_keys.contains(e.key)) "  [DONE]" else if (self.entryOpen(cp, i)) "" else "  [LOCKED]";
            const label = std.fmt.allocPrint(a, "{s}{s}", .{ self.locUpper(a, e.name), state }) catch continue;
            self.scen_labels.append(self.gpa, label) catch {};
        }
    }

    /// Loads a scenario's map with its starting cash and starts its goals.
    fn startCampaignEntry(self: *App, e: CampEntry) void {
        var pb: [160]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "maps/scenario/{s}.zt2", .{e.map}) catch return;
        self.loadPath(path) catch return;
        self.custom_len = 0;
        self.sim.zoo.income = e.cash;
        self.world.income = e.cash;
        self.startScenario(e.scenario);
        const n = @min(e.key.len, self.scen_key.len);
        @memcpy(self.scen_key[0..n], e.key[0..n]);
        self.scen_key_len = n;
        self.openMenu(.none);
    }

    fn markScenarioDone(self: *App) void {
        if (self.scen_key_len == 0 or !self.camp_ready) return;
        const key = self.scen_key[0..self.scen_key_len];
        if (self.done_keys.contains(key)) return;
        const owned = self.camp_arena.allocator().dupe(u8, key) catch return;
        self.done_keys.put(self.gpa, owned, {}) catch return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        var it = self.done_keys.keyIterator();
        while (it.next()) |k| {
            out.appendSlice(self.gpa, k.*) catch return;
            out.append(self.gpa, '\n') catch return;
        }
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(self.io, self.opts.save_dir) catch {};
        var fb: [200]u8 = undefined;
        cwd.writeFile(self.io, .{ .sub_path = self.campaignFile(&fb), .data = out.items }) catch {};
        self.say("scenario complete!", .{});
        self.pushAlert(1, "SCENARIO COMPLETE", .{});
    }

    // ------------------------------------------------------------ scenarios

    /// Starts the goals of a scenario (`scenario/goals/*.xml`) on the
    /// current zoo.
    fn startScenario(self: *App, goals: []const u8) void {
        self.scen_result = .running;
        self.scen_tutorial = std.ascii.findIgnoreCase(goals, "tutorial") != null;
        if (self.scen) |m| {
            m.destroy();
            self.scen = null;
        }
        if (self.strings == null) {
            var st = loc_mod.Loc.init(self.gpa);
            st.load(self.vfs, "lang/1033/") catch {};
            self.strings = st;
        }
        if (self.ui_state == null) self.ui_state = uistate.State.init(self.gpa);
        const m = scenario_mod.Manager.create(self.gpa, self.vfs, &self.strings.?) catch |e| {
            self.say("scenario failed: {s}", .{@errorName(e)});
            return;
        };
        m.host = .{
            .ctx = self,
            .entities = scenEntities,
            .leaf_types = scenLeaves,
            .binder_attr = scenBinderAttr,
            .place = scenPlace,
            .attr = scenAttr,
            .set_attr = scenSetAttr,
            .selected = scenSelected,
            .ui = &self.ui_state.?,
            .ui_known = scenUiKnown,
            .attr_bool = scenAttrBool,
            .attr_str = scenAttrStr,
            .kind_of = scenKindOf,
            .binder = scenBinder,
            .stat = scenStat,
            .give_cash = scenGiveCash,
        };
        m.add(goals) catch |e| {
            self.say("cannot load goals {s}: {s}", .{ goals, @errorName(e) });
            m.destroy();
            return;
        };
        m.challenge_mode = std.mem.endsWith(u8, goals, "challengegoals.xml");
        m.log = self.opts.scenario_log;
        m.eng.log = self.opts.scenario_log;
        m.trace = std.c.getenv("ZT_TRACE") != null;
        self.scen = m;
        // The map's animals must exist before the first check, or sticky rules that count them fail at once.
        self.sim.sync(&self.world) catch {};
        self.syncUiState();
        m.tick();
    }

    /// Whether an entity is of a kind, by type path.
    fn binderIs(self: *App, binder: []const u8, kind: []const u8, direct: bool) bool {
        const b = self.reg.get(binder) orelse return false;
        if (direct) return std.ascii.eqlIgnoreCase(b.name, kind) or (b.type_path.len > 0 and std.ascii.eqlIgnoreCase(b.type_path[b.type_path.len - 1], kind));
        for (b.type_path) |t| if (std.ascii.eqlIgnoreCase(t, kind)) return true;
        return false;
    }

    const prop_handle: u32 = 0x8000_0000;

    fn scenEntities(ctx: *anyopaque, gpa: std.mem.Allocator, kind: []const u8, direct: bool, out: *std.ArrayList(u32)) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        for (self.sim.agents.items) |ag| {
            if (ag.binder.len == 0 or !self.binderIs(ag.binder, kind, direct)) continue;
            out.append(gpa, ag.id) catch {};
        }
        for (self.world.props.items) |p| {
            if (p.binder.len == 0 or !self.binderIs(p.binder, kind, direct)) continue;
            out.append(gpa, p.id | prop_handle) catch {};
        }
    }

    fn scenPlace(ctx: *anyopaque, binder: []const u8, x: f32, y: f32, rot: f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        const at = self.groundAt(x, y);
        const rotm = world_mod.yawRotation(rot);
        if (self.actorDef(binder) != null) {
            _ = self.world.addActor(binder, at, rotm, &.{}) catch return;
        } else if (viewer.binderModel(self.gpa, &self.reg, binder, "mainObj")) |m| {
            const food: f32 = if (self.feederKind(binder) != null) 100 else -1;
            _ = self.world.addPropEx(m.file, at, rotm, m.scale, &.{}, binder, food) catch return;
        } else return;
        self.say("{s} arrives", .{binder});
    }

    fn scenLeaves(ctx: *anyopaque, gpa: std.mem.Allocator, kind: []const u8, out: *std.ArrayList([]const u8)) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        var it = self.reg.binders.valueIterator();
        while (it.next()) |bp| {
            const b = bp.*;
            if (b.abstract or b.type_path.len == 0) continue;
            var inside = false;
            for (b.type_path) |t| if (std.ascii.eqlIgnoreCase(t, kind)) {
                inside = true;
            };
            if (!inside) continue;
            const leaf = b.type_path[b.type_path.len - 1];
            var dup = false;
            for (out.items) |o| if (std.mem.eql(u8, o, leaf)) {
                dup = true;
            };
            if (!dup) out.append(gpa, leaf) catch {};
        }
    }

    fn scenAttr(ctx: *anyopaque, id: u32, name: []const u8) ?f64 {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (id & prop_handle != 0) return null;
        const ag = self.sim.agentFor(id) orelse return null;
        if (std.ascii.eqlIgnoreCase(name, "environment")) return if (ag.habitat != null) 100 - @as(f64, ag.hab_score) else 0;
        const b = ag.brain orelse return null;
        for (ai.need_names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, name)) return b.needs[i];
        return null;
    }

    /// The tutorial's Continue button: it hides itself, the panel and the block-out.
    fn pressContinue(self: *App) void {
        const us = &(self.ui_state orelse return);
        const e = us.at("continue tutorial");
        e.presses += 1;
        e.visible = false;
        us.at("tutorial info").visible = false;
        us.at("tutorial block out").visible = false;
    }

    /// Challenge Mode: the scenario manager hands out timed challenges.
    fn maybeStartChallenge(self: *App) void {
        if (!self.challenge_next) return;
        self.challenge_next = false;
        self.startScenario("scenario/goals/challengegoals.xml");
        if (self.scen) |m| m.challenge_mode = true;
        self.say("challenge mode: challenges will be offered as your zoo grows", .{});
    }

    fn challengeOpen(self: *const App) bool {
        const us = &(self.ui_state orelse return false);
        for ([_][]const u8{ "challenge layout", "instant challenge layout" }) |n| {
            if (us.get(n)) |e| if (e.visible orelse false) return true;
        }
        return false;
    }

    /// The accept / decline panel for a challenge, from what the scripts put in
    /// the challenge layout's text nodes.
    fn drawChallenge(self: *App, ui: *viewer.Ui, scale: f32) !void {
        const us = &(self.ui_state orelse return);
        const instant = if (us.get("instant challenge layout")) |e| e.visible orelse false else false;
        const text = if (instant) (if (us.get("instant challenge text")) |e| e.text else "") else (if (us.get("challenge text")) |e| e.text else "");
        const intro = if (instant) (if (us.get("instant challenge description text")) |e| e.text else "") else "";
        const ts: f32 = @max(2, @round(scale * 1.1));
        const pw = @min(ui.width * 0.8, 120 * 6 * ts);
        const ph = ui.height * 0.62;
        const px = (ui.width - pw) / 2;
        const py = ui.height * 0.14;
        try ui.rect(0, 0, ui.width, ui.height, .{ 0, 0, 0, 0.45 });
        ui.template("blank", px, py, pw, ph, scale / 2, 1);
        _ = try ui.text(px + 16 * ts, py + 10 * ts, ts * 1.4, if (instant) "INSTANT CHALLENGE" else "CHALLENGE", .{ 1, 0.92, 0.5, 1 });
        const cols: usize = @intFromFloat(@max(20, (pw - 32 * ts) / (6 * ts)));
        var y = py + 36 * ts;
        if (intro.len > 0) y += try self.wrapText(ui, px + 16 * ts, y, ts, cols, intro, .{ 0.8, 0.85, 0.9, 1 }) + 8 * ts;
        _ = try self.wrapText(ui, px + 16 * ts, y, ts, cols, text, .{ 1, 1, 1, 1 });
        const bw = 22 * 6 * ts;
        const bh = 7 * ts + 10 * ts;
        const by = py + ph - bh - 12 * ts;
        const items = [_]struct { label: []const u8, x: f32, act: MenuAction }{
            .{ .label = "ACCEPT", .x = px + pw / 2 - bw - 10 * ts, .act = .challenge_accept },
            .{ .label = "DECLINE", .x = px + pw / 2 + 10 * ts, .act = .challenge_decline },
        };
        for (items) |it| {
            ui.template("buttonbar", it.x, by, bw, bh, ts / 2, 1);
            _ = try ui.text(it.x + (bw - viewer.Ui.textWidth(it.label, ts)) / 2, by + 5 * ts, ts, it.label, .{ 1, 1, 1, 1 });
            try self.hits.append(self.gpa, .{ .x = it.x, .y = by, .w = bw, .h = bh, .action = .{ .menu = it.act } });
        }
    }

    fn scenUiKnown(ctx: *anyopaque, name: []const u8) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        const h = &(self.hud orelse return false);
        if (h.shell.find(name) != null) return true;
        for ([_][]const u8{ "challenge layout", "instant challenge layout", "challenge text", "instant challenge text", "instant challenge description text", "branch layout" }) |kn| if (std.ascii.eqlIgnoreCase(kn, name)) return true;
        inline for (.{ "tutorial", "goals", "status", "info", "bucks", "mainmenu" }) |f| {
            if (@field(h, f)) |*lay| if (lay.find(name) != null) return true;
        }
        return false;
    }

    /// Writes what the player has open or pressed into the UI state scripts read.
    fn syncUiState(self: *App) void {
        const st = &(self.ui_state orelse return);
        st.at("goals layout").visible = self.menu == .goals;
        st.at("goalpanel").visible = self.menu == .goals;
        st.at("goal panel").visible = self.menu == .goals;
        st.at("scenariogoals").activated = self.menu == .goals;
        st.at("Zoofinance").activated = self.menu == .finances;
        st.at("zoo status layout").visible = self.menu == .finances;
    }

    fn scenSelected(ctx: *anyopaque) ?u32 {
        const self: *App = @ptrCast(@alignCast(ctx));
        const sel = self.selected orelse return null;
        return switch (sel.kind) {
            .actor => sel.id,
            .prop => sel.id | prop_handle,
            else => null,
        };
    }

    fn scenAttrBool(ctx: *anyopaque, id: u32, name: []const u8) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        return hookFlag(self, scenBinder(ctx, id), name);
    }

    fn scenAttrStr(ctx: *anyopaque, id: u32, name: []const u8) ?[]const u8 {
        const self: *App = @ptrCast(@alignCast(ctx));
        const chain = self.chainFor(scenBinder(ctx, id)) orelse return null;
        if (name.len > 0 and name[0] == '@') {
            // Where the species comes from, and the biome it likes best (from BFGBiomeData).
            if (std.mem.eql(u8, name, "@location")) return entity.Registry.attr(chain, .shared, "BFGBiomeData", "location");
            var i = chain.len;
            while (i > 0) {
                i -= 1;
                const sec = chain[i].section(.shared) orelse continue;
                const bd = for (sec.children) |ch| {
                    if (std.ascii.eqlIgnoreCase(ch.name, "BFGBiomeData")) break ch;
                } else continue;
                var best: ?[]const u8 = null;
                var bv: f32 = -1000;
                for (sim_mod.habitat_biomes) |bn| for (bd.children) |c| if (std.ascii.eqlIgnoreCase(c.name, bn)) {
                    const v = std.fmt.parseFloat(f32, c.attr("sensitivity") orelse "0") catch 0;
                    if (v > bv) {
                        bv = v;
                        best = bn;
                    }
                };
                return best;
            }
            return null;
        }
        return entity.Registry.attr(chain, .shared, "BFAIEntityDataShared", name);
    }

    fn scenBinderAttr(ctx: *anyopaque, binder: []const u8, name: []const u8) ?[]const u8 {
        const self: *App = @ptrCast(@alignCast(ctx));
        const chain = self.chainFor(binder) orelse return null;
        return entity.Registry.attr(chain, .shared, "BFAIEntityDataShared", name);
    }

    fn scenKindOf(ctx: *anyopaque, id: u32, kind: []const u8) bool {
        const self: *App = @ptrCast(@alignCast(ctx));
        return self.binderIs(scenBinder(ctx, id), kind, false);
    }

    fn scenSetAttr(ctx: *anyopaque, id: u32, name: []const u8, value: f64) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (id & prop_handle != 0) return;
        const ag = self.sim.agentFor(id) orelse return;
        if (ag.brain) |*b| for (ai.need_names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, name)) {
            b.needs[i] = @floatCast(value);
        };
    }

    fn scenBinder(ctx: *anyopaque, id: u32) []const u8 {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (id & prop_handle != 0) {
            for (self.world.props.items) |p| if (p.id | prop_handle == id) return p.binder;
            return "";
        }
        return if (self.sim.agentFor(id)) |ag| ag.binder else "";
    }

    fn scenStat(ctx: *anyopaque, name: []const u8) f64 {
        const self: *App = @ptrCast(@alignCast(ctx));
        const eq = std.mem.eql;
        if (eq(u8, name, "cash")) return self.sim.zoo.income;
        if (eq(u8, name, "month")) return @floatFromInt(self.sim.zoo.months);
        if (eq(u8, name, "day")) return @floor((1 - self.sim.month_timer / self.sim.month_secs) * 30) + 1;
        if (eq(u8, name, "time")) return self.tod;
        if (eq(u8, name, "fame")) return self.stars() * 2;
        if (eq(u8, name, "guests")) return @floatFromInt(self.sim.liveGuests());
        if (std.mem.startsWith(u8, name, "cam_")) {
            const fc = self.cur_ctx orelse return 0;
            if (eq(u8, name, "cam_x")) return fc.cam.center[0];
            if (eq(u8, name, "cam_y")) return fc.cam.center[1];
            if (eq(u8, name, "cam_z")) return fc.cam.center[2];
            if (eq(u8, name, "cam_zoom")) return fc.cam.dist;
            if (eq(u8, name, "cam_yaw")) return fc.cam.yaw;
        }
        if (std.mem.startsWith(u8, name, "biome:")) {
            const t = &self.world.terrain;
            var n: f64 = 0;
            for (t.paint) |pi| {
                if (pi < t.biomes.len and std.ascii.eqlIgnoreCase(t.biomes[pi], name[6..])) n += 1;
            }
            return n;
        }
        if (std.mem.startsWith(u8, name, "eco:")) return self.ecoFigure(name);
        if (eq(u8, name, "guests_total")) return @floatFromInt(self.sim.zoo.guests_total);
        if (eq(u8, name, "admission")) return self.sim.adult_price;
        if (eq(u8, name, "is_campaign")) return if (self.scen_key_len > 0) 1 else 0;
        if (eq(u8, name, "simtime")) return @as(f64, @floatFromInt(self.sim.zoo.months)) * self.sim.month_secs + (self.sim.month_secs - self.sim.month_timer);
        if (eq(u8, name, "income")) {
            var t: f64 = 0;
            for (self.sim.zoo.month.earned) |v| t += v;
            return t;
        }
        if (eq(u8, name, "profit")) {
            var t: f64 = 0;
            for (self.sim.zoo.month.earned) |v| t += v;
            for (self.sim.zoo.month.spent) |v| t -= v;
            return t;
        }
        if (eq(u8, name, "lifetime_income")) {
            var t: f64 = 0;
            for (self.sim.zoo.total.earned) |v| t += v;
            return t;
        }
        return 0;
    }

    /// `eco:<period>:<category>:<type>:<month>` figures for ZTEconomyMgr:ZT_GET_INFO.
    fn ecoFigure(self: *App, key: []const u8) f64 {
        var it = std.mem.splitScalar(u8, key, ':');
        _ = it.next();
        const period = it.next() orelse return 0;
        const cat = it.next() orelse return 0;
        const typ = it.next() orelse return 0;
        const z = &self.sim.zoo;
        const led = if (std.mem.eql(u8, period, "monthly")) z.month else z.total;
        if (std.mem.eql(u8, typ, "totalUsers")) return @floatFromInt(z.guests_total);
        var earned: f64 = 0;
        var spent: f64 = 0;
        for (std.enums.values(sim_mod.Cat)) |cv| {
            const match = cat.len == 0 or std.ascii.eqlIgnoreCase(cat, @tagName(cv));
            if (match) {
                earned += led.earned[@intFromEnum(cv)];
                spent += led.spent[@intFromEnum(cv)];
            }
        }
        if (std.mem.indexOf(u8, typ, "xpense") != null or std.mem.indexOf(u8, typ, "pent") != null) return spent;
        if (std.mem.eql(u8, typ, "profit")) return earned - spent;
        return earned;
    }

    fn scenGiveCash(ctx: *anyopaque, amount: f64) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (amount >= 0) self.sim.zoo.earn(.admission, amount) else self.sim.zoo.spend(.supplies, -amount);
    }

    fn installHooks(self: *App) void {
        self.sim.hooks = .{ .ctx = self, .brain = hookBrain, .anim_len = hookAnimLen, .flag = hookFlag, .feeder = hookFeeder, .usable = hookUsable, .wage = hookWage, .venue = hookVenue, .habitat = hookHabitat };
        self.sim.guest_binders = self.guest_names.items;
        self.updateGuestCap();
    }

    fn updateGuestCap(self: *App) void {
        const cap = self.guests_base + self.guests_per_star * self.stars();
        self.sim.max_guests = if (self.arrivals_on) @intFromFloat(cap) else 0;
    }

    // ------------------------------------------------------- virtual input

    fn scancodeFor(name: []const u8) ?u32 {
        if (name.len == 1) {
            const ch = std.ascii.toLower(name[0]);
            if (ch >= 'a' and ch <= 'z') return 4 + @as(u32, ch - 'a');
            if (ch >= '1' and ch <= '9') return 30 + @as(u32, ch - '1');
            if (ch == '0') return 39;
            switch (ch) {
                '[' => return sc.lbracket,
                ']' => return sc.rbracket,
                ',' => return sc.comma,
                '.' => return sc.period,
                else => return null,
            }
        }
        const names = [_]struct { n: []const u8, c: u32 }{
            .{ .n = "tab", .c = sc.tab },
            .{ .n = "delete", .c = sc.delete },
            .{ .n = "esc", .c = 41 },
            .{ .n = "enter", .c = 40 },
            .{ .n = "space", .c = 44 },
            .{ .n = "backspace", .c = 42 },
            .{ .n = "f5", .c = sc.f5 },
            .{ .n = "f9", .c = sc.f9 },
            .{ .n = "f10", .c = sc.f10 },
            .{ .n = "f1", .c = sc.f1 },
            .{ .n = "f2", .c = sc.f2 },
            .{ .n = "f3", .c = sc.f3 },
            .{ .n = "shift", .c = sc.lshift },
        };
        for (names) |e| if (std.ascii.eqlIgnoreCase(e.n, name)) return e.c;
        return null;
    }

    fn splitInput(self: *App, text: []const u8) !void {
        var it = std.mem.tokenizeScalar(u8, text, ';');
        while (it.next()) |c| {
            const t = std.mem.trim(u8, c, " \t\r\n");
            if (t.len > 0) try self.input_cmds.append(self.gpa, t);
        }
    }

    /// Runs the next virtual-input action (one per frame).
    fn playInput(self: *App, ctx: *viewer.FrameCtx) void {
        if (self.wait_frames > 0) {
            self.wait_frames -= 1;
            return;
        }
        if (self.input_i >= self.input_cmds.items.len) {
            if (self.input_cmds.items.len > 0) {
                self.input_cmds.clearRetainingCapacity();
                self.input_i = 0;
                // Script done: take the requested screenshot, if any.
                if (self.opts.viewer.screenshot != null) ctx.shot_request = true;
            }
            return;
        }
        const cmd = self.input_cmds.items[self.input_i];
        self.input_i += 1;
        self.runInput(cmd, ctx) catch |e| self.say("input '{s}' failed: {s}", .{ cmd, @errorName(e) });
    }

    fn runInput(self: *App, cmd: []const u8, ctx: *viewer.FrameCtx) !void {
        var it = std.mem.tokenizeScalar(u8, cmd, ' ');
        const verb = it.next() orelse return;
        const plat = ctx.plat;
        if (std.mem.eql(u8, verb, "move")) {
            self.vmouse = .{ try num(it.next()), try num(it.next()) };
            plat.injectEvent(.{ .mouse_move = .{ .x = self.vmouse[0], .y = self.vmouse[1] } });
        } else if (std.mem.eql(u8, verb, "at")) {
            const x = try num(it.next());
            const y = try num(it.next());
            const z = if (it.next()) |zt| try std.fmt.parseFloat(f32, zt) else self.world.terrain.zAt(x, y);
            const p = ctx.cam.project(.{ x, y, z }, @floatFromInt(ctx.win_width), @floatFromInt(ctx.win_height)) orelse return error.BehindCamera;
            self.vmouse = p;
            plat.injectEvent(.{ .mouse_move = .{ .x = p[0], .y = p[1] } });
        } else if (std.mem.eql(u8, verb, "down") or std.mem.eql(u8, verb, "up") or std.mem.eql(u8, verb, "click")) {
            const b: u8 = if (it.next()) |t| @intCast(try std.fmt.parseInt(u8, t, 10)) else 1;
            if (!std.mem.eql(u8, verb, "up")) plat.injectEvent(.{ .mouse_button = .{ .button = b, .down = true, .x = self.vmouse[0], .y = self.vmouse[1] } });
            if (!std.mem.eql(u8, verb, "down")) plat.injectEvent(.{ .mouse_button = .{ .button = b, .down = false, .x = self.vmouse[0], .y = self.vmouse[1] } });
        } else if (std.mem.eql(u8, verb, "key") or std.mem.eql(u8, verb, "keydown") or std.mem.eql(u8, verb, "keyup")) {
            const name = it.next() orelse return error.BadScript;
            const code = scancodeFor(name) orelse return error.UnknownKey;
            if (!std.mem.eql(u8, verb, "keyup")) plat.injectEvent(.{ .key_down = .{ .scancode = code, .repeat = false } });
            if (!std.mem.eql(u8, verb, "keydown")) plat.injectEvent(.{ .key_up = .{ .scancode = code } });
        } else if (std.mem.eql(u8, verb, "wheel")) {
            plat.injectEvent(.{ .mouse_wheel = .{ .dx = 0, .dy = try num(it.next()) } });
        } else if (std.mem.eql(u8, verb, "wait")) {
            self.wait_frames = @intFromFloat(try num(it.next()));
        } else if (std.mem.eql(u8, verb, "cam")) {
            ctx.cam.yaw = try num(it.next());
            ctx.cam.pitch = try num(it.next());
            ctx.cam.dist = try num(it.next());
            ctx.snap_camera = true;
            if (it.next()) |cx| {
                ctx.cam.center[0] = try std.fmt.parseFloat(f32, cx);
                ctx.cam.center[1] = try num(it.next());
                ctx.cam.center[2] = self.world.terrain.zAt(ctx.cam.center[0], ctx.cam.center[1]);
            }
        } else if (std.mem.eql(u8, verb, "info")) {
            const w = &self.world;
            var sel_buf: [48]u8 = undefined;
            const sel = if (self.selected) |sl| std.fmt.bufPrint(&sel_buf, "{s}#{d}", .{ @tagName(sl.kind), sl.id }) catch "?" else "none";
            std.debug.print("info: tool={s} props={d} fences={d} paths={d} actors={d} selected={s} hover={s} paused={}\n", .{
                @tagName(self.tool), w.props.items.len, w.fences.items.len, w.paths.items.len, w.actors.items.len, sel,
                if (self.hover != null) "yes" else "no",                self.paused,
            });
            for (self.sim.agents.items[0..@min(self.sim.agents.items.len, 6)]) |ag| {
                std.debug.print("agent #{d}: {s} speed={d:.2} state={s} anim={s} brain={}\n", .{ ag.id, @tagName(ag.kind), ag.speed, @tagName(ag.state), ag.anim_name, ag.brain != null });
                if (ag.brain) |b| if (b.task) |ti| std.debug.print("  task: {s}\n", .{b.lib.tasks.items[ti].name});
                if (ag.habitat != null) std.debug.print("  habitat {d:.0} biome {d:.0} space {d:.0} ({d:.0}/{d:.0} tiles, open={})\n", .{ ag.hab_score, ag.hab_biome, ag.hab_space, ag.hab_area, ag.hab_need, ag.hab_open });
            }
            for (self.sim.feeders.items) |f| std.debug.print("feeder #{d} {s}: food {d:.0}\n", .{ f.prop_id, f.binder, f.food });
            std.debug.print("animal welfare: {d:.0}\n", .{self.sim.animalWelfare()});
            for (self.hits.items) |hh| std.debug.print("  hit {d:.0},{d:.0} {d:.0}x{d:.0}\n", .{ hh.x, hh.y, hh.w, hh.h });
            if (self.ui_state) |*us| {
                var uit = us.map.iterator();
                while (uit.next()) |kv| if (kv.value_ptr.visible != null or kv.value_ptr.text.len > 0 or kv.value_ptr.pos != null) std.debug.print("  ui {s}: visible={any} pos={any} size={any} text='{s}'\n", .{ kv.key_ptr.*, kv.value_ptr.visible, kv.value_ptr.pos, kv.value_ptr.size, kv.value_ptr.text[0..@min(kv.value_ptr.text.len, 50)] });
            }
            if (self.scen) |m| {
                const Dump = struct {
                    fn node(mm: *scenario_mod.Manager, n: *const scenario_mod.Node, depth: usize) void {
                        std.debug.print("  scenario:", .{});
                        for (0..depth + 1) |_| std.debug.print("  ", .{});
                        std.debug.print("{s} {s} [{s}]{s}\n", .{ if (n.is_group) "group" else "rule", n.name, @tagName(n.state), if (n.hidden) " hidden" else "" });
                        for (n.children) |k| node(mm, k, depth + 1);
                    }
                };
                for (m.roots.items) |r| Dump.node(m, r, 0);
                if (m.eng.missing.count() > 0) {
                    std.debug.print("  scenario: missing:", .{});
                    for (m.eng.missing.keys(), m.eng.missing.values()) |k, v| std.debug.print(" {s}({d})", .{ k, v });
                    std.debug.print("\n", .{});
                }
            }
            if (self.audio) |*au| {
                var live: usize = 0;
                for (au.voices) |v| if (v != null) {
                    live += 1;
                };
                std.debug.print("audio: tags={d} device={} on={} voices={d} played={d} last={s} biome={s}\n", .{ au.lib.tags.count(), au.hasDevice(), au.enabled, live, au.played, au.last_tag, au.ambient_biome });
            }
            std.debug.print("perf: {d:.1} fps ({d} static draws, {d} actor draws)\n", .{ if (ctx.dt > 0) 1.0 / ctx.dt else 0.0, self.scene.draws.items.len, self.scene.actor_draws.items.len });
            std.debug.print("zoo: guests={d} total={d} left={d} income={d:.0} views={d} happy={d:.0}\n", .{
                self.sim.liveGuests(), self.sim.zoo.guests_total, self.sim.zoo.guests_left, self.sim.zoo.income, self.sim.zoo.views, self.sim.happiness(),
            });
            std.debug.print("cam: yaw={d:.3} pitch={d:.3} dist={d:.2} center=({d:.1},{d:.1})\n", .{ ctx.cam.yaw, ctx.cam.pitch, ctx.cam.dist, ctx.cam.center[0], ctx.cam.center[1] });
        } else if (std.mem.eql(u8, verb, "shot")) {
            ctx.shot_request = true;
        } else if (std.mem.eql(u8, verb, "quit")) {
            ctx.quit = true;
        } else return self.runCommand(cmd);
    }

    // ------------------------------------------------------------- events

    const phase_times = [_]f32{ 0.0, 0.07, 0.13, 0.42, 0.7, 0.9 };
    const phase_names = [_][]const u8{ "NIGHT", "SUNRISE", "MORNING", "NOON", "AFTERNOON", "SUNSET" };

    fn phaseIndex(tod: f32) usize {
        var idx: usize = 0;
        for (phase_times, 0..) |pt, i| if (pt <= tod + 1e-4) {
            idx = i;
        };
        return idx;
    }

    /// Moves the clock to the previous or next named part of the day.
    fn jumpPhase(self: *App, delta: i32) void {
        const n: i32 = phase_times.len;
        const cur: i32 = @intCast(phaseIndex(self.tod));
        // If between phases, "next" goes forward and "previous" snaps back to this one.
        var target = cur + delta;
        if (delta < 0 and self.tod > phase_times[@intCast(cur)] + 0.01) target = cur;
        target = @mod(target, n);
        self.tod = phase_times[@intCast(target)];
        self.say("time: {s}", .{phase_names[@intCast(target)]});
    }

    fn cycle(i: *usize, len: usize, delta: i32) void {
        if (len == 0) return;
        const n: i64 = @intCast(len);
        i.* = @intCast(@mod(@as(i64, @intCast(i.*)) + delta, n));
    }

    fn stepItem(self: *App, delta: i32) void {
        const d: i32 = if (self.shift) delta * 10 else delta;
        switch (self.tool) {
            .prop => cycle(&self.prop_i, self.props.items.len, d),
            .fence => {
                // Skip fence types that have no straight-segment model.
                var tries: usize = 0;
                while (tries < self.fence_kinds.items.len) : (tries += 1) {
                    cycle(&self.fence_i, self.fence_kinds.items.len, if (d < 0) -1 else 1);
                    const pieces = self.scene.fenceModels(self.fence_kinds.items[self.fence_i]) catch break;
                    if (pieces.segment != null) break;
                }
            },
            .path => cycle(&self.path_i, self.path_textures.items.len, d),
            .food => cycle(&self.food_i, self.food_names.items.len, d),
            .actor => {
                var tries: usize = 0;
                var dd = d;
                while (tries < 40) : (tries += 1) {
                    cycle(&self.actor_i, self.actor_names.items.len, dd);
                    if (self.actorDef(self.actor_names.items[self.actor_i]) != null) break;
                    dd = if (d < 0) -1 else 1;
                }
            },
            else => {},
        }
        self.title_dirty = true;
    }

    pub fn event(self: *App, ev: platform.Event, ctx: *viewer.FrameCtx) void {
        if (self.menu != .none) return self.menuEvent(ev, ctx);
        // Escape opens the pause menu instead of quitting.
        switch (ev) {
            .key_down => |k| if (!k.repeat and k.scancode == sc.esc) {
                if (self.challengeOpen()) {
                    self.menuAction(.challenge_decline, ctx);
                } else self.openMenu(.pause);
                ctx.consumed = true;
                return;
            },
            else => {},
        }
        switch (ev) {
            .key_down => |k| {
                if (k.repeat) return;
                switch (k.scancode) {
                    sc.lshift, sc.rshift => self.shift = true,
                    sc.tab => {
                        self.paused = !self.paused;
                        self.title_dirty = true;
                    },
                    sc.period => {
                        self.speed = @min(self.speed * 2, 16);
                        self.title_dirty = true;
                    },
                    sc.comma => {
                        self.speed = @max(self.speed / 2, 0.25);
                        self.title_dirty = true;
                    },
                    sc.f1 => self.show_help = !self.show_help,
                    sc.m => self.toggleSound(),
                    sc.b => {
                        self.status_tab = 1;
                        self.openMenu(if (self.menu == .finances) .none else .finances);
                    },
                    sc.i => {
                        self.status_tab = 0;
                        self.openMenu(if (self.menu == .finances) .none else .finances);
                    },
                    sc.t => {
                        self.tod_auto = !self.tod_auto;
                        self.say("time of day {s}", .{if (self.tod_auto) "running" else "stopped"});
                    },
                    sc.g => {
                        self.arrivals_on = !self.arrivals_on;
                        self.updateGuestCap();
                        self.say("guest arrivals {s}", .{if (self.arrivals_on) "on" else "off"});
                    },
                    sc.f2 => self.jumpPhase(-1),
                    sc.f3 => self.jumpPhase(1),
                    sc.f5 => self.saveWorld() catch |e| self.say("save failed: {s}", .{@errorName(e)}),
                    sc.f9 => self.loadSaved() catch |e| self.say("load failed: {s}", .{@errorName(e)}),
                    else => if (self.opts.tools) self.toolKey(k.scancode),
                }
            },
            .key_up => |k| switch (k.scancode) {
                sc.lshift, sc.rshift => self.shift = false,
                else => {},
            },
            .mouse_wheel => |w| if (self.opts.tools and self.over_ui and w.dy != 0) {
                const mp = toPixels(ctx, ctx.mouse[0], ctx.mouse[1]);
                const br = self.buy_rect;
                if (self.hudActive() and self.buy_cat != null and mp[0] >= br[0] and mp[0] < br[0] + br[2] and mp[1] >= br[1] and mp[1] < br[1] + br[3]) {
                    if (w.dy > 0) self.buy_scroll -|= 1 else self.buy_scroll += 1;
                } else if (!self.hudActive()) {
                    // Scrolling over the item list moves through the items.
                    self.stepItemBy(if (w.dy > 0) -1 else 1);
                }
                ctx.consumed = true;
            },
            .mouse_button => |b| if (self.opts.tools and b.button == 1) {
                if (b.down) {
                    if (self.uiClick(b.x, b.y, ctx)) {
                        ctx.consumed = true;
                        return;
                    }
                    self.lmb = true;
                    self.click(ctx);
                } else {
                    self.lmb = false;
                    if (self.brush_touched) self.resettle();
                }
            },
            else => {},
        }
    }

    // ---------------------------------------------------------------- menus

    const MapScan = struct {
        app: *App,
        fn add(self: MapScan, path: []const u8) anyerror!void {
            if (!std.mem.startsWith(u8, path, "maps/") or !std.mem.endsWith(u8, path, ".zt2")) return;
            const a = self.app;
            const ar = a.save_arena.allocator();
            try a.map_paths.append(a.gpa, try ar.dupe(u8, path));
        }
    };

    fn lessLabel(_: void, a: []const u8, b: []const u8) bool {
        // Default maps before scenario maps, then alphabetical.
        const a_scen = std.mem.indexOf(u8, a, "/scenario/") != null;
        const b_scen = std.mem.indexOf(u8, b, "/scenario/") != null;
        if (a_scen != b_scen) return !a_scen;
        return std.mem.lessThan(u8, a, b);
    }

    /// Lists the maps in the game data.
    fn buildMapList(self: *App) !void {
        self.map_paths.clearRetainingCapacity();
        self.map_labels.clearRetainingCapacity();
        try self.vfs.forEach(MapScan{ .app = self }, MapScan.add);
        std.mem.sort([]const u8, self.map_paths.items, {}, lessLabel);
        const ar = self.save_arena.allocator();
        for (self.map_paths.items) |p| {
            const base = std.fs.path.basename(p);
            const stem = base[0 .. base.len - 4];
            if (std.mem.eql(u8, stem, "nomap")) continue;
            const label = try std.fmt.allocPrint(ar, "{s}{s}", .{ if (std.mem.indexOf(u8, p, "/scenario/") != null) "scenario: " else "", stem });
            try self.map_labels.append(self.gpa, label);
        }
        // Drop the placeholder from the path list too so indexes line up.
        var i: usize = 0;
        while (i < self.map_paths.items.len) {
            if (std.mem.endsWith(u8, self.map_paths.items[i], "/nomap.zt2")) _ = self.map_paths.orderedRemove(i) else i += 1;
        }
    }

    /// Lists the saves on disk.
    fn buildSaveList(self: *App) void {
        self.save_paths.clearRetainingCapacity();
        self.save_labels.clearRetainingCapacity();
        self.save_info.clearRetainingCapacity();
        self.confirm_delete = null;
        const ar = self.save_arena.allocator();
        const now = Io.Timestamp.now(self.io, .real);
        var dir = Io.Dir.cwd().openDir(self.io, self.opts.save_dir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |e| {
            if (e.kind != .file or !std.ascii.endsWithIgnoreCase(e.name, ".zt2")) continue;
            const full = std.fs.path.join(ar, &.{ self.opts.save_dir, e.name }) catch continue;
            const label = ar.dupe(u8, e.name[0 .. e.name.len - 4]) catch continue;
            // When it was saved and how big it is (the terrain file included).
            var info: []const u8 = "";
            if (Io.Dir.cwd().statFile(self.io, full, .{})) |st| {
                const age_s: i64 = @intCast(@divTrunc(now.nanoseconds - st.mtime.nanoseconds, std.time.ns_per_s));
                var size: u64 = st.size;
                var dat_buf: [512]u8 = undefined;
                if (std.fmt.bufPrint(&dat_buf, "{s}.dat", .{full[0 .. full.len - 4]})) |dp| {
                    if (Io.Dir.cwd().statFile(self.io, dp, .{})) |ds| size += ds.size else |_| {}
                } else |_| {}
                var tb: [64]u8 = undefined;
                const when: []const u8 = if (age_s < 90)
                    "JUST NOW"
                else if (age_s < 3600)
                    std.fmt.bufPrint(&tb, "{d} MIN AGO", .{@divTrunc(age_s, 60)}) catch ""
                else if (age_s < 172800)
                    std.fmt.bufPrint(&tb, "{d} HOURS AGO", .{@divTrunc(age_s, 3600)}) catch ""
                else
                    std.fmt.bufPrint(&tb, "{d} DAYS AGO", .{@divTrunc(age_s, 86400)}) catch "";
                var ib: [96]u8 = undefined;
                const mb = @as(f64, @floatFromInt(size)) / (1024.0 * 1024.0);
                info = ar.dupe(u8, std.fmt.bufPrint(&ib, "{s}  {d:.1} MB", .{ when, mb }) catch "") catch "";
            } else |_| {}
            self.save_paths.append(self.gpa, full) catch continue;
            self.save_labels.append(self.gpa, label) catch continue;
            self.save_info.append(self.gpa, info) catch {
                _ = self.save_paths.pop();
                _ = self.save_labels.pop();
                continue;
            };
        }
        // Alphabetical, keeping paths and labels together.
        const n = self.save_labels.items.len;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            var j = i;
            while (j > 0 and std.ascii.lessThanIgnoreCase(self.save_labels.items[j], self.save_labels.items[j - 1])) : (j -= 1) {
                std.mem.swap([]const u8, &self.save_labels.items[j], &self.save_labels.items[j - 1]);
                std.mem.swap([]const u8, &self.save_paths.items[j], &self.save_paths.items[j - 1]);
                std.mem.swap([]const u8, &self.save_info.items[j], &self.save_info.items[j - 1]);
            }
        }
    }

    /// Removes a save (its zoo file and terrain file) after a second click.
    fn deleteSave(self: *App, i: usize) void {
        if (i >= self.save_paths.items.len) return;
        if (self.confirm_delete == null or self.confirm_delete.? != i) {
            self.confirm_delete = i;
            return;
        }
        const path = self.save_paths.items[i];
        const cwd = Io.Dir.cwd();
        cwd.deleteFile(self.io, path) catch |e| {
            self.say("could not delete ({s})", .{@errorName(e)});
            return;
        };
        var dat_buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&dat_buf, "{s}.dat", .{path[0 .. path.len - 4]})) |dp| cwd.deleteFile(self.io, dp) catch {} else |_| {}
        self.say("deleted save {s}", .{self.save_labels.items[i]});
        self.buildSaveList();
    }

    fn openMenu(self: *App, m: Menu) void {
        if (m == .main) self.in_main = true;
        if (m == .none or m == .pause) self.in_main = false;
        self.menu = m;
        self.menu_first = 0;
        if (m == .saves) self.buildSaveList();
        self.lmb = false;
    }

    fn menuAction(self: *App, a: MenuAction, ctx: *viewer.FrameCtx) void {
        switch (a) {
            .close_menu => self.openMenu(.none),
            .save => {
                self.saveWorld() catch |e| self.say("save failed: {s}", .{@errorName(e)});
                self.openMenu(.none);
            },
            .price_up => {
                self.sim.adult_price = @min(100, self.sim.adult_price + 2);
                self.sim.child_price = @round(self.sim.adult_price / 2);
            },
            .price_down => {
                self.sim.adult_price = @max(0, self.sim.adult_price - 2);
                self.sim.child_price = @round(self.sim.adult_price / 2);
            },
            .open_status => self.openMenu(.finances),
            .open_main => self.openMenu(.main),
            .open_save_as => {
                var nb: [64]u8 = undefined;
                const cur = self.saveName(&nb);
                const n = @min(cur.len, self.name_buf.len);
                @memcpy(self.name_buf[0..n], cur[0..n]);
                self.name_len = n;
                self.openMenu(.save_as);
                self.buildSaveList();
            },
            .confirm_save_as => {
                if (self.name_len == 0) return self.say("type a name first", .{});
                self.setCustomName(self.name_buf[0..self.name_len]);
                self.saveWorld() catch |e| self.say("save failed: {s}", .{@errorName(e)});
                self.openMenu(.none);
            },
            .open_saves => self.openMenu(.saves),
            .open_maps => self.openMenu(.maps),
            .open_settings => self.openMenu(.settings),
            .gender_male, .gender_female => {
                self.buy_female = a == .gender_female;
                self.buy_scroll = 0;
                self.buildBuyLists();
            },
            .tutorial_continue => self.pressContinue(),
            .open_challenge => {
                self.challenge_next = true;
                self.openMenu(.maps);
            },
            .challenge_accept, .challenge_decline => if (self.ui_state) |*us| {
                if (self.scen) |m| m.setVar("challenge", if (a == .challenge_accept) "accept" else "decline");
                for ([_][]const u8{ "challenge layout", "instant challenge layout", "branch layout" }) |n| us.at(n).visible = false;
            },
            .open_goals => self.openMenu(.goals),
            .open_campaigns => {
                self.loadCampaigns();
                self.openMenu(.campaigns);
            },
            .open_finances => {
                self.status_tab = 1;
                self.openMenu(.finances);
            },
            .open_pause => self.openMenu(.pause),
            .toggle_pause => {
                self.paused = !self.paused;
                self.title_dirty = true;
            },
            .undo => self.doUndo(),
            .zoom_in => {
                ctx.cam.dist = @max(3, ctx.cam.dist * 0.8);
                ctx.snap_camera = true;
            },
            .zoom_out => {
                ctx.cam.dist = @min(ctx.cam.radius * 20, ctx.cam.dist * 1.25);
                ctx.snap_camera = true;
            },
            .rot_left => {
                ctx.cam.yaw -= 0.35;
                ctx.snap_camera = true;
            },
            .rot_right => {
                ctx.cam.yaw += 0.35;
                ctx.snap_camera = true;
            },
            .open_new_zoo => self.openMenu(.new_zoo),
            .new_zoo_size => self.nz_size = @intCast((self.nz_size + 1) % zoo_sizes.len),
            .new_zoo_biome => self.nz_biome = @intCast((self.nz_biome + 1) % zoo_biomes.len),
            .new_zoo_start => {
                self.startBlankZoo();
                self.openMenu(.none);
                self.maybeStartChallenge();
            },
            .ui_size => {
                self.ui_zoom = if (self.ui_zoom < 1.2) 1.25 else if (self.ui_zoom < 1.4) 1.5 else if (self.ui_zoom < 1.8) 2.0 else 1.0;
            },
            .toggle_delete => {
                self.delete_mode = !self.delete_mode;
                if (self.delete_mode) {
                    self.tool = .select;
                    self.buy_cat = null;
                    self.say("delete mode: click something to remove it", .{});
                }
            },
            .close_selection => {
                self.selected = null;
                self.track_id = null;
            },
            .track_camera => {
                if (self.selected) |sel| self.track_id = if (self.track_id != null) null else sel.id;
            },
            .toggle_hud => {
                self.hud_on = !self.hud_on;
                self.show_help = !self.hud_on;
            },
            .back => self.openMenu(if (self.menu == .scenarios) .campaigns else if (self.in_main) .main else .pause),
            .quit => ctx.quit = true,
            .toggle_help => self.show_help = !self.show_help,
            .toggle_arrivals => {
                self.arrivals_on = !self.arrivals_on;
                self.updateGuestCap();
            },
            .toggle_clock => self.tod_auto = !self.tod_auto,
            .toggle_sound => self.toggleSound(),
            .toggle_modern => self.scene.fx.modern = !self.scene.fx.modern,
            .toggle_shadows => self.scene.fx.shadows = !self.scene.fx.shadows,
            .toggle_ssao => self.scene.fx.ssao = !self.scene.fx.ssao,
            .toggle_bloom => self.scene.fx.bloom = !self.scene.fx.bloom,
            .toggle_fxaa => self.scene.fx.fxaa = !self.scene.fx.fxaa,
            .speed_up => self.speed = @min(self.speed * 2, 16),
            .speed_down => self.speed = @max(self.speed / 2, 0.25),
            .delete_selected => self.deleteSelected(),
            .refill_selected => self.refill(),
        }
    }

    fn entryAction(self: *App, i: usize) void {
        switch (self.menu) {
            .maps => if (i < self.map_paths.items.len) {
                self.loadPath(self.map_paths.items[i]) catch {};
                self.custom_len = 0;
                self.openMenu(.none);
                self.maybeStartChallenge();
            },
            .campaigns => if (i < self.campaigns.items.len) {
                self.camp_sel = i;
                self.buildScenarioLabels();
                self.openMenu(.scenarios);
            },
            .scenarios => {
                const cp = self.campaigns.items[self.camp_sel];
                if (i < cp.entries.len) {
                    if (self.entryOpen(cp, i)) self.startCampaignEntry(cp.entries[i]) else self.say("finish the scenario before it first", .{});
                }
            },
            .saves => if (i < self.save_paths.items.len) {
                self.loadPath(self.save_paths.items[i]) catch {};
                self.setCustomName(self.save_labels.items[i]);
                self.openMenu(.none);
            },
            else => {},
        }
    }

    /// Events while a menu is open: only the menu reacts.
    fn menuEvent(self: *App, ev: platform.Event, ctx: *viewer.FrameCtx) void {
        ctx.consumed = true;
        switch (ev) {
            .key_down => |k| {
                if (self.menu == .save_as and k.scancode != sc.esc) {
                    if (k.scancode == 42) {
                        if (self.name_len > 0) self.name_len -= 1;
                    } else if (k.scancode == 40 or k.scancode == 88) {
                        if (!k.repeat) self.menuAction(.confirm_save_as, ctx);
                    } else if (typedChar(k.scancode, self.shift)) |ch| {
                        if (self.name_len < self.name_buf.len) {
                            self.name_buf[self.name_len] = ch;
                            self.name_len += 1;
                        }
                    }
                    return;
                }
                if (!k.repeat and k.scancode == sc.o and self.menu == .goals) self.openMenu(.none);
                if (!k.repeat and k.scancode == sc.esc) {
                    switch (self.menu) {
                        .pause => self.openMenu(.none),
                        .main => {},
                        .goals, .result => self.openMenu(.none),
                        else => self.openMenu(if (self.in_main) .main else .pause),
                    }
                }
            },
            .mouse_button => |b| if (b.button == 1 and b.down) {
                const h = self.hitAt(toPixels(ctx, b.x, b.y)) orelse return;
                self.sfx("uiclick");
                switch (h.action) {
                    .menu => |a| self.menuAction(a, ctx),
                    .entry => |i| self.entryAction(i),
                    .del_save => |i| self.deleteSave(i),
                    else => {},
                }
            },
            .mouse_wheel => |w| {
                const n = switch (self.menu) {
                    .maps => self.map_labels.items.len,
                    .saves => self.save_labels.items.len,
                    .campaigns => self.camp_labels.items.len,
                    .scenarios => self.scen_labels.items.len,
                    else => 0,
                };
                if (w.dy > 0 and self.menu_first > 0) self.menu_first -= 1;
                if (w.dy < 0 and self.menu_first + self.menu_rows < n) self.menu_first += 1;
            },
            else => {},
        }
    }


    fn menuButton(self: *App, ui: *viewer.Ui, y: f32, scale: f32, text: []const u8, action: @TypeOf(@as(Hit, undefined).action), on: bool) !f32 {
        const width = 26 * 6 * scale;
        const x = (ui.width - width) / 2;
        const h = 7 * scale + 8 * scale;
        ui.template(if (on) "header" else "buttonbar", x, y, width, h, scale / 2, 1);
        const tw = viewer.Ui.textWidth(text, scale);
        _ = try ui.text(x + (width - tw) / 2 + scale / 2, y + 4 * scale, scale, text, .{ 1, 1, 1, 1 });
        try self.hits.append(self.gpa, .{ .x = x, .y = y, .w = width, .h = h, .action = action });
        return h + 3 * scale;
    }

    fn drawMenu(self: *App, ui: *viewer.Ui, base_scale: f32) !void {
        const scale = base_scale * 1.5;
        try ui.rect(0, 0, ui.width, ui.height, .{ 0, 0, 0, 0.55 });
        const title: []const u8 = switch (self.menu) {
            .pause => "PAUSED",
            .maps => "CHOOSE A MAP",
            .saves => "LOAD A SAVED ZOO",
            .settings => "SETTINGS",
            .finances => "FINANCES",
            .goals => "GOALS",
            .campaigns => "CAMPAIGNS",
            .scenarios => "CHOOSE A SCENARIO",
            .new_zoo => "NEW BLANK ZOO",
            .save_as => "SAVE YOUR ZOO",
            .main => "ZOOTYCON2",
            .result => if (self.scen_result == .won) "SCENARIO COMPLETE!" else "SCENARIO FAILED",
            .none => "",
        };
        if (self.menu == .finances) return self.drawFinances(ui, scale);
        if (self.menu == .goals) return self.drawGoals(ui, scale);
        if (self.menu == .main and self.hud != null) return self.drawMainMenu(ui);
        const tscale = scale * 1.6;
        const tw = viewer.Ui.textWidth(title, tscale);
        var y = ui.height * 0.12;
        _ = try ui.text((ui.width - tw) / 2, y, tscale, title, .{ 1, 0.92, 0.5, 1 });
        y += 7 * tscale + 14 * scale;
        switch (self.menu) {
            .result => {
                y += try self.menuButton(ui, y, scale, "KEEP PLAYING", .{ .menu = .close_menu }, false);
                y += try self.menuButton(ui, y, scale, "CAMPAIGNS", .{ .menu = .open_campaigns }, false);
                y += try self.menuButton(ui, y, scale, "MAIN MENU", .{ .menu = .open_main }, false);
            },
            .pause => {
                y += try self.menuButton(ui, y, scale, "RESUME", .{ .menu = .close_menu }, false);
                y += try self.menuButton(ui, y, scale, "SAVE GAME...", .{ .menu = .open_save_as }, false);
                y += try self.menuButton(ui, y, scale, "LOAD GAME", .{ .menu = .open_saves }, false);
                y += try self.menuButton(ui, y, scale, "NEW MAP", .{ .menu = .open_maps }, false);
                y += try self.menuButton(ui, y, scale, "CAMPAIGNS", .{ .menu = .open_campaigns }, false);
                y += try self.menuButton(ui, y, scale, "CHALLENGE MODE", .{ .menu = .open_challenge }, false);
                y += try self.menuButton(ui, y, scale, "MAIN MENU", .{ .menu = .open_main }, false);
                y += try self.menuButton(ui, y, scale, "SETTINGS", .{ .menu = .open_settings }, false);
                y += try self.menuButton(ui, y, scale, "QUIT", .{ .menu = .quit }, false);
            },
            .maps, .saves, .campaigns, .scenarios => {
                const labels = switch (self.menu) {
                    .maps => self.map_labels.items,
                    .campaigns => self.camp_labels.items,
                    .scenarios => self.scen_labels.items,
                    else => self.save_labels.items,
                };
                if (labels.len == 0) {
                    const msg = if (self.menu == .maps) "NO MAPS FOUND" else "NO SAVED ZOOS YET";
                    const mw = viewer.Ui.textWidth(msg, scale);
                    _ = try ui.text((ui.width - mw) / 2, y, scale, msg, .{ 0.8, 0.85, 0.9, 1 });
                    y += 14 * scale;
                }
                if (self.menu == .maps) y += try self.menuButton(ui, y, scale, "NEW BLANK ZOO (CHOOSE SIZE)...", .{ .menu = .open_new_zoo }, true);
                // As many rows as fit between the title and the Back button.
                const row_h = 18 * scale * 0.8;
                const room = ui.height - y - 40 * scale;
                self.menu_rows = @max(3, @as(usize, @intFromFloat(@max(0, room / row_h))));
                if (self.menu_first + self.menu_rows > labels.len) self.menu_first = labels.len -| self.menu_rows;
                const first = self.menu_first;
                const last = @min(labels.len, first + self.menu_rows);
                var i = first;
                while (i < last) : (i += 1) {
                    const rs = scale * 0.8;
                    const h = try self.menuButton(ui, y, rs, labels[i], .{ .entry = i }, false);
                    if (self.menu == .saves and i < self.save_info.items.len) {
                        const bw = 26 * 6 * rs;
                        const bx = (ui.width - bw) / 2;
                        const ts = rs * 0.75;
                        _ = try ui.text(bx + bw + 8 * rs, y + (h - 7 * ts) / 2 - rs, ts, self.save_info.items[i], .{ 0.8, 0.85, 0.9, 1 });
                        const confirming = self.confirm_delete != null and self.confirm_delete.? == i;
                        const dl: []const u8 = if (confirming) "SURE?" else "DELETE";
                        const dw = 8 * 6 * ts;
                        const dx = bx - dw - 8 * rs;
                        ui.template("buttonbar", dx, y, dw, h - 3 * rs, rs / 2, 1);
                        _ = try ui.text(dx + (dw - viewer.Ui.textWidth(dl, ts)) / 2, y + (h - 3 * rs - 7 * ts) / 2, ts, dl, if (confirming) .{ 1, 0.5, 0.45, 1 } else .{ 1, 0.75, 0.7, 1 });
                        try self.hits.append(self.gpa, .{ .x = dx, .y = y, .w = dw, .h = h - 3 * rs, .action = .{ .del_save = i } });
                    }
                    y += h;
                }
                if (labels.len > self.menu_rows) {
                    var nb: [48]u8 = undefined;
                    const note = std.fmt.bufPrint(&nb, "{d}-{d} OF {d}  (SCROLL WITH THE WHEEL)", .{ first + 1, last, labels.len }) catch "";
                    const nw = viewer.Ui.textWidth(note, scale * 0.7);
                    _ = try ui.text((ui.width - nw) / 2, y + 2 * scale, scale * 0.7, note, .{ 0.8, 0.85, 0.9, 1 });
                    y += 12 * scale;
                }
                y += 6 * scale;
                y += try self.menuButton(ui, y, scale, "BACK", .{ .menu = .back }, false);
            },
            .settings => {
                var b: [48]u8 = undefined;
                y += try self.menuButton(ui, y, scale, std.fmt.bufPrint(&b, "HELP TEXT: {s}", .{if (self.show_help) "ON" else "OFF"}) catch "", .{ .menu = .toggle_help }, self.show_help);
                y += try self.menuButton(ui, y, scale, std.fmt.bufPrint(&b, "GUEST ARRIVALS: {s}", .{if (self.arrivals_on) "ON" else "OFF"}) catch "", .{ .menu = .toggle_arrivals }, self.arrivals_on);
                y += try self.menuButton(ui, y, scale, std.fmt.bufPrint(&b, "DAY/NIGHT CLOCK: {s}", .{if (self.tod_auto) "RUNNING" else "STOPPED"}) catch "", .{ .menu = .toggle_clock }, self.tod_auto);
 y += try self.menuButton(ui, y, scale, std.fmt.bufPrint(&b, "UI SIZE: {d:.0}%  (CLICK TO CHANGE)", .{self.ui_zoom * 100}) catch "", .{ .menu = .ui_size }, false);
                y += try self.menuButton(ui, y, scale, std.fmt.bufPrint(&b, "GAME HUD: {s}", .{if (self.hud_on) "ON" else "OFF"}) catch "", .{ .menu = .toggle_hud }, self.hud_on);
                y += try self.menuButton(ui, y, scale, std.fmt.bufPrint(&b, "SOUND: {s}", .{if (self.soundOn()) "ON" else "OFF"}) catch "", .{ .menu = .toggle_sound }, self.soundOn());
                y += try self.menuButton(ui, y, scale, std.fmt.bufPrint(&b, "MODERN LIGHTING: {s}", .{if (self.scene.fx.modern) "ON" else "OFF"}) catch "", .{ .menu = .toggle_modern }, self.scene.fx.modern);
                y += try self.menuButton(ui, y, scale, std.fmt.bufPrint(&b, "SUN SHADOWS: {s}", .{if (self.scene.fx.shadows) "ON" else "OFF"}) catch "", .{ .menu = .toggle_shadows }, self.scene.fx.shadows);
                y += try self.menuButton(ui, y, scale, std.fmt.bufPrint(&b, "AMBIENT OCCLUSION: {s}", .{if (self.scene.fx.ssao) "ON" else "OFF"}) catch "", .{ .menu = .toggle_ssao }, self.scene.fx.ssao);
                y += try self.menuButton(ui, y, scale, std.fmt.bufPrint(&b, "BLOOM: {s}", .{if (self.scene.fx.bloom) "ON" else "OFF"}) catch "", .{ .menu = .toggle_bloom }, self.scene.fx.bloom);
                y += try self.menuButton(ui, y, scale, std.fmt.bufPrint(&b, "EDGE SMOOTHING: {s}", .{if (self.scene.fx.fxaa) "ON" else "OFF"}) catch "", .{ .menu = .toggle_fxaa }, self.scene.fx.fxaa);
                y += try self.menuButton(ui, y, scale, std.fmt.bufPrint(&b, "SIM SPEED: X{d:.2}  (CLICK: FASTER)", .{self.speed}) catch "", .{ .menu = .speed_up }, false);
                y += try self.menuButton(ui, y, scale, "SIM SPEED: SLOWER", .{ .menu = .speed_down }, false);
                y += 6 * scale;
                y += try self.menuButton(ui, y, scale, "BACK", .{ .menu = .back }, false);
            },
            .new_zoo => {
                var b: [96]u8 = undefined;
                y += try self.menuButton(ui, y, scale, std.fmt.bufPrint(&b, "SIZE: {s}", .{zoo_sizes[self.nz_size].name}) catch "", .{ .menu = .new_zoo_size }, false);
                y += try self.menuButton(ui, y, scale, std.fmt.bufPrint(&b, "BIOME: {s}", .{terrain_mod.blank_biomes[zoo_biomes[self.nz_biome]]}) catch "", .{ .menu = .new_zoo_biome }, false);
                y += 6 * scale;
                y += try self.menuButton(ui, y, scale, "START", .{ .menu = .new_zoo_start }, true);
                y += try self.menuButton(ui, y, scale, "BACK", .{ .menu = .open_maps }, false);
            },
            .save_as => {
                const label = "NAME YOUR SAVE, THEN PRESS ENTER";
                const lw = viewer.Ui.textWidth(label, scale);
                _ = try ui.text((ui.width - lw) / 2, y, scale, label, .{ 0.8, 0.85, 0.9, 1 });
                y += 12 * scale;
                const bw = 30 * 6 * scale;
                const bx = (ui.width - bw) / 2;
                const bh = 7 * scale + 10 * scale;
                ui.template("displayfield", bx, y, bw, bh, scale / 2, 1.5);
                var shown: [48]u8 = undefined;
                const caret: []const u8 = if ((self.blink / 30) % 2 == 0) "_" else " ";
                const txt = std.fmt.bufPrint(&shown, "{s}{s}", .{ self.name_buf[0..self.name_len], caret }) catch "";
                _ = try ui.text(bx + 5 * scale, y + 5 * scale, scale, txt, .{ 1, 1, 1, 1 });
                y += bh + 6 * scale;
                // Warn when this would replace an existing save.
                for (self.save_labels.items) |l| if (std.ascii.eqlIgnoreCase(l, self.name_buf[0..self.name_len])) {
                    const warn = "THIS REPLACES AN EXISTING SAVE";
                    const ww = viewer.Ui.textWidth(warn, scale * 0.8);
                    _ = try ui.text((ui.width - ww) / 2, y, scale * 0.8, warn, .{ 1, 0.7, 0.5, 1 });
                    y += 10 * scale;
                    break;
                };
                y += 4 * scale;
                y += try self.menuButton(ui, y, scale, "SAVE", .{ .menu = .confirm_save_as }, true);
                y += try self.menuButton(ui, y, scale, "CANCEL", .{ .menu = .back }, false);
            },
            .main => {
                y += try self.menuButton(ui, y, scale, "PLAY A FREEFORM ZOO", .{ .menu = .open_maps }, true);
                y += try self.menuButton(ui, y, scale, "LOAD A SAVED ZOO", .{ .menu = .open_saves }, false);
                y += try self.menuButton(ui, y, scale, "OPTIONS", .{ .menu = .open_settings }, false);
                y += try self.menuButton(ui, y, scale, "QUIT", .{ .menu = .quit }, false);
            },
            .finances, .goals, .none => {},
        }
    }

    /// How far the right-hand panels move down to clear the game's money display.
    fn hudRightShift(self: *const App, ui: *const viewer.Ui) f32 {
        return if (self.hudActive()) 58 * self.canvas(ui).scale else 0;
    }


    // ------------------------------------------------------------ buy panel

    fn buildBuyLists(self: *App) void {
        for (&self.buy_lists) |*l| l.clearRetainingCapacity();
        const add = struct {
            fn f(a: *App, t: BuyTab, i: usize) void {
                a.buy_lists[@intFromEnum(t)].append(a.gpa, @intCast(i)) catch {};
            }
        }.f;
        for (0..self.fence_kinds.items.len) |i| add(self, .fence, i);
        for (0..self.path_textures.items.len) |i| add(self, .path, i);
        for (self.food_names.items, 0..) |n, i| {
            // Water-only feeders (reefs, buoys) need a water surface we do not have yet.
            const aquatic = std.ascii.startsWithIgnoreCase(n, "artificialreef") or std.ascii.startsWithIgnoreCase(n, "buoy");
            if (self.feederKind(n) != null and !aquatic) add(self, .food, i);
        }
        // Buildings, scenery, toys, shelters, trees, plants and rocks come straight
        // from the entity data, sorted by name, when they have a model to place.
        self.item_names.clearRetainingCapacity();
        var names: std.ArrayList(struct { name: []const u8, tab: BuyTab }) = .empty;
        defer names.deinit(self.gpa);
        const ca = self.catalog_arena.allocator();
        var bit = self.reg.binders.valueIterator();
        while (bit.next()) |b| {
            const bd = b.*;
            if (bd.abstract or bd.type_path.len < 2) continue;
            const kind = bd.type_path[1];
            const eq = std.ascii.eqlIgnoreCase;
            var tab: ?BuyTab = null;
            if (eq(kind, "building")) {
                if (bd.type_path.len > 2 and (eq(bd.type_path[2], "Rubble") or std.ascii.findIgnoreCase(bd.type_path[2], "Reward") != null)) continue;
                tab = .building;
            } else if (eq(kind, "scenery") or eq(kind, "prop")) tab = .scenery
            else if (eq(kind, "enrichment")) tab = .enrich
            else if (eq(kind, "shelters")) tab = .shelter
            else if (eq(kind, "tree")) tab = .tree
            else if (eq(kind, "foliage")) tab = .plant
            else if (eq(kind, "rock")) tab = .rock;
            const t = tab orelse continue;
            if (viewer.binderModel(self.gpa, &self.reg, bd.name, "mainObj") == null) continue;
            names.append(self.gpa, .{ .name = ca.dupe(u8, bd.name) catch continue, .tab = t }) catch {};
        }
        std.mem.sort(@TypeOf(names.items[0]), names.items, {}, struct {
            fn less(_: void, a: @TypeOf(names.items[0]), b: @TypeOf(names.items[0])) bool {
                return std.ascii.lessThanIgnoreCase(a.name, b.name);
            }
        }.less);
        for (names.items) |e| {
            self.item_names.append(self.gpa, e.name) catch continue;
            add(self, e.tab, self.item_names.items.len - 1);
        }
        for (self.actor_names.items, 0..) |n, i| {
            if (sim_mod.classify(n) == .animal) {
                if (std.mem.indexOf(u8, n, "Adult") != null and std.mem.indexOf(u8, n, "uper") == null) {
                    const male = std.mem.endsWith(u8, n, "_M");
                    const female = std.mem.endsWith(u8, n, "_F");
                    if ((male and self.buy_female) or (female and !self.buy_female)) continue;
                    add(self, .animal, i);
                }
            } else if (!sim_mod.isGuest(n)) add(self, .staff, i);
        }
    }

    /// The icon file for an item of a tab, by the game's naming convention.
    fn iconFor(self: *App, tab: BuyTab, idx: usize) ?[]const u8 {
        var buf: [128]u8 = undefined;
        var name: []const u8 = switch (tab) {
            .fence => self.fence_kinds.items[idx],
            .path => return self.path_textures.items[idx],
            .food => self.food_names.items[idx],
            .building, .scenery, .enrich, .shelter, .tree, .plant, .rock => self.item_names.items[idx],
            .animal, .staff => self.actor_names.items[idx],
            .deform => return null,
        };
        // Try the full name, then without trailing parts (variant, sex, age).
        var tries: usize = 0;
        while (tries < 3 and name.len > 0) : (tries += 1) {
            if (name.len > buf.len) return null;
            if (self.icons.get(std.ascii.lowerString(&buf, name))) |p| return p;
            const cut = std.mem.lastIndexOfScalar(u8, name, '_') orelse return null;
            name = name[0..cut];
        }
        return null;
    }

    fn itemName(self: *const App, tab: BuyTab, idx: usize) []const u8 {
        return switch (tab) {
            .fence => self.fence_kinds.items[idx],
            .path => std.fs.path.stem(self.path_textures.items[idx]),
            .food => self.food_names.items[idx],
            .building, .scenery, .enrich, .shelter, .tree, .plant, .rock => self.item_names.items[idx],
            .animal, .staff => self.actor_names.items[idx],
            .deform => "",
        };
    }

    fn itemPrice(self: *App, tab: BuyTab, idx: usize) f64 {
        return switch (tab) {
            .fence => self.costOf(self.fence_kinds.items[idx], 20),
            .path => path_cost,
            .food => self.costOf(self.food_names.items[idx], 50),
            .building, .scenery, .enrich, .shelter, .tree, .plant, .rock => self.costOf(self.item_names.items[idx], 50),
            .animal, .staff => self.costOf(self.actor_names.items[idx], 100),
            .deform => 0,
        };
    }

    fn tabTool(tab: BuyTab) Tool {
        return switch (tab) {
            .fence => .fence,
            .path => .path,
            .food => .food,
            .building, .scenery, .enrich, .shelter, .tree, .plant, .rock => .item,
            .animal, .staff => .actor,
            .deform => .raise,
        };
    }

    fn openBuyCat(self: *App, cat: u8) void {
        self.delete_mode = false;
        if (self.buy_cat != null and self.buy_cat.? == cat) {
            self.buy_cat = null;
            return;
        }
        self.buy_cat = cat;
        self.buy_scroll = 0;
        self.setBuyTab(switch (cat) {
            0 => .fence,
            1 => .animal,
            2 => .deform,
            else => .staff,
        });
    }

    fn setBuyTab(self: *App, tab: BuyTab) void {
        self.buy_tab = tab;
        self.buy_scroll = 0;
        self.tool = tabTool(tab);
        self.fence_start = null;
        self.title_dirty = true;
    }

    fn buyTabCat(tab: BuyTab) u8 {
        return switch (tab) {
            .fence, .path, .building, .scenery => 0,
            .animal, .food, .enrich, .shelter => 1,
            .deform, .tree, .plant, .rock => 2,
            .staff => 3,
        };
    }

    fn buyTabFor(name: []const u8) ?BuyTab {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(name, "Fence Tab")) return .fence;
        if (eq(name, "Path Tab")) return .path;
        if (eq(name, "Building Tab")) return .building;
        if (eq(name, "Scenery Tab")) return .scenery;
        if (eq(name, "Buy Animal Tab")) return .animal;
        if (eq(name, "Animal Food Tab")) return .food;
        if (eq(name, "Staff Tab")) return .staff;
        if (eq(name, "Terrain Deformation Tab")) return .deform;
        if (eq(name, "Animal Enrichment Tab")) return .enrich;
        if (eq(name, "Animal Shelter Tab")) return .shelter;
        if (eq(name, "Tree Tab")) return .tree;
        if (eq(name, "Plant Tab")) return .plant;
        if (eq(name, "Rock Tab")) return .rock;
        return null;
    }

    fn selectBuyItem(self: *App, pos: usize) void {
        const list = self.buy_lists[@intFromEnum(self.buy_tab)].items;
        if (pos >= list.len) return;
        const idx: usize = list[pos];
        self.tool = tabTool(self.buy_tab);
        switch (self.buy_tab) {
            .fence => self.fence_i = idx,
            .path => self.path_i = idx,
            .food => self.food_i = idx,
            .building, .scenery, .enrich, .shelter, .tree, .plant, .rock => self.item_sel = idx,
            .animal, .staff => {
                if (self.actorDef(self.actor_names.items[idx]) == null) {
                    self.say("{s} has no model", .{self.actor_names.items[idx]});
                    return;
                }
                self.actor_i = idx;
            },
            .deform => {},
        }
        self.fence_start = null;
        self.title_dirty = true;
    }

    /// Which item of the open tab is currently the placement choice.
    fn currentBuyIndex(self: *const App) usize {
        return switch (self.buy_tab) {
            .fence => self.fence_i,
            .path => self.path_i,
            .food => self.food_i,
            .building, .scenery, .enrich, .shelter, .tree, .plant, .rock => self.item_sel,
            .animal, .staff => self.actor_i,
            .deform => 0,
        };
    }

    /// The game's buy panel: category tabs from its layout over its own panel
    /// background, with a scrolling grid of item icons and prices.
    fn drawBuyPanel(self: *App, ui: *viewer.Ui, d: *uilayout.Draw, shell: *const uilayout.Layout) void {
        const cat = self.buy_cat orelse return;
        const c = d.canvas;
        const s = c.scale;
        const ox = 278 * s;
        const oy = c.off_y + 384 * s;
        ui.template("buyandpgb", 276 * s, oy + 212 * s, 436 * s, 173 * s, s, 1);
        const set_name = switch (cat) {
            0 => "Construction ToggleSet",
            1 => "Animal ToggleSet",
            2 => "Terraform Toggleset",
            else => "Staff ToggleSet",
        };
        if (shell.find(set_name)) |n| uilayout.drawAt(d, n, .{ ox, oy + 170 * s, 450 * s, 256 * s });
        if (self.buy_tab == .deform) {
            if (shell.find("Terrain Deformation Toggle Set")) |n| uilayout.drawAt(d, n, .{ ox, oy + 185 * s, 450 * s, 256 * s });
            self.buy_rect = .{ 0, 0, 0, 0 };
            return;
        }
        if (cat == 1) if (shell.find("buy animal gender toggleset")) |n| uilayout.drawAt(d, n, .{ ox + 6 * s, oy + 190 * s, 450 * s, 256 * s });
        // Item grid inside the panel background.
        const gx = 292 * s;
        const gy = oy + 222 * s;
        const cell_w = 58 * s;
        const cell_h = 74 * s;
        const cols: usize = @max(1, @as(usize, @intFromFloat(392 * s / cell_w)));
        const rows: usize = 2;
        self.buy_rect = .{ 276 * s, oy + 212 * s, 436 * s, 173 * s };
        const list = self.buy_lists[@intFromEnum(self.buy_tab)].items;
        const total_rows = (list.len + cols - 1) / cols;
        if (total_rows > rows and self.buy_scroll > total_rows - rows) self.buy_scroll = total_rows - rows;
        if (total_rows <= rows) self.buy_scroll = 0;
        const first = self.buy_scroll * cols;
        const ts: f32 = @max(1, @round(s));
        const cur = self.currentBuyIndex();
        self.buy_hover = null;
        const mouse = d.mouse;
        var k: usize = 0;
        while (k < cols * rows) : (k += 1) {
            const pos = first + k;
            if (pos >= list.len) break;
            const idx: usize = list[pos];
            const x = gx + @as(f32, @floatFromInt(k % cols)) * cell_w;
            const y = gy + @as(f32, @floatFromInt(k / cols)) * cell_h;
            const hot = mouse[0] >= x and mouse[0] < x + cell_w and mouse[1] >= y and mouse[1] < y + cell_h;
            if (hot) self.buy_hover = .{ .tab = self.buy_tab, .pos = pos };
            if (idx == cur and tabTool(self.buy_tab) == self.tool) ui.rect(x, y, cell_w - 2 * s, cell_h - 2 * s, .{ 1, 0.9, 0.4, 0.35 }) catch {} else if (hot) ui.rect(x, y, cell_w - 2 * s, cell_h - 2 * s, .{ 1, 1, 1, 0.18 }) catch {};
            const isz = 50 * s;
            if (self.iconFor(self.buy_tab, idx)) |ip| if (ui.sprite(ip)) |spr| {
                // Entity icons are 2x2 atlases of states (normal, lit, pressed, off).
                const atlas = self.buy_tab != .path and spr.w >= 128;
                const src: [4]f32 = if (atlas) .{ 0, 0, spr.w / 2, spr.h / 2 } else .{ 0, 0, spr.w, spr.h };
                ui.image(spr, x + 2 * s, y + 2 * s, isz, isz, src, .{ 1, 1, 1, 1 }) catch {};
            };
            var pb: [24]u8 = undefined;
            const price = std.fmt.bufPrint(&pb, "${d:.0}", .{self.itemPrice(self.buy_tab, idx)}) catch "";
            const pw = viewer.Ui.textWidth(price, ts);
            const afford = self.sim.zoo.income >= self.itemPrice(self.buy_tab, idx);
            _ = ui.text(x + (cell_w - 2 * s - pw) / 2, y + 54 * s, ts, price, if (afford) .{ 0.55, 0.95, 0.55, 1 } else .{ 1, 0.5, 0.45, 1 }) catch {};
            self.hits.append(self.gpa, .{ .x = x, .y = y, .w = cell_w - 2 * s, .h = cell_h - 2 * s, .action = .{ .buy_item = pos } }) catch {};
        }
        // Name of the hovered or chosen item.
        var shown: usize = std.math.maxInt(usize);
        if (self.buy_hover) |hv| {
            shown = self.buy_lists[@intFromEnum(hv.tab)].items[hv.pos];
        } else if (tabTool(self.buy_tab) == self.tool) {
            // The current choice, if it belongs to this tab.
            for (list) |li| if (li == cur) {
                shown = cur;
            };
        }
        if (shown != std.math.maxInt(usize)) {
            const nm = self.itemName(self.buy_tab, @min(shown, self.itemCountForTab(self.buy_tab) -| 1));
            if (nm.len > 0) ui.label(gx, oy + 214 * s, ts, nm[0..@min(nm.len, 48)], .{ 1, 0.92, 0.5, 1 }) catch {};
        }
    }


    /// The game's entity info panel for a selected animal, guest or keeper:
    /// its frame, tabs, icon and name from `ui/layout/shell.xml`'s entity
    /// info layout, with our needs and status in the content area.
    fn drawEntityInfo(self: *App, ui: *viewer.Ui, d: *uilayout.Draw, shell: *const uilayout.Layout) void {
        self.info_drawn = false;
        const sel = self.selected orelse return;
        if (sel.kind != .actor) return;
        const ag = self.sim.agentFor(sel.id) orelse return;
        const c = d.canvas;
        const s = c.scale;
        const ox = c.off_x + 714 * s;
        const oy = c.off_y + 513 * s;
        const animal = ag.kind == .animal;
        self.info_drawn = true;
        const white = [4]f32{ 1, 1, 1, 1 };
        const gold = [4]f32{ 1, 0.92, 0.5, 1 };
        const grey = [4]f32{ 0.85, 0.9, 0.95, 1 };
        const ts: f32 = @max(1, @round(s));

        if (shell.find("Backgrounds")) |n| uilayout.drawAt(d, n, .{ ox, oy, 309 * s, 300 * s });
        if (animal) {
            if (shell.find("animal buttonbar")) |n| uilayout.drawAt(d, n, .{ ox + 103 * s, oy + 79 * s, 202 * s, 64 * s });
        }
        if (shell.find(if (animal) "Animal Info ToggleSet" else "Guest Info ToggleSet")) |n| uilayout.drawAt(d, n, .{ ox, oy, 309 * s, 256 * s });
        if (shell.find("track camera button")) |n| uilayout.drawAt(d, n, .{ ox + 5 * s, oy + 50 * s, 96 * s, 92 * s });

        // Portrait and name.
        const ibox = [4]f32{ ox + 10 * s, oy + 55 * s, 93 * s, 84 * s };
        if (self.iconForName(ag.binder)) |ip| if (ui.sprite(ip)) |spr| {
            const side = @min(ibox[2], ibox[3]);
            ui.image(spr, ibox[0] + (ibox[2] - side) / 2, ibox[1], side, side, .{ 0, 0, spr.w / 2, spr.h / 2 }, white) catch {};
        };
        const name = ag.binder;
        _ = ui.text(ox + 108 * s, oy + 58 * s, ts, name[0..@min(name.len, 24)], gold) catch {};

        // Remove button inside the button bar.
        const rb = [4]f32{ ox + 110 * s, oy + 100 * s, 70 * s, 18 * s };
        ui.template("buttonbar", rb[0], rb[1], rb[2], rb[3], s / 2, 1);
        _ = ui.text(rb[0] + (rb[2] - viewer.Ui.textWidth("REMOVE", ts)) / 2, rb[1] + (rb[3] - 7 * ts) / 2, ts, "REMOVE", .{ 1, 0.6, 0.6, 1 }) catch {};
        self.hits.append(self.gpa, .{ .x = rb[0], .y = rb[1], .w = rb[2], .h = rb[3], .action = .{ .menu = .delete_selected } }) catch {};

        // Content: rows of icon, label and bar.
        const rx = ox + 16 * s;
        var ry = oy + 150 * s;
        const rh = 11 * s;
        const bar_x = rx + 14 * s + 12 * 6 * ts;
        const bar_w = ox + 296 * s - bar_x;
        const Row = struct { label: []const u8, frac: f32, color: [4]f32 };
        var rows: [10]Row = undefined;
        var n: usize = 0;
        var lines: [6][48]u8 = undefined;
        var line_len: [6]usize = @splat(0);
        var ln: usize = 0;
        const addLine = struct {
            fn f(buf: *[6][48]u8, lens: *[6]usize, cnt: *usize, comptime fmt: []const u8, args: anytype) void {
                if (cnt.* >= 6) return;
                const t = std.fmt.bufPrint(&buf[cnt.*], fmt, args) catch return;
                lens[cnt.*] = t.len;
                cnt.* += 1;
            }
        }.f;
        if (animal) {
            if (ag.brain) |b| {
                const order = [_]usize{ 5, 6, 0, 1, 2, 3, 4 };
                if (self.info_tab == 0) {
                    for (order) |i| {
                        rows[n] = .{ .label = ai.need_names[i], .frac = b.needs[i] / 100.0, .color = needColor(b.needs[i]) };
                        n += 1;
                    }
                }
            }
            if (self.info_tab == 0 and ag.habitat != null) {
                rows[n] = .{ .label = "HABITAT", .frac = ag.hab_score / 100.0, .color = .{ 0.45, 0.8, 0.5, 1 } };
                n += 1;
            }
            if (self.info_tab == 1) {
                addLine(&lines, &line_len, &ln, "DOING {s}", .{ag.anim_name});
                if (ag.brain) |b| addLine(&lines, &line_len, &ln, "WELFARE {d:.0}", .{(100 - @max(b.needs[5], b.needs[6])) * (0.5 + 0.5 * ag.hab_score / 100.0)});
                if (ag.habitat != null) {
                    addLine(&lines, &line_len, &ln, "HABITAT {d:.0}  BIOME FIT {d:.0}", .{ ag.hab_score, ag.hab_biome });
                    if (ag.hab_open) addLine(&lines, &line_len, &ln, "SPACE: OPEN GROUND", .{}) else addLine(&lines, &line_len, &ln, "SPACE {d:.0} OF {d:.0} TILES", .{ ag.hab_area, ag.hab_need });
                }
            }
            if (self.info_tab == 2) {
                if (ag.habitat) |h| {
                    addLine(&lines, &line_len, &ln, "SPECIES {s}", .{h.species});
                    var best: usize = 0;
                    for (h.sens, 0..) |v, i| if (v > h.sens[best]) {
                        best = i;
                    };
                    addLine(&lines, &line_len, &ln, "HOME BIOME {s}", .{sim_mod.habitat_biomes[best]});
                    addLine(&lines, &line_len, &ln, "NEEDS {d:.0} TILES, +{d:.0} EACH", .{ h.space_first, h.space_more });
                }
            }
        } else if (ag.is_guest) {
            if (self.info_tab == 0) {
                rows[n] = .{ .label = "HAPPY", .frac = ag.happiness / 100.0, .color = .{ 0.4, 0.85, 0.4, 1 } };
                n += 1;
                const names = [_][]const u8{ "HUNGER", "THIRST", "BATHROOM" };
                for (ag.needs[0..3], names) |v, nm| {
                    rows[n] = .{ .label = nm, .frac = v / 100.0, .color = needColor(v) };
                    n += 1;
                }
            } else if (self.info_tab == 1) {
                const goal: []const u8 = switch (ag.goal) {
                    .view => "WATCHING ANIMALS",
                    .leave => "HEADING HOME",
                    .wander => "STROLLING",
                    .shop => "GOING SHOPPING",
                    .none => "LOOKING AROUND",
                };
                addLine(&lines, &line_len, &ln, "{s}", .{goal});
                if (std.math.isFinite(ag.tour_left)) addLine(&lines, &line_len, &ln, "LEAVES IN {d:.0}S", .{@max(ag.tour_left, 0)});
            }
        } else {
            if (self.info_tab == 0) {
                addLine(&lines, &line_len, &ln, "STAFF", .{});
                addLine(&lines, &line_len, &ln, "WAGE ${d:.0} A MONTH", .{ag.wage});
            } else if (self.info_tab == 1) {
                addLine(&lines, &line_len, &ln, "{s}", .{switch (ag.job) {
                    .none => "LOOKING FOR WORK",
                    .go => "HEADING TO A FEEDER",
                    .work => "REFILLING A FEEDER",
                }});
            }
        }
        for (rows[0..n]) |r| {
            if (needIcon(r.label)) |ip| if (ui.sprite(ip)) |spr| {
                ui.image(spr, rx, ry - 1 * s, 10 * s, 10 * s, .{ 0, 0, spr.w, spr.h }, white) catch {};
            };
            _ = ui.text(rx + 13 * s, ry, ts, r.label[0..@min(r.label.len, 11)], white) catch {};
            bar(ui, bar_x, ry, bar_w, 7 * ts, r.frac, r.color) catch {};
            ry += rh;
        }
        for (0..ln) |i| {
            _ = ui.text(rx, ry, ts, lines[i][0..line_len[i]], grey) catch {};
            ry += rh;
        }
    }

    fn iconForName(self: *App, name: []const u8) ?[]const u8 {
        var buf: [128]u8 = undefined;
        var nm = name;
        var tries: usize = 0;
        while (tries < 3 and nm.len > 0) : (tries += 1) {
            if (nm.len > buf.len) return null;
            if (self.icons.get(std.ascii.lowerString(&buf, nm))) |p| return p;
            const cut = std.mem.lastIndexOfScalar(u8, nm, '_') orelse return null;
            nm = nm[0..cut];
        }
        return null;
    }

    fn itemCountForTab(self: *const App, tab: BuyTab) usize {
        return switch (tab) {
            .fence => self.fence_kinds.items.len,
            .path => self.path_textures.items.len,
            .food => self.food_names.items.len,
            .building, .scenery, .enrich, .shelter, .tree, .plant, .rock => self.item_names.items.len,
            .animal, .staff => self.actor_names.items.len,
            .deform => 0,
        };
    }

    fn pushAlert(self: *App, kind: u8, comptime fmt: []const u8, args: anytype) void {
        // Newest first.
        var i: usize = self.alerts.len - 1;
        while (i > 0) : (i -= 1) self.alerts[i] = self.alerts[i - 1];
        var a: Alert = .{ .kind = kind, .t = self.app_time };
        const text = std.fmt.bufPrint(&a.text, fmt, args) catch a.text[0..0];
        a.len = text.len;
        self.alerts[0] = a;
        if (kind == 2) self.sfx("message_alert");
    }

    fn alertReady(self: *App, slot: usize, cooldown: f64) bool {
        if (self.app_time - self.alert_cool[slot] < cooldown) return false;
        self.alert_cool[slot] = self.app_time;
        return true;
    }

    /// Looks for things the player should hear about.
    fn checkAlerts(self: *App) void {
        const z = &self.sim.zoo;
        if (self.last_stars == 0) {
            self.last_stars = self.stars();
            self.last_months = z.months;
        }
        for (self.sim.feeders.items) |f| if (f.food < 10) {
            if (self.alertReady(0, 45)) self.pushAlert(2, "A FEEDER IS ALMOST EMPTY", .{});
            break;
        };
        for (self.sim.agents.items) |ag| if (ag.kind == .animal) if (ag.brain) |b| {
            if (b.needs[5] >= 92 and self.alertReady(1, 60)) self.pushAlert(2, "{s} IS VERY HUNGRY", .{ag.binder[0..@min(ag.binder.len, 30)]});
            if (b.needs[6] >= 92 and self.alertReady(2, 60)) self.pushAlert(2, "{s} IS VERY THIRSTY", .{ag.binder[0..@min(ag.binder.len, 30)]});
        };
        // Guests with an urgent need that nothing in the zoo can satisfy.
        const wants = [3][]const u8{ "SOMETHING TO EAT", "SOMETHING TO DRINK", "A BATHROOM" };
        for (0..3) |ni| {
            var n: u32 = 0;
            for (self.sim.agents.items) |ag| if (ag.is_guest and ag.needs[ni] >= 90) {
                n += 1;
            };
            if (n < 2) continue;
            var have = false;
            for (self.sim.venues.items) |v| if (@intFromEnum(v.need) == ni) {
                have = true;
            };
            if (!have and self.alertReady(3 + ni, 90)) self.pushAlert(2, "GUESTS NEED {s}", .{wants[ni]});
        }
        if (z.income < 1000 and self.alertReady(6, 180)) self.pushAlert(2, "MONEY IS RUNNING LOW", .{});
        const st = self.stars();
        if (st > self.last_stars) self.pushAlert(1, "YOUR ZOO IS NOW A {d:.0} STAR ZOO!", .{st});
        self.last_stars = st;
        if (z.months != self.last_months) {
            self.last_months = z.months;
            const net = z.last_month.totalEarned() - z.last_month.totalSpent();
            self.pushAlert(if (net >= 0) 1 else 0, "MONTH {d} DONE: {s}${d:.0}", .{ z.months, if (net < 0) "-" else "", @abs(net) });
        }
    }

    /// The game's message bar: recent alerts, newest on top.
    fn drawAlerts(self: *App, ui: *viewer.Ui) void {
        var n: usize = 0;
        for (self.alerts) |a| if (a.len > 0 and self.app_time - a.t < 14) {
            n += 1;
        };
        if (n == 0) return;
        const c = self.canvas(ui);
        const s = c.scale;
        const ts: f32 = @max(1, @round(s * 1.8));
        const h = (16 + 14 * @as(f32, @floatFromInt(n))) * s;
        // The bar is as wide as its longest message (within the layout's room).
        var widest: f32 = 0;
        for (self.alerts) |a| if (a.len > 0 and self.app_time - a.t < 14) {
            widest = @max(widest, viewer.Ui.textWidth(a.text[0..a.len], ts));
        };
        const bar_w = std.math.clamp(widest + 70 * s, 280 * s, 560 * s);
        const bar_x = 300 * s + (440 * s - bar_w) / 2;
        ui.template("topbars", bar_x, 8 * s, bar_w, h, s, 1.5);
        var y = 8 * s + 10 * s;
        for (self.alerts) |a| {
            if (a.len == 0 or self.app_time - a.t >= 14) continue;
            const col: [4]f32 = switch (a.kind) {
                1 => .{ 0.6, 1, 0.6, 1 },
                2 => .{ 1, 0.65, 0.55, 1 },
                else => .{ 1, 0.97, 0.7, 1 },
            };
            var tsz = ts;
            var w = viewer.Ui.textWidth(a.text[0..a.len], tsz);
            if (w > bar_w - 40 * s) {
                tsz = @max(1, ts - 1);
                w = viewer.Ui.textWidth(a.text[0..a.len], tsz);
            }
            _ = ui.text(bar_x + (bar_w - w) / 2, y, tsz, a.text[0..a.len], col) catch {};
            y += 14 * s;
        }
    }

    fn canvas(self: *const App, ui: *const viewer.Ui) uilayout.Canvas {
        var c = uilayout.Canvas.fit(ui.width, ui.height);
        c.scale *= self.ui_zoom;
        c.off_x = ui.width - uilayout.canvas_w * c.scale;
        c.off_y = ui.height - uilayout.canvas_h * c.scale;
        return c;
    }

    /// Thought icons over guests' heads: a need that has become urgent, or
    /// whether the guest is delighted or miserable.
    /// Shows where the next fence piece starts and where the pointer would put it.
    fn drawFenceMarkers(self: *App, ui: *viewer.Ui, ctx: *viewer.FrameCtx) void {
        if (self.tool != .fence or self.isGateKind()) return;
        const sz = @max(8, ui.height / 60);
        if (self.hover) |h| {
            const p = [3]f32{ snap(h[0], 3.0), snap(h[1], 3.0), self.world.terrain.zAt(snap(h[0], 3.0), snap(h[1], 3.0)) };
            if (ctx.cam.project(p, ui.width, ui.height)) |sp| ui.rect(sp[0] - sz / 2, sp[1] - sz / 2, sz, sz, .{ 1, 1, 1, 0.8 }) catch {};
        }
        if (self.fence_start) |st| {
            const p = [3]f32{ st[0], st[1], self.world.terrain.zAt(st[0], st[1]) };
            if (ctx.cam.project(p, ui.width, ui.height)) |sp| ui.rect(sp[0] - sz * 0.7, sp[1] - sz * 0.7, sz * 1.4, sz * 1.4, .{ 1, 0.85, 0.2, 0.9 }) catch {};
        }
    }

    fn drawEmotes(self: *App, ui: *viewer.Ui, ctx: *viewer.FrameCtx) void {
        if (ctx.cam.dist > 90) return;
        const size = @max(18, ui.height / 24) * self.ui_zoom;
        var shown: usize = 0;
        for (self.sim.agents.items) |ag| {
            if (!ag.is_guest or ag.leave_done) continue;
            var path: ?[]const u8 = null;
            var worst: f32 = 80;
            const icons = [3][]const u8{ "ui/icon_needs/all_hunger.dds", "ui/icon_needs/all_thirst.dds", "ui/icon_needs/guest_bathroom.dds" };
            for (ag.needs[0..3], icons) |v, ip| if (v >= worst) {
                worst = v;
                path = ip;
            };
            if (path == null) {
                if (ag.happiness >= 80) path = "ui/icon_needs/all_good.dds" else if (ag.happiness <= 20) path = "ui/icon_needs/all_bad.dds";
            }
            const ip = path orelse continue;
            const head = [3]f32{ ag.pos[0], ag.pos[1], ag.pos[2] + 2.6 };
            const sp = ctx.cam.project(head, ui.width, ui.height) orelse continue;
            if (sp[0] < -size or sp[0] > ui.width + size or sp[1] < -size or sp[1] > ui.height + size) continue;
            const spr = ui.sprite(ip) orelse continue;
            const bob = @sin(@as(f32, @floatCast(self.sim.time)) * 3 + @as(f32, @floatFromInt(ag.id))) * size * 0.06;
            ui.image(spr, sp[0] - size / 2, sp[1] - size * 0.95 + bob, size, size, .{ 0, 0, spr.w, spr.h }, .{ 1, 1, 1, 0.95 }) catch {};
            shown += 1;
            if (shown >= 60) break;
        }
    }

    fn hudActive(self: *const App) bool {
        return self.hud != null and self.hud_on and self.opts.tools;
    }

    fn loadHud(self: *App) void {
        const sb = self.vfs.read(self.gpa, "ui/layout/shell.xml") catch return;
        defer self.gpa.free(sb);
        var shell = uilayout.parse(self.gpa, sb) catch return;
        var bucks: ?uilayout.Layout = null;
        if (self.vfs.read(self.gpa, "ui/layout/zoobucksdisplay.xml")) |bb| {
            defer self.gpa.free(bb);
            bucks = uilayout.parse(self.gpa, bb) catch null;
        } else |_| {}
        var info: ?uilayout.Layout = null;
        if (self.vfs.read(self.gpa, "ui/layout/entityinfo.xml")) |ib| {
            defer self.gpa.free(ib);
            info = uilayout.parse(self.gpa, ib) catch null;
        } else |_| {}
        var status: ?uilayout.Layout = null;
        if (self.vfs.read(self.gpa, "ui/layout/zoostatus.xml")) |zb| {
            defer self.gpa.free(zb);
            status = uilayout.parse(self.gpa, zb) catch null;
        } else |_| {}
        var mainmenu: ?uilayout.Layout = null;
        if (self.vfs.read(self.gpa, "ui/layout/mainmenu.xml")) |mb| {
            defer self.gpa.free(mb);
            mainmenu = uilayout.parse(self.gpa, mb) catch null;
        } else |_| {}
        var tutorial: ?uilayout.Layout = null;
        if (self.vfs.read(self.gpa, "ui/layout/tutorial.xml")) |tb| {
            defer self.gpa.free(tb);
            tutorial = uilayout.parse(self.gpa, tb) catch null;
        } else |_| {}
        var goals_l: ?uilayout.Layout = null;
        if (self.vfs.read(self.gpa, "ui/layout/goals.xml")) |gb| {
            defer self.gpa.free(gb);
            goals_l = uilayout.parse(self.gpa, gb) catch null;
        } else |_| {}
        self.hud = .{ .shell = shell, .bucks = bucks, .info = info, .status = status, .mainmenu = mainmenu, .tutorial = tutorial, .goals = goals_l };
        _ = &shell;
        self.show_help = false;
    }

    fn buy_open_tab(self: *const App, t: BuyTab) bool {
        return self.buy_tab == t;
    }

    fn hudAction(name: []const u8) ?@TypeOf(@as(Hit, undefined).action) {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(name, "construction")) return .{ .buy_cat = 0 };
        if (eq(name, "animals")) return .{ .buy_cat = 1 };
        if (eq(name, "terraform")) return .{ .buy_cat = 2 };
        if (eq(name, "staff")) return .{ .buy_cat = 3 };
        if (buyTabFor(name)) |t| return .{ .buy_tab = t };
        if (eq(name, "Freeform Button")) return .{ .menu = .open_maps };
        if (eq(name, "Load Save Game Button")) return .{ .menu = .open_saves };
        if (eq(name, "Campaign Game Button")) return .{ .menu = .open_campaigns };
        if (eq(name, "Challenge Button")) return .{ .menu = .open_challenge };
        if (eq(name, "Game Options Button")) return .{ .menu = .open_settings };
        if (eq(name, "Exit Game Button")) return .{ .menu = .quit };
        if (eq(name, "close")) return .{ .menu = .close_selection };
        if (eq(name, "track camera button")) return .{ .menu = .track_camera };
        if (eq(name, "Animal Info Status Tab") or eq(name, "Guest Info Button")) return .{ .info_tab = 0 };
        if (eq(name, "Animal Info Tab Button") or eq(name, "Guest Info Status Tab")) return .{ .info_tab = 1 };
        if (eq(name, "Animal Info Conservation Tab")) return .{ .info_tab = 2 };
        if (eq(name, "hill")) return .{ .tool = .raise };
        if (eq(name, "valley")) return .{ .tool = .lower };
        if (eq(name, "flatten")) return .{ .tool = .flatten };
        if (eq(name, "cliff")) return .{ .tool = .cliff };
        if (eq(name, "ditch")) return .{ .tool = .ditch };
        if (eq(name, "smooth")) return .{ .tool = .smooth };
        if (eq(name, "Zoofinance")) return .{ .menu = .open_finances };
        if (eq(name, "scenariogoals")) return .{ .menu = .open_goals };
        if (eq(name, "continue tutorial")) return .{ .menu = .tutorial_continue };
        if (eq(name, "Male button")) return .{ .menu = .gender_male };
        if (eq(name, "Female Button")) return .{ .menu = .gender_female };
        if (eq(name, "zoo info tab")) return .{ .status_tab = 0 };
        if (eq(name, "balance sheet tab")) return .{ .status_tab = 1 };
        if (eq(name, "graphs tab")) return .{ .status_tab = 2 };
        if (eq(name, "undo")) return .{ .menu = .undo };
        if (eq(name, "delete")) return .{ .menu = .toggle_delete };
        if (eq(name, "options")) return .{ .menu = .open_pause };
        if (eq(name, "pause")) return .{ .menu = .toggle_pause };
        if (eq(name, "Zoom In")) return .{ .menu = .zoom_in };
        if (eq(name, "Zoom Out")) return .{ .menu = .zoom_out };
        if (eq(name, "Rotate Left")) return .{ .menu = .rot_left };
        if (eq(name, "Rotate Right")) return .{ .menu = .rot_right };
        return null;
    }

    fn hudInfo(ctx: *anyopaque, n: *const uilayout.Node) uilayout.Info {
        const self: *App = @ptrCast(@alignCast(ctx));
        const eq = std.ascii.eqlIgnoreCase;
        var info: uilayout.Info = .{};
        if (eq(n.name, "minimize") or eq(n.name, "maximize")) info.visible = false;
        if (self.menu == .main and std.mem.endsWith(u8, n.name, "Pointer") and n.kind == .layout) {
            // The paw pointer that goes with the hovered button.
            info.visible = self.main_hover.len > 0 and std.ascii.eqlIgnoreCase(std.mem.trim(u8, n.name, " "), self.main_hover);
        }
        // The fame stars are drawn by hand over the star wells (see drawHud).
        if (eq(n.name, "famestars") or eq(n.name, "zoo fame stars")) info.visible = false;
        if (eq(n.name, "CurrentDate")) {
            info.text = std.fmt.bufPrint(&self.hud_text, "MONTH {d}", .{self.sim.zoo.months + 1}) catch "";
        }
        if (eq(n.name, "zoo_bucks_static_display")) {
            info.text = money(&self.hud_text, self.sim.zoo.income);
        }
        if (n.kind == .toggle or n.kind == .button) {
            info.enabled = hudAction(n.name) != null;
            if (eq(n.name, "construction")) info.on = self.buy_cat != null and self.buy_cat.? == 0;
            if (eq(n.name, "animals")) info.on = self.buy_cat != null and self.buy_cat.? == 1;
            if (eq(n.name, "terraform")) info.on = self.buy_cat != null and self.buy_cat.? == 2;
            if (eq(n.name, "staff")) info.on = self.buy_cat != null and self.buy_cat.? == 3;
            if (buyTabFor(n.name)) |t| info.on = self.buy_open_tab(t);
            if (eq(n.name, "Animal Info Status Tab") or eq(n.name, "Guest Info Button")) info.on = self.info_tab == 0;
            if (eq(n.name, "Animal Info Tab Button") or eq(n.name, "Guest Info Status Tab")) info.on = self.info_tab == 1;
            if (eq(n.name, "Animal Info Conservation Tab")) info.on = self.info_tab == 2;
            if (eq(n.name, "track camera button")) info.on = self.track_id != null;
            if (eq(n.name, "Male button")) info.on = !self.buy_female;
            if (eq(n.name, "Female Button")) info.on = self.buy_female;
            if (eq(n.name, "hill")) info.on = self.tool == .raise;
            if (eq(n.name, "valley")) info.on = self.tool == .lower;
            if (eq(n.name, "flatten")) info.on = self.tool == .flatten;
            if (eq(n.name, "cliff")) info.on = self.tool == .cliff;
            if (eq(n.name, "ditch")) info.on = self.tool == .ditch;
            if (eq(n.name, "smooth")) info.on = self.tool == .smooth;
            if (eq(n.name, "pause")) info.on = self.paused;
            if (eq(n.name, "delete")) info.on = self.delete_mode;
            if (eq(n.name, "zoo info tab")) info.on = self.status_tab == 0;
            if (eq(n.name, "balance sheet tab")) info.on = self.status_tab == 1;
            if (eq(n.name, "graphs tab")) info.on = self.status_tab == 2;
        }
        if (self.ui_state) |*us| if (us.get(n.name)) |e| {
            if (e.visible) |v| info.visible = v;
            if (!e.enabled) info.enabled = false;
            if (e.activated) info.on = true;
            if (e.text.len > 0) info.text = e.text;
        };
        return info;
    }

    fn hudButton(ctx: *anyopaque, n: *const uilayout.Node, rect: [4]f32) void {
        const self: *App = @ptrCast(@alignCast(ctx));
        if (self.ui_state) |*us| if (self.cv_scale > 0 and !std.ascii.eqlIgnoreCase(n.name, "scenariogoals")) {
            const e = us.at(n.name);
            e.pos = .{ (rect[0] - self.cv_off[0]) / self.cv_scale, (rect[1] - self.cv_off[1]) / self.cv_scale };
            e.size = .{ rect[2] / self.cv_scale, rect[3] / self.cv_scale };
        };
        const act = hudAction(n.name) orelse return;
        self.hits.append(self.gpa, .{ .x = rect[0], .y = rect[1], .w = rect[2], .h = rect[3], .action = act }) catch {};
    }

    /// The game's own HUD: button panel, fame stars, date bar and money.
    fn drawHud(self: *App, ui: *viewer.Ui, ctx: *viewer.FrameCtx) void {
        const h = &(self.hud orelse return);
        var d: uilayout.Draw = .{
            .ui = ui,
            .canvas = self.canvas(ui),
            .hooks = .{ .ctx = self, .info = hudInfo, .button = hudButton },
            .mouse = toPixels(ctx, ctx.mouse[0], ctx.mouse[1]),
            .pressed = self.lmb,
        };
        self.cv_scale = d.canvas.scale;
        self.cv_off = .{ d.canvas.off_x, d.canvas.off_y };
        const tops = [_][]const u8{ "famestarwells", "CurrentDate Background", "Primary Game Button Panel" };
        for (tops) |name| if (h.shell.find(name)) |n| uilayout.drawTop(&d, n);
        if (h.bucks) |*b| if (b.find("zoo_bucks")) |n| uilayout.drawTop(&d, n);
        // Fill the star wells: the star strip cropped to the rating.
        if (ui.sprite("ui/photosaf/stars.dds")) |spr| {
            const cs = d.canvas.scale;
            const frac = std.math.clamp(self.stars() / 5.0, 0, 1);
            const wx = 47 * cs;
            const wy = 61 * cs;
            const ww = 224 * cs;
            const wh = 38 * cs;
            ui.image(spr, wx, wy, ww * frac, wh, .{ 0, 0, spr.w * frac, spr.h }, .{ 1, 1, 1, 1 }) catch {};
        }
        self.drawBuyPanel(ui, &d, &h.shell);
        self.syncUiState();
        if (self.scen != null) {
            // The game's own Goals button sits off the visible HUD here, so show one.
            const cs = d.canvas.scale;
            const bx = 8 * cs;
            const by = 104 * cs;
            const bw = 70 * cs;
            const bh = 20 * cs;
            ui.template("buttonbar", bx, by, bw, bh, cs / 2, 1);
            const ts1: f32 = @max(1, @round(cs));
            _ = ui.text(bx + (bw - viewer.Ui.textWidth("GOALS (O)", ts1)) / 2, by + (bh - 7 * ts1) / 2, ts1, "GOALS (O)", .{ 1, 1, 1, 1 }) catch {};
            self.hits.append(self.gpa, .{ .x = bx, .y = by, .w = bw, .h = bh, .action = .{ .menu = .open_goals } }) catch {};
            if (self.ui_state) |*us| {
                const e = us.at("scenariogoals");
                // canvas units are relative to the canvas offset, which hudButton also subtracts
                e.pos = .{ (bx - self.cv_off[0]) / cs, (by - self.cv_off[1]) / cs };
                e.size = .{ 70, 20 };
            }
        }
        if (self.scen != null and self.challengeOpen()) self.drawChallenge(ui, self.canvas(ui).scale * 1.5) catch {};
        if (self.scen != null) if (h.tutorial) |*tl| if (self.ui_state) |*us| {
            const shown = (if (us.get("tutorial layout")) |e| e.visible orelse false else false) or (if (us.get("tutorial info")) |e| e.visible orelse false else false);
            if (shown) {
                if (tl.find("tutorial info")) |n| uilayout.drawTop(&d, n);
                if (tl.find("continue tutorial")) |n| uilayout.drawTop(&d, n);
                const hint = "ENTER: CONTINUE     F10: SKIP A STEP THIS ENGINE CANNOT DO YET";
                ui.label((ui.width - viewer.Ui.textWidth(hint, 1)) / 2, ui.height - 14, 1, hint, .{ 0.85, 0.9, 1, 1 }) catch {};
            }
            // The ring the script places around the thing to use next.
            if (us.get("tutorial ring")) |re| if ((re.visible orelse false) and re.pos != null and re.size != null) {
                const cs = d.canvas.scale;
                const rp = re.pos.?;
                const rs = re.size.?;
                const pulse: f32 = 0.55 + 0.45 * @sin(@as(f32, @floatFromInt(self.blink)) * 0.15);
                const x = d.canvas.off_x + rp[0] * cs;
                const y = d.canvas.off_y + rp[1] * cs;
                const w = rs[0] * cs;
                const hh = rs[1] * cs;
                const t = 3 * cs;
                const col = [4]f32{ 1, 0.9, 0.2, pulse };
                ui.rect(x, y, w, t, col) catch {};
                ui.rect(x, y + hh - t, w, t, col) catch {};
                ui.rect(x, y, t, hh, col) catch {};
                ui.rect(x + w - t, y, t, hh, col) catch {};
            };
        };
        if (h.info) |*il| self.drawEntityInfo(ui, &d, il) else self.info_drawn = false;
    }

    /// The game's launcher screen from `ui/layout/mainmenu.xml`: logo, paw
    /// buttons and their pointers. Freeform, Load, Options and Exit work;
    /// the rest are shown greyed out.
    fn drawMainMenu(self: *App, ui: *viewer.Ui) !void {
        const hud = &(self.hud orelse return);
        const lay = &(hud.mainmenu orelse return);
        const ctx = self.cur_ctx orelse return;
        var c = uilayout.Canvas.fit(ui.width, ui.height);
        c.scale *= self.ui_zoom;
        const s = c.scale;
        const ox = (ui.width - 1024 * s) / 2;
        const oy = (ui.height - 768 * s) / 2;
        const mouse = toPixels(ctx, ctx.mouse[0], ctx.mouse[1]);
        var d: uilayout.Draw = .{
            .ui = ui,
            .canvas = .{ .scale = s, .off_x = ox, .off_y = oy },
            .hooks = .{ .ctx = self, .info = hudInfo, .button = hudButton },
            .mouse = mouse,
            .pressed = self.lmb,
        };
        // Which paw button is under the pointer decides which pointer shows.
        self.main_hover = "";
        const buttons = [_]struct { node: []const u8, pointer: []const u8, label: []const u8 }{
            .{ .node = "Freeform Button", .pointer = "Freeform Pointer", .label = "PLAY A FREEFORM ZOO" },
            .{ .node = "Load Save Game Button", .pointer = "Load Save Game Pointer", .label = "LOAD A SAVED ZOO" },
            .{ .node = "Game Options Button", .pointer = "Game Options Pointer", .label = "GAME OPTIONS" },
            .{ .node = "Exit Game Button", .pointer = "Exit Game Pointer", .label = "QUIT" },
            .{ .node = "Campaign Game Button", .pointer = "Campaign Game Pointer", .label = "PLAY THE CAMPAIGNS" },
            .{ .node = "Challenge Button", .pointer = "Challenge Pointer", .label = "PLAY CHALLENGE MODE" },
            .{ .node = "Downloads Button", .pointer = "Downloads Pointer", .label = "DOWNLOADS: NOT AVAILABLE" },
        };
        var hover_label: []const u8 = "";
        for (buttons) |b| if (lay.find(b.node)) |n| {
            const bx = ox + n.x * s;
            const by = oy + n.y * s;
            if (mouse[0] >= bx and mouse[0] < bx + n.w * s and mouse[1] >= by and mouse[1] < by + n.h * s) {
                self.main_hover = b.pointer;
                hover_label = b.label;
            }
        };
        const draw_names = [_][]const u8{ "Ui back ground pieces", "Ui logo and message bar ", "Freeform Pointer", "Load Save Game Pointer", "Game Options Pointer", "Exit Game Pointer", "Campaign Game Pointer", "Challenge Pointer", "Downloads Pointer", "Freeform Button", "Challenge Button", "Campaign Game Button", "Game Options Button", "Downloads Button", "Load Save Game Button", "Exit Game Button" };
        for (draw_names) |nm| if (lay.find(nm)) |n| {
            uilayout.drawAt(&d, n, .{ ox + n.x * s, oy + n.y * s, n.w * s, n.h * s });
        };
        // The hovered button's name goes in the logo's text bar.
        var ts: f32 = @max(1, @round(s * 1.6));
        const label = if (hover_label.len > 0) hover_label else "ZOOTYCON2";
        if (viewer.Ui.textWidth(label, ts) > 240 * s) ts = @max(1, ts - 1);
        const lw = viewer.Ui.textWidth(label, ts);
        _ = try ui.text(ui.width / 2 - lw / 2, oy + 330 * s - 3.5 * ts, ts, label, .{ 1, 0.92, 0.5, 1 });
        const note = "AN OPEN-SOURCE ENGINE FOR ZOO TYCOON 2";
        const nw = viewer.Ui.textWidth(note, @max(1, ts * 0.5));
        _ = try ui.text(ui.width / 2 - nw / 2, oy + 700 * s, @max(1, ts * 0.5), note, .{ 0.85, 0.9, 0.95, 1 });
    }

    /// The zoo status screen on the game's own frame (`ui/layout/zoostatus.xml`):
    /// tabs for zoo info (admission prices), the balance sheet and a profit graph.
    /// Word-wraps `text` (upper-cased, as the font has capitals only) into
    /// lines at most `cols` characters wide and draws them. Returns the height used.
    fn wrapText(self: *App, ui: *viewer.Ui, x: f32, y: f32, ts: f32, cols: usize, text: []const u8, color: [4]f32) !f32 {
        _ = self;
        var line: [160]u8 = undefined;
        var n: usize = 0;
        var yy = y;
        var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
        while (words.next()) |w| {
            if (n > 0 and n + 1 + w.len > cols) {
                _ = try ui.text(x, yy, ts, line[0..n], color);
                yy += 10 * ts;
                n = 0;
            }
            if (n > 0 and n < line.len) {
                line[n] = ' ';
                n += 1;
            }
            const take = @min(w.len, line.len - n);
            _ = std.ascii.upperString(line[n..][0..take], w[0..take]);
            n += take;
        }
        if (n > 0) {
            _ = try ui.text(x, yy, ts, line[0..n], color);
            yy += 10 * ts;
        }
        return yy - y;
    }

    /// The goals window: every visible rule of the running scenario, with
    /// its state, as the scenario scripts last described it.
    fn drawGoals(self: *App, ui: *viewer.Ui, scale: f32) !void {
        const ts: f32 = @max(1, @round(scale * 0.8));
        const pw = @min(ui.width * 0.9, 130 * 6 * ts);
        const ph = ui.height * 0.82;
        const px = (ui.width - pw) / 2;
        const py = ui.height * 0.08;
        ui.template("blank", px, py, pw, ph, scale / 2, 1);
        _ = try ui.text(px + 16 * ts, py + 10 * ts, ts * 1.4, "GOALS", .{ 1, 0.92, 0.5, 1 });
        var y = py + 34 * ts;
        if (self.scen) |sm| if (sm.intro.len > 0) {
            var ib: [96]u8 = undefined;
            const t = sm.loc.get(sm.intro) orelse sm.intro;
            const up = std.ascii.upperString(&ib, t[0..@min(t.len, ib.len)]);
            _ = try ui.text(px + 16 * ts + 70 * ts, py + 12 * ts, ts, up, .{ 0.8, 0.85, 0.9, 1 });
        };
        const cols: usize = @intFromFloat(@max(20, (pw - 70 * ts) / (6 * ts)));
        const m = self.scen orelse {
            _ = try ui.text(px + 16 * ts, y, ts, "THIS ZOO HAS NO SCENARIO GOALS.", .{ 0.8, 0.85, 0.9, 1 });
            return self.goalsClose(ui, px, py, pw, ph, ts);
        };
        var stack: [32]*const scenario_mod.Node = undefined;
        var depth: [32]usize = undefined;
        var sp: usize = 0;
        var ri = m.roots.items.len;
        while (ri > 0) {
            ri -= 1;
            if (sp < stack.len) {
                stack[sp] = m.roots.items[ri];
                depth[sp] = 0;
                sp += 1;
            }
        }
        var overview: []const u8 = "";
        while (sp > 0 and y < py + ph - 40 * ts) {
            sp -= 1;
            const n = stack[sp];
            const d = depth[sp];
            if (!n.is_group and !n.hidden) {
                if (overview.len == 0 and n.state == .pending) overview = m.overviewFor(n);
                const text = m.textFor(n);
                const mark: []const u8 = switch (n.state) {
                    .pending => "[ ]",
                    .success => "[X]",
                    .failed => "[!]",
                };
                const col: [4]f32 = switch (n.state) {
                    .pending => .{ 1, 1, 1, 1 },
                    .success => .{ 0.55, 0.95, 0.55, 1 },
                    .failed => .{ 1, 0.55, 0.5, 1 },
                };
                _ = try ui.text(px + 16 * ts, y, ts, mark, col);
                y += try self.wrapText(ui, px + 40 * ts, y, ts, cols, text, col) + 4 * ts;
            }
            var ci = n.children.len;
            while (ci > 0) {
                ci -= 1;
                if (sp < stack.len) {
                    stack[sp] = n.children[ci];
                    depth[sp] = d + 1;
                    sp += 1;
                }
            }
        }
        if (overview.len > 0 and y < py + ph - 60 * ts) {
            y += 6 * ts;
            _ = try ui.text(px + 16 * ts, y, ts, "OVERVIEW", .{ 1, 0.92, 0.5, 1 });
            y += 12 * ts;
            _ = try self.wrapText(ui, px + 16 * ts, y, ts * 0.85, @intFromFloat(@as(f32, @floatFromInt(cols)) * 1.1), overview, .{ 0.8, 0.85, 0.9, 1 });
        }
        return self.goalsClose(ui, px, py, pw, ph, ts);
    }

    fn goalsClose(self: *App, ui: *viewer.Ui, px: f32, py: f32, pw: f32, ph: f32, ts: f32) !void {
        if (self.ui_state) |*us| if (self.cv_scale > 0) {
            const e = us.at("close");
            const bw0 = 30 * 6 * ts;
            e.pos = .{ (px + (pw - bw0) / 2 - self.cv_off[0]) / self.cv_scale, (py + ph - 26 * ts - self.cv_off[1]) / self.cv_scale };
            e.size = .{ bw0 / self.cv_scale, (7 * ts + 8 * ts) / self.cv_scale };
        };
        const bw = 30 * 6 * ts;
        const bx = px + (pw - bw) / 2;
        const by = py + ph - 26 * ts;
        const bh = 7 * ts + 8 * ts;
        ui.template("buttonbar", bx, by, bw, bh, ts / 2, 1);
        const label = "CLOSE";
        _ = try ui.text(bx + (bw - viewer.Ui.textWidth(label, ts)) / 2, by + 4 * ts, ts, label, .{ 1, 1, 1, 1 });
        try self.hits.append(self.gpa, .{ .x = bx, .y = by, .w = bw, .h = bh, .action = .{ .menu = .close_menu } });
    }

    fn drawFinances(self: *App, ui: *viewer.Ui, scale: f32) !void {
        const z = &self.sim.zoo;
        const white = [4]f32{ 1, 1, 1, 1 };
        const gold = [4]f32{ 1, 0.92, 0.5, 1 };
        const green = [4]f32{ 0.55, 0.95, 0.55, 1 };
        const red = [4]f32{ 1, 0.55, 0.5, 1 };
        const grey = [4]f32{ 0.8, 0.85, 0.9, 1 };
        const hud = &(self.hud orelse return);
        const lay = &(hud.status orelse return);
        const ctx = self.cur_ctx orelse return;
        _ = scale;
        const c = self.canvas(ui);
        const s = c.scale;
        const ts: f32 = @max(1, @round(s * 1.2));
        // The status window is centred on the canvas.
        const ox = (ui.width - 640 * s) / 2;
        const oy = (ui.height - 590 * s) / 2 + 20 * s;
        var d: uilayout.Draw = .{
            .ui = ui,
            .canvas = c,
            .hooks = .{ .ctx = self, .info = hudInfo, .button = hudButton },
            .mouse = toPixels(ctx, ctx.mouse[0], ctx.mouse[1]),
            .pressed = self.lmb,
        };
        if (lay.find("background layout")) |n| uilayout.drawAt(&d, n, .{ ox, oy, 640 * s, 590 * s });
        if (lay.find("zoostatus_filler")) |n| uilayout.drawAt(&d, n, .{ ox + 22 * s, oy + 98 * s, 597 * s, 459 * s });
        // Tabs: the game spaces them 48 apart.
        const tab_names = [_][]const u8{ "zoo info tab", "balance sheet tab", "graphs tab", "awards tab", "building list tab", "donations tab", "zoofame tab" };
        for (tab_names, 0..) |tn, i| if (lay.find(tn)) |n| {
            uilayout.drawAt(&d, n, .{ ox + (175 + 48 * @as(f32, @floatFromInt(i))) * s, oy + 22 * s, 48 * s, 64 * s });
        };
        const title: []const u8 = switch (self.status_tab) {
            0 => "ZOO INFO",
            1 => "BALANCE SHEET",
            else => "PROFIT GRAPH",
        };
        _ = try ui.text(ox + 24 * s, oy + 12 * s, ts, title, gold);
        var mb: [32]u8 = undefined;
        const month_txt = std.fmt.bufPrint(&mb, "MONTH {d}", .{z.months + 1}) catch "";
        _ = try ui.text(ox + 24 * s, oy + 30 * s, ts, month_txt, grey);

        const cx = ox + 36 * s;
        var y = oy + 112 * s;
        const rh = 15 * s * (ts / @max(1, s * 1.2));
        var buf: [48]u8 = undefined;
        switch (self.status_tab) {
            0 => {
                const rows = [_]struct { l: []const u8, v: []const u8 }{
                    .{ .l = "ZOO", .v = if (self.custom_len > 0) self.custom_name[0..self.custom_len] else (if (std.mem.indexOfScalar(u8, self.world.name, ':')) |ci| self.world.name[ci + 1 ..] else self.world.name) },
                    .{ .l = "GUESTS IN THE ZOO", .v = std.fmt.bufPrint(&buf, "{d}", .{self.sim.liveGuests()}) catch "" },
                    .{ .l = "GUESTS SO FAR", .v = std.fmt.bufPrint(buf[16..], "{d}", .{z.guests_total}) catch "" },
                    .{ .l = "ANIMALS", .v = std.fmt.bufPrint(buf[32..], "{d}", .{self.countAnimals()}) catch "" },
                };
                for (rows) |r| {
                    _ = try ui.text(cx, y, ts, r.l, grey);
                    _ = try ui.text(cx + 210 * s, y, ts, r.v, white);
                    y += rh;
                }
                y += rh;
                _ = try ui.text(cx, y, ts, "ZOO RATING", grey);
                var st_buf: [16]u8 = undefined;
                _ = try ui.text(cx + 210 * s, y, ts, std.fmt.bufPrint(&st_buf, "{d:.0} STARS", .{self.stars()}) catch "", gold);
                y += rh;
                _ = try ui.text(cx, y, ts, "GUEST HAPPINESS", grey);
                var hb: [16]u8 = undefined;
                _ = try ui.text(cx + 210 * s, y, ts, std.fmt.bufPrint(&hb, "{d:.0}", .{self.sim.happiness()}) catch "", white);
                y += rh * 2;
                // Admission prices with plus and minus buttons.
                _ = try ui.text(cx, y, ts, "ADMISSION PRICE", gold);
                y += rh * 1.3;
                var pb: [48]u8 = undefined;
                _ = try ui.text(cx, y + 3 * s, ts, std.fmt.bufPrint(&pb, "ADULT ${d:.0}   CHILD ${d:.0}", .{ self.sim.adult_price, self.sim.child_price }) catch "", white);
                const bw = 22 * s;
                const bx = cx + 250 * s;
                for ([2]bool{ false, true }) |up| {
                    const x = bx + (if (up) bw + 6 * s else 0);
                    ui.template("buttonbar", x, y, bw, bw, s / 2, 1);
                    const lab: []const u8 = if (up) "+" else "-";
                    _ = try ui.text(x + (bw - viewer.Ui.textWidth(lab, ts)) / 2, y + (bw - 7 * ts) / 2, ts, lab, white);
                    try self.hits.append(self.gpa, .{ .x = x, .y = y, .w = bw, .h = bw, .action = .{ .menu = if (up) .price_up else .price_down } });
                }
                y += rh * 2.2;
                _ = try ui.text(cx, y, ts, "HIGHER PRICES MEAN FEWER VISITORS.", grey);
            },
            1 => {
                // Income and expenses by category: this month, last month, all time.
                const cw = 12 * 6 * ts;
                const name_w = 15 * 6 * ts;
                const ledgers = [3]sim_mod.Ledger{ z.month, z.last_month, z.total };
                const heads = [_][]const u8{ "THIS MONTH", "LAST MONTH", "ALL TIME" };
                y = oy + 104 * s;
                const sm = ts;
                const rh2 = 11.5 * s;
                for (heads, 0..) |h, i| {
                    const hx = cx + name_w + cw * @as(f32, @floatFromInt(i + 1)) - viewer.Ui.textWidth(h, sm);
                    _ = try ui.text(hx, y, sm, h, grey);
                }
                y += rh2;
                var mbuf: [32]u8 = undefined;
                for ([2]bool{ true, false }) |income| {
                    _ = try ui.text(cx, y, sm, if (income) "INCOME" else "EXPENSES", gold);
                    y += rh2;
                    var sums: [3]f64 = @splat(0);
                    for (sim_mod.cat_names, 0..) |nm, ci| {
                        _ = try ui.text(cx + 6 * s, y, sm, nm, white);
                        for (ledgers, 0..) |l, i| {
                            const v = if (income) l.earned[ci] else l.spent[ci];
                            sums[i] += v;
                            const txt = money(&mbuf, v);
                            _ = try ui.text(cx + name_w + cw * @as(f32, @floatFromInt(i + 1)) - viewer.Ui.textWidth(txt, sm), y, sm, txt, if (v == 0) grey else white);
                        }
                        y += rh2;
                    }
                    _ = try ui.text(cx, y, sm, if (income) "TOTAL INCOME" else "TOTAL EXPENSES", white);
                    for (sums, 0..) |v, i| {
                        const txt = money(&mbuf, v);
                        _ = try ui.text(cx + name_w + cw * @as(f32, @floatFromInt(i + 1)) - viewer.Ui.textWidth(txt, sm), y, sm, txt, if (income) green else red);
                    }
                    y += rh2 * 1.3;
                }
                _ = try ui.text(cx, y, sm, "NET", white);
                for (ledgers, 0..) |l, i| {
                    const net = l.totalEarned() - l.totalSpent();
                    const txt = money(&mbuf, net);
                    _ = try ui.text(cx + name_w + cw * @as(f32, @floatFromInt(i + 1)) - viewer.Ui.textWidth(txt, sm), y, sm, txt, if (net >= 0) green else red);
                }
                y += rh2;
                _ = try ui.text(cx, y, sm, "BALANCE", gold);
                const bt = money(&mbuf, z.income);
                _ = try ui.text(cx + name_w + cw * 3 - viewer.Ui.textWidth(bt, sm), y, sm, bt, gold);
            },
            else => {
                // Net result of each finished month, as bars around a zero line.
                const gx = cx;
                const gy = oy + 120 * s;
                const gw = 540 * s;
                const gh = 300 * s;
                try ui.rect(gx, gy, gw, gh, .{ 0, 0, 0, 0.35 });
                const n: usize = z.history_n;
                // The month in progress is the last bar, drawn paler.
                const cur_net = z.month.totalEarned() - z.month.totalSpent();
                if (n == 0 and cur_net == 0) {
                    _ = try ui.text(gx + 20 * s, gy + gh / 2, ts, "NO FINANCES TO GRAPH YET", grey);
                } else {
                    var maxv: f64 = @max(1, @abs(cur_net));
                    for (z.history[0..n]) |v| maxv = @max(maxv, @abs(v));
                    const bw2 = @min(gw / @as(f32, @floatFromInt(@max(n + 1, 8))), 40 * s);
                    const mid = gy + gh / 2;
                    try ui.rect(gx, mid, gw, s, .{ 1, 1, 1, 0.4 });
                    for (z.history[0..n], 0..) |v, i| {
                        const hgt: f32 = @floatCast(v / maxv * @as(f64, gh / 2 - 12 * s));
                        const x = gx + 10 * s + @as(f32, @floatFromInt(i)) * bw2;
                        const col: [4]f32 = if (v >= 0) .{ 0.4, 0.85, 0.4, 1 } else .{ 0.9, 0.4, 0.35, 1 };
                        try ui.rect(x, if (hgt >= 0) mid - hgt else mid, bw2 * 0.7, @abs(hgt), col);
                    }
                    {
                        const hgt: f32 = @floatCast(cur_net / maxv * @as(f64, gh / 2 - 12 * s));
                        const x = gx + 10 * s + @as(f32, @floatFromInt(n)) * bw2;
                        const col: [4]f32 = if (cur_net >= 0) .{ 0.4, 0.85, 0.4, 0.55 } else .{ 0.9, 0.4, 0.35, 0.55 };
                        try ui.rect(x, if (hgt >= 0) mid - hgt else mid, bw2 * 0.7, @abs(hgt), col);
                    }
                    var ab: [40]u8 = undefined;
                    _ = try ui.text(gx + 6 * s, gy + 6 * s, ts * 0.8, std.fmt.bufPrint(&ab, "LARGEST MONTH ${d:.0}", .{maxv}) catch "", grey);
                }
                _ = try ui.text(gx, gy + gh + 10 * s, ts * 0.8, "EACH BAR IS A MONTH, OLDEST AT LEFT. THE PALE BAR IS THIS MONTH.", grey);
            },
        }
        // Close button.
        const bw = 14 * 6 * ts;
        const bx = ox + (640 * s - bw) / 2;
        const by = oy + 590 * s - 28 * s;
        ui.template("buttonbar", bx, by, bw, 22 * s, s / 2, 1);
        _ = try ui.text(bx + (bw - viewer.Ui.textWidth("CLOSE", ts)) / 2, by + (22 * s - 7 * ts) / 2, ts, "CLOSE", white);
        try self.hits.append(self.gpa, .{ .x = bx, .y = by, .w = bw, .h = 22 * s, .action = .{ .menu = .close_menu } });
    }

    fn countAnimals(self: *const App) usize {
        var n: usize = 0;
        for (self.sim.agents.items) |ag| if (ag.kind == .animal) {
            n += 1;
        };
        return n;
    }

    fn money(buf: []u8, v: f64) []const u8 {
        const r: i64 = @intFromFloat(@round(v));
        return if (r < 0)
            std.fmt.bufPrint(buf, "-${d}", .{-r}) catch ""
        else
            std.fmt.bufPrint(buf, "${d}", .{r}) catch "";
    }

    /// Pixel position of a window-coordinate mouse position.
    fn toPixels(ctx: *const viewer.FrameCtx, x: f32, y: f32) [2]f32 {
        const sx = @as(f32, @floatFromInt(ctx.width)) / @as(f32, @floatFromInt(@max(ctx.win_width, 1)));
        const sy = @as(f32, @floatFromInt(ctx.height)) / @as(f32, @floatFromInt(@max(ctx.win_height, 1)));
        return .{ x * sx, y * sy };
    }

    fn hitAt(self: *const App, px: [2]f32) ?Hit {
        for (self.hits.items) |h| {
            if (px[0] >= h.x and px[0] < h.x + h.w and px[1] >= h.y and px[1] < h.y + h.h) return h;
        }
        return null;
    }

    /// Handles a click on the interface; true if it hit a button or the list.
    fn uiClick(self: *App, x: f32, y: f32, ctx: *viewer.FrameCtx) bool {
        const h = self.hitAt(toPixels(ctx, x, y)) orelse return false;
        self.sfx("uiclick");
        switch (h.action) {
            .tool => |t| {
                self.tool = t;
                self.fence_start = null;
                self.title_dirty = true;
            },
            .pick => |i| self.pickItem(i),
            .buy_cat => |cat| self.openBuyCat(cat),
            .buy_tab => |t| {
                // Tabs belong to the open category.
                if (self.buy_cat == null or self.buy_cat.? != buyTabCat(t)) self.buy_cat = buyTabCat(t);
                self.setBuyTab(t);
            },
            .buy_item => |pos| self.selectBuyItem(pos),
            .info_tab => |t| self.info_tab = t,
            .status_tab => |t| self.status_tab = t,
            .menu => |a| self.menuAction(a, ctx),
            .entry, .none, .del_save => {},
        }
        return true;
    }

    fn itemCount(self: *const App) usize {
        return switch (self.tool) {
            .prop => self.props.items.len,
            .fence => self.fence_kinds.items.len,
            .path => self.path_textures.items.len,
            .actor => self.actor_names.items.len,
            .food => self.food_names.items.len,
            else => 0,
        };
    }

    fn itemIndex(self: *const App) usize {
        return switch (self.tool) {
            .prop => self.prop_i,
            .fence => self.fence_i,
            .path => self.path_i,
            .actor => self.actor_i,
            .food => self.food_i,
            else => 0,
        };
    }

    fn itemLabel(self: *const App, i: usize) []const u8 {
        return switch (self.tool) {
            .prop => std.fs.path.basename(self.props.items[i]),
            .fence => self.fence_kinds.items[i],
            .path => std.fs.path.basename(self.path_textures.items[i]),
            .actor => self.actor_names.items[i],
            .food => self.food_names.items[i],
            else => "",
        };
    }

    /// Chooses catalog item `i` for the current tool.
    fn pickItem(self: *App, i: usize) void {
        if (i >= self.itemCount()) return;
        switch (self.tool) {
            .prop => self.prop_i = i,
            .fence => self.fence_i = i,
            .path => self.path_i = i,
            .food => self.food_i = i,
            .actor => {
                if (self.actorDef(self.actor_names.items[i]) == null) {
                    self.say("{s} has no model", .{self.actor_names.items[i]});
                    return;
                }
                self.actor_i = i;
            },
            else => {},
        }
        self.title_dirty = true;
    }

    fn stepItemBy(self: *App, delta: i32) void {
        const saved = self.shift;
        self.shift = false;
        self.stepItem(delta);
        self.shift = saved;
    }

    fn toolKey(self: *App, code: u32) void {
        if (code >= sc.k1 and code <= sc.k9) {
            const tools = [_]Tool{ .select, .prop, .fence, .path, .raise, .lower, .flatten, .actor, .food };
            self.tool = tools[code - sc.k1];
            self.fence_start = null;
            self.title_dirty = true;
            return;
        }
        switch (code) {
            sc.lbracket => self.stepItem(-1),
            sc.rbracket => self.stepItem(1),
            sc.r => {
                self.yaw += if (self.shift) -std.math.pi / 12.0 else std.math.pi / 12.0;
                self.title_dirty = true;
            },
            sc.delete, sc.x => self.deleteSelected(),
            sc.f => self.refill(),
            sc.f10 => if (self.scen) |m| if (m.skipStep()) |n| self.say("skipped step: {s}", .{n}),
            sc.o => self.openMenu(if (self.menu == .goals) .none else .goals),
            40 => if (self.challengeOpen()) self.menuAction(.challenge_accept, self.cur_ctx.?) else if (self.ui_state) |*us| if (us.get("continue tutorial")) |e| if (e.visible orelse false) self.pressContinue(),
            sc.z => self.doUndo(),
            sc.c => {
                self.fence_start = null;
                self.title_dirty = true;
            },
            else => {},
        }
    }

    fn click(self: *App, ctx: *viewer.FrameCtx) void {
        const r = ctx.cam.ray(ctx.mouse[0], ctx.mouse[1], @floatFromInt(ctx.win_width), @floatFromInt(ctx.win_height));
        const hit = terrainHit(&self.world.terrain, r.origin, r.dir);
        self.hover = hit;
        switch (self.tool) {
            .select => {
                self.selected = self.pick(r.origin, r.dir);
                self.title_dirty = true;
                if (self.delete_mode and self.selected != null) self.deleteSelected();
            },
            .prop => if (hit) |h| self.placeProp(h) catch {},
            .actor => if (hit) |h| self.placeActor(h) catch {},
            .food => if (hit) |h| self.placeFood(h) catch {},
            .item => if (hit) |h| self.placeItem(h) catch {},
            .path => if (hit) |h| self.placePath(h) catch {},
            .fence => if (hit) |h| {
                const p = [2]f32{ snap(h[0], 3.0), snap(h[1], 3.0) };
                if (self.isGateKind()) {
                    self.placeGate(p) catch {};
                    return;
                }
                if (self.fence_start) |s| {
                    // Go along the longer way first, then turn to reach the click.
                    const dx = p[0] - s[0];
                    const dy = p[1] - s[1];
                    if (@abs(dx) >= @abs(dy)) {
                        self.placeFenceLine(s, .{ p[0], s[1] }) catch {};
                        self.placeFenceLine(.{ p[0], s[1] }, p) catch {};
                    } else {
                        self.placeFenceLine(s, .{ s[0], p[1] }) catch {};
                        self.placeFenceLine(.{ s[0], p[1] }, p) catch {};
                    }
                    self.fence_start = p; // keep drawing from the end
                } else self.fence_start = p;
                self.title_dirty = true;
            },
            .flatten => if (hit) |h| {
                self.flatten_to = h[2];
            },
            .raise, .lower, .cliff, .ditch, .smooth => {},
        }
    }

    // ------------------------------------------------------------- frame

    fn modelMatrixAt(self: *App, at: [3]f32, yaw: f32, scale: f32) Mat4 {
        _ = self;
        return viewer.fromTransform(.{ .translation = at, .rotation = world_mod.yawRotation(yaw), .scale = scale });
    }

    fn drawOverlays(self: *App) !void {
        const scene = self.scene;
        scene.overlay.clearRetainingCapacity();
        if (!self.opts.tools) return;
        const green = [4]f32{ 0.5, 1.0, 0.5, 0.55 };
        const red = [4]f32{ 1.0, 0.45, 0.45, 0.6 };
        // Placement previews.
        if (self.hover) |h| switch (self.tool) {
            .prop => if (self.props.items.len > 0) {
                if (try scene.loadModel(self.props.items[self.prop_i])) |d| try scene.addOverlay(d, self.modelMatrixAt(h, self.yaw, 1.0), green);
            },
            .actor => if (self.actor_names.items.len > 0) {
                const name = self.actor_names.items[self.actor_i];
                if (self.actorDef(name)) |def| {
                    if (try scene.loadModel(def.file)) |d| try scene.addOverlay(d, self.modelMatrixAt(h, self.yaw, def.scale), green);
                }
            },
            .food => if (self.food_names.items.len > 0) {
                if (viewer.binderModel(self.gpa, &self.reg, self.food_names.items[self.food_i], "mainObj")) |m| {
                    if (try scene.loadModel(m.file)) |d| try scene.addOverlay(d, self.modelMatrixAt(h, self.yaw, m.scale), green);
                }
            },
            .fence => if (self.fence_kinds.items.len > 0) {
                const pieces = try scene.fenceModels(self.fence_kinds.items[self.fence_i]);
                if (pieces.segment) |seg| {
                    if (self.fence_start) |s| {
                        const e = [2]f32{ snap(h[0], 3.0), snap(h[1], 3.0) };
                        const dx = e[0] - s[0];
                        const dy = e[1] - s[1];
                        const horizontal = @abs(dx) >= @abs(dy);
                        const len = if (horizontal) dx else dy;
                        const n: usize = @min(60, @as(usize, @intFromFloat(@round(@abs(len) / 3.0))));
                        const theta: f32 = if (horizontal) (if (dx >= 0) 0 else std.math.pi) else (if (dy >= 0) std.math.pi / 2.0 else 3.0 * std.math.pi / 2.0);
                        for (0..n) |i| {
                            const k = @as(f32, @floatFromInt(i)) * 3.0;
                            const x = s[0] + @cos(theta) * k;
                            const y = s[1] + @sin(theta) * k;
                            const z = self.world.terrain.zAt(x, y);
                            try scene.addOverlay(seg, self.modelMatrixAt(.{ x, y, z }, theta, 1.0), green);
                        }
                    } else {
                        const x = snap(h[0], 3.0);
                        const y = snap(h[1], 3.0);
                        try scene.addOverlay(seg, self.modelMatrixAt(.{ x, y, self.world.terrain.zAt(x, y) }, 0, 1.0), green);
                    }
                }
            },
            else => {},
        };
        // Selection highlight.
        if (self.selected) |sel| switch (sel.kind) {
            .prop => for (self.world.props.items) |p| if (p.id == sel.id) {
                if (try scene.loadModel(p.model)) |d| try scene.addOverlay(d, propMatrix(p), red);
            },
            .actor => for (self.world.actors.items) |a| if (a.id == sel.id) {
                if (self.actorDef(a.binder)) |def| {
                    if (try scene.loadModel(def.file)) |d| try scene.addOverlay(d, viewer.fromTransform(.{ .translation = a.position, .rotation = a.rotation, .scale = def.scale }), red);
                }
            },
            .fence => for (self.world.fences.items) |f| if (f.id == sel.id) {
                const pieces = try scene.fenceModels(f.kind);
                if (pieces.segment) |seg| try scene.addOverlay(seg, self.fenceMatrix(f), red);
            },
            .path => {},
        };
    }

    fn toolHint(self: *const App) []const u8 {
        return switch (self.tool) {
            .select => "CLICK AN OBJECT, ANIMAL OR PERSON. DEL OR X REMOVES IT",
            .item => "CLICK THE GROUND TO PLACE. R ROTATES",
            .prop => "CLICK THE GROUND TO PLACE. [ ] CHANGE OBJECT, R ROTATES",
            .fence => "CLICK WHERE THE FENCE STARTS, THEN CLICK EACH CORNER. C ENDS THE LINE",
            .path => "CLICK OR DRAG TO PAINT PATH TILES. [ ] CHANGE PATH",
            .raise => "HOLD LEFT MOUSE TO RAISE THE GROUND",
            .lower => "HOLD LEFT MOUSE TO LOWER THE GROUND",
            .flatten => "CLICK TO PICK A HEIGHT, THEN HOLD TO FLATTEN TO IT",
            .cliff => "HOLD LEFT MOUSE TO RAISE A STEEP CLIFF",
            .ditch => "HOLD LEFT MOUSE TO DIG A NARROW DITCH",
            .smooth => "HOLD LEFT MOUSE TO SMOOTH THE GROUND",
            .actor => "CLICK THE GROUND TO PLACE. [ ] CHANGE ANIMAL OR PERSON",
            .food => "CLICK TO PLACE A FEEDER. F REFILLS THE SELECTED ONE (SHIFT: ALL)",
        };
    }

    fn statsText(self: *const App, buf: []u8) []const u8 {
        const z = &self.sim.zoo;
        return std.fmt.bufPrint(buf, "GUESTS {d}/{d}  MONEY ${d:.0}  VIEWS {d}  HAPPY {d:.0}  ANIMALS {d:.0}  STARS {d:.0}", .{
            self.sim.liveGuests(), self.sim.max_guests, z.income, z.views, self.sim.happiness(), self.sim.animalWelfare(), self.stars(),
        }) catch "";
    }

    /// The on-screen display, drawn over the scene each frame.
    pub fn overlay(self: *App, ui: *viewer.Ui, ctx: *viewer.FrameCtx) !void {
        const scale: f32 = @max(1, @round(ui.height / 360 * self.ui_zoom));
        const pad = 6 * scale;
        const line = 10 * scale;
        const white = [4]f32{ 1, 1, 1, 1 };
        const yellow = [4]f32{ 1, 0.92, 0.5, 1 };
        const grey = [4]f32{ 0.8, 0.85, 0.9, 1 };
        var buf: [256]u8 = undefined;
        var y = pad + (if (self.hudActive()) 56 * self.canvas(ui).scale else 0);
        // A menu replaces the normal display.
        self.hits.clearRetainingCapacity();
        self.cur_ctx = ctx;
        if (self.menu != .none) {
            try self.drawMenu(ui, scale);
            return;
        }

        // Top left: what the tool is doing.
        var detail: []const u8 = "";
        switch (self.tool) {
            .prop => if (self.props.items.len > 0) {
                detail = std.fs.path.basename(self.props.items[self.prop_i]);
            },
            .fence => if (self.fence_kinds.items.len > 0) {
                detail = self.fence_kinds.items[self.fence_i];
            },
            .path => if (self.path_textures.items.len > 0) {
                detail = std.fs.path.basename(self.path_textures.items[self.path_i]);
            },
            .actor => if (self.actor_names.items.len > 0) {
                detail = self.actor_names.items[self.actor_i];
            },
            .food => if (self.food_names.items.len > 0) {
                detail = self.food_names.items[self.food_i];
            },
            else => {},
        }
        const head = if (self.opts.tools)
            std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ self.tool.label(), if (detail.len > 0) ": " else "", detail }) catch ""
        else
            "VIEW";
        // The game's date bar and stars take the top-left corner.
        const lx = if (self.hudActive()) pad + 300 * self.canvas(ui).scale else pad;
        if (self.hudActive()) self.drawAlerts(ui);
        try ui.label(lx, y, scale, head, white);
        y += line + 2 * scale;
        // The right-hand statistics take the same row, so clip the hint to fit.
        const stats_w = viewer.Ui.textWidth(self.statsText(&buf), scale);
        const room = @max(0, ui.width - stats_w - pad * 4 - 4 - lx);
        if (self.opts.tools and self.show_help) {
            const hint = self.toolHint();
            const fit: usize = @intFromFloat(@floor(room / (6 * scale)));
            try ui.label(lx, y, scale, hint[0..@min(hint.len, fit)], grey);
            y += line + 2 * scale;
        }
        if (self.message_len > 0) {
            const mfit: usize = @intFromFloat(@max(4, @floor(room / (6 * scale))));
            try ui.label(lx, y, scale, self.message[0..@min(self.message_len, mfit)], yellow);
        }

        // Top right: simulation status.
        const status = std.fmt.bufPrint(&buf, "{s} X{d:.2}   {d} AGENTS   {s} {d:.2}{s}", .{
            if (self.paused) "PAUSED" else "RUNNING",
            self.speed,
            self.sim.agents.items.len,
            phase_names[phaseIndex(self.tod)],
            self.tod,
            if (self.tod_auto) "+" else "",
        }) catch "";
        const sw = viewer.Ui.textWidth(status, scale);
        const ry = if (self.hudActive()) pad + 58 * self.canvas(ui).scale else pad;
        try ui.label(ui.width - sw - pad, ry, scale, status, white);

        self.drawEmotes(ui, ctx);
        self.drawFenceMarkers(ui, ctx);

        // Clickable interface.
        if (self.opts.tools) try self.drawControls(ui, scale, pad, line);
        if (self.hudActive()) self.drawHud(ui, ctx);

        // Zoo statistics: guests, takings, how happy they are.
        const stats = self.statsText(&buf);
        const stw = viewer.Ui.textWidth(stats, scale);
        try ui.label(ui.width - stw - pad, ry + line + 2 * scale, scale, stats, white);

        // Details panel (the item list uses the same corner).
        self.info_drawn = if (self.hudActive()) self.info_drawn else false;
        if (self.opts.tools and self.itemCount() == 0 and !self.info_drawn) try self.drawInfoPanel(ui, scale, pad, line, pad + 3.2 * (line + 2 * scale) + self.hudRightShift(ui));

        // Selection.
        if (self.selected) |sel| {
            var food_text: [32]u8 = undefined;
            var food: []const u8 = "";
            if (sel.kind == .prop) for (self.sim.feeders.items) |f| if (f.prop_id == sel.id and !f.infinite) {
                food = std.fmt.bufPrint(&food_text, "  FOOD {d:.0}%", .{f.food}) catch "";
            };
            const t = std.fmt.bufPrint(&buf, "SELECTED {s} #{d}{s}", .{ @tagName(sel.kind), sel.id, food }) catch "";
            const w2 = viewer.Ui.textWidth(t, scale);
            if (!self.info_drawn) try ui.label(ui.width - w2 - pad, ry + 2 * (line + 2 * scale), scale, t, yellow);
        }

        // Key reference.
        if (self.show_help) {
            const lines = if (self.opts.tools) [_][]const u8{
                "1 SELECT 2 OBJECT 3 FENCE 4 PATH 5 RAISE 6 LOWER 7 FLATTEN 8 ANIMAL/PERSON 9 FOOD",
                "[ ] CHOOSE (SHIFT: x10)  R ROTATE  Z UNDO  TAB PAUSE  , . SPEED  F5 SAVE  F9 LOAD",
                "T RUN/STOP CLOCK   F2 F3 PREVIOUS/NEXT TIME OF DAY   G GUEST ARRIVALS   F REFILL FEEDER",
                "RIGHT-DRAG ORBIT  MIDDLE-DRAG PAN  WHEEL ZOOM TO CURSOR  WASD/ARROWS PAN  Q E TURN  SHIFT FAST",
            } else [_][]const u8{
                "TAB PAUSE  , . SPEED   T RUN/STOP CLOCK   F2 F3 TIME OF DAY",
                "LEFT-DRAG ORBIT  MIDDLE-DRAG PAN  WHEEL ZOOM  WASD/ARROWS PAN  Q E TURN  SHIFT FAST",
                "",
                "",
            };
            var by = ui.height - pad - line * @as(f32, @floatFromInt(lines.len));
            for (lines) |l| {
                if (l.len > 0) try ui.label(pad, by, scale, l, grey);
                by += line;
            }
        }
    }

    fn bar(ui: *viewer.Ui, x: f32, y: f32, w: f32, h: f32, frac: f32, color: [4]f32) !void {
        try ui.rect(x, y, w, h, .{ 0.1, 0.1, 0.12, 0.9 });
        try ui.rect(x, y, w * std.math.clamp(frac, 0, 1), h, color);
    }

    /// Needs go from green (satisfied) to red (urgent).
    fn needColor(need: f32) [4]f32 {
        const t = std.math.clamp(need / 100.0, 0, 1);
        return .{ 0.3 + 0.7 * t, 0.85 - 0.6 * t, 0.25, 1 };
    }

    /// Details of the selected thing, with buttons for what can be done to it.
    fn drawInfoPanel(self: *App, ui: *viewer.Ui, scale: f32, pad: f32, line: f32, top: f32) !void {
        const sel = self.selected orelse return;
        const white = [4]f32{ 1, 1, 1, 1 };
        const grey = [4]f32{ 0.8, 0.85, 0.9, 1 };
        const panel_w: f32 = 34 * 6 * scale;
        const x = ui.width - panel_w - pad;
        var rows: std.ArrayList(struct { text: []const u8, frac: f32, color: [4]f32, is_bar: bool }) = .empty;
        defer rows.deinit(self.gpa);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var title: []const u8 = "";
        var can_refill = false;
        switch (sel.kind) {
            .prop => for (self.world.props.items) |p| if (p.id == sel.id) {
                title = if (p.binder.len > 0) p.binder else std.fs.path.basename(p.model);
                for (self.sim.feeders.items) |f| if (f.prop_id == p.id) {
                    can_refill = true;
                    try rows.append(self.gpa, .{ .text = try std.fmt.allocPrint(a, "FOOD {d:.0}%", .{f.food}), .frac = f.food / 100.0, .color = .{ 0.4, 0.7, 0.9, 1 }, .is_bar = true });
                };
            },
            .fence => for (self.world.fences.items) |f| if (f.id == sel.id) {
                title = f.kind;
            },
            .path => title = "PATH TILE",
            .actor => for (self.world.actors.items) |act| if (act.id == sel.id) {
                title = act.binder;
                if (self.sim.agentFor(act.id)) |ag| {
                    if (ag.is_guest) {
                        try rows.append(self.gpa, .{ .text = try std.fmt.allocPrint(a, "HAPPY {d:.0}", .{ag.happiness}), .frac = ag.happiness / 100.0, .color = .{ 0.4, 0.85, 0.4, 1 }, .is_bar = true });
                        const goal = switch (ag.goal) {
                            .view => "WATCHING ANIMALS",
                            .leave => "HEADING HOME",
                            .wander => "STROLLING",
                            .shop => "GOING SHOPPING",
                            .none => "LOOKING AROUND",
                        };
                        try rows.append(self.gpa, .{ .text = goal, .frac = 0, .color = grey, .is_bar = false });
                        for (ag.needs[0..3], 0..) |nv, ni| {
                            const names = [_][]const u8{ "HUNGER", "THIRST", "BATHROOM" };
                            try rows.append(self.gpa, .{ .text = names[ni], .frac = nv / 100.0, .color = needColor(nv), .is_bar = true });
                        }
                        if (std.math.isFinite(ag.tour_left)) try rows.append(self.gpa, .{ .text = try std.fmt.allocPrint(a, "LEAVES IN {d:.0}S", .{@max(ag.tour_left, 0)}), .frac = 0, .color = grey, .is_bar = false });
                    } else if (ag.brain) |b| {
                        const shown = [_]usize{ 5, 6, 0, 1, 2, 3, 4 };
                        for (shown) |i| {
                            try rows.append(self.gpa, .{
                                .text = try std.fmt.allocPrint(a, "{s}", .{ai.need_names[i]}),
                                .frac = b.needs[i] / 100.0,
                                .color = needColor(b.needs[i]),
                                .is_bar = true,
                            });
                        }
                        if (ag.habitat != null) {
                            try rows.append(self.gpa, .{ .text = "HABITAT", .frac = ag.hab_score / 100.0, .color = .{ 0.45, 0.8, 0.5, 1 }, .is_bar = true });
                            try rows.append(self.gpa, .{ .text = "BIOME FIT", .frac = ag.hab_biome / 100.0, .color = .{ 0.45, 0.8, 0.5, 1 }, .is_bar = true });
                            if (ag.hab_open) {
                                try rows.append(self.gpa, .{ .text = "SPACE: OPEN GROUND", .frac = 0, .color = grey, .is_bar = false });
                            } else try rows.append(self.gpa, .{ .text = try std.fmt.allocPrint(a, "SPACE {d:.0}/{d:.0} TILES", .{ ag.hab_area, ag.hab_need }), .frac = 0, .color = grey, .is_bar = false });
                        }
                        try rows.append(self.gpa, .{ .text = try std.fmt.allocPrint(a, "DOING {s}", .{ag.anim_name}), .frac = 0, .color = grey, .is_bar = false });
                        try rows.append(self.gpa, .{ .text = try std.fmt.allocPrint(a, "WELFARE {d:.0}", .{100 - @max(b.needs[5], b.needs[6])}), .frac = 0, .color = grey, .is_bar = false });
                    }
                }
            },
        }
        const row_h = line + scale;
        const btn_h = 7 * scale + 4 * scale;
        const height = (line + 2 * scale) + row_h * @as(f32, @floatFromInt(rows.items.len)) + btn_h + 6 * scale;
        ui.template("blank", x - 6 * scale, top - 6 * scale, panel_w + 12 * scale, height + 9 * scale, scale / 2, 1.5);
        _ = try ui.text(x, top, scale, title[0..@min(title.len, 34)], .{ 1, 0.92, 0.5, 1 });
        var y = top + line + 2 * scale;
        for (rows.items) |r| {
            if (r.is_bar) {
                var tx = x;
                if (needIcon(r.text)) |path| if (ui.sprite(path)) |spr| {
                    try ui.image(spr, x, y - 1.5 * scale, 10 * scale, 10 * scale, .{ 0, 0, spr.w, spr.h }, .{ 1, 1, 1, 1 });
                    tx = x + 12 * scale;
                };
                _ = try ui.text(tx, y, scale, r.text[0..@min(r.text.len, 11)], white);
                const bx0 = x + 12 * scale + 12 * 6 * scale;
                try bar(ui, bx0, y, panel_w - (bx0 - x), 7 * scale, r.frac, r.color);
            } else _ = try ui.text(x, y, scale, r.text[0..@min(r.text.len, 34)], r.color);
            y += row_h;
        }
        y += 2 * scale;
        _ = try self.drawButton(ui, x + 2 * scale, y + 2 * scale, scale, "DELETE", .{ 1, 0.6, 0.6, 1 }, .{ .menu = .delete_selected });
        const bx = x + viewer.Ui.textWidth("DELETE", scale) + 8 * scale;
        if (can_refill) _ = try self.drawButton(ui, bx, y + 2 * scale, scale, "REFILL", .{ 0.6, 0.85, 1, 1 }, .{ .menu = .refill_selected });
    }

    /// The game's icon for a need or status bar, by its label.
    fn needIcon(label: []const u8) ?[]const u8 {
        const map = [_]struct { []const u8, []const u8 }{
            .{ "HUNGER", "ui/icon_needs/all_hunger.dds" },
            .{ "THIRST", "ui/icon_needs/all_thirst.dds" },
            .{ "REST", "ui/icon_needs/animal_rest.dds" },
            .{ "EXERCISE", "ui/icon_needs/animal_exercise.dds" },
            .{ "SOCIAL", "ui/icon_needs/animal_social.dds" },
            .{ "STIMULATION", "ui/icon_needs/animal_stimulation.dds" },
            .{ "HYGIENE", "ui/icon_needs/animal_hygiene.dds" },
            .{ "HABITAT", "ui/icon_needs/animal_biome.dds" },
            .{ "BIOME FIT", "ui/icon_needs/animal_biome.dds" },
            .{ "BATHROOM", "ui/icon_needs/guest_bathroom.dds" },
        };
        for (map) |m| if (std.ascii.eqlIgnoreCase(m[0], label)) return m[1];
        return null;
    }

    fn drawButton(self: *App, ui: *viewer.Ui, x: f32, y: f32, scale: f32, text: []const u8, color: [4]f32, action: @TypeOf(@as(Hit, undefined).action)) !f32 {
        const pad = 2 * scale;
        const w = viewer.Ui.textWidth(text, scale) + pad * 2 - scale;
        const h = 7 * scale + pad * 2;
        ui.template("buttonbar", x - pad, y - pad, w, h, scale / 3, 1);
        _ = try ui.text(x, y, scale, text, color);
        try self.hits.append(self.gpa, .{ .x = x - pad, .y = y - pad, .w = w, .h = h, .action = action });
        return h;
    }

    /// Tool buttons down the left edge and the item list on the right.
    fn drawControls(self: *App, ui: *viewer.Ui, scale: f32, pad: f32, line: f32) !void {
        const white = [4]f32{ 1, 1, 1, 1 };
        const yellow = [4]f32{ 1, 0.92, 0.5, 1 };
        const tools = [_]struct { t: Tool, label: []const u8 }{
            .{ .t = .select, .label = "1 SELECT" },
            .{ .t = .prop, .label = "2 OBJECT" },
            .{ .t = .fence, .label = "3 FENCE" },
            .{ .t = .path, .label = "4 PATH" },
            .{ .t = .raise, .label = "5 RAISE" },
            .{ .t = .lower, .label = "6 LOWER" },
            .{ .t = .flatten, .label = "7 FLATTEN" },
            .{ .t = .actor, .label = "8 ANIMAL" },
            .{ .t = .food, .label = "9 FOOD" },
        };
        var y = pad + line * 4.5;
        if (!self.hudActive()) {
            for (tools) |t| {
                const h = try self.drawButton(ui, pad + 2 * scale, y, scale, t.label, if (self.tool == t.t) yellow else white, .{ .tool = t.t });
                y += h + 2 * scale;
            }
            y += 4 * scale;
            _ = try self.drawButton(ui, pad + 2 * scale, y, scale, "B FINANCES", white, .{ .menu = .open_finances });
        }

        // The item list for tools that choose from a catalog (the game's buy
        // panel replaces it when the real HUD is on).
        if (self.hudActive()) return;
        const n = self.itemCount();
        if (n == 0) return;
        const rows: usize = 16;
        const cur = self.itemIndex();
        const first = if (n <= rows) 0 else @min(cur -| rows / 2, n - rows);
        const shown = @min(rows, n);
        const max_chars = 30;
        const panel_w = (max_chars + 1) * 6 * scale;
        const x = ui.width - panel_w - pad;
        const top = pad + line * 4.2 + self.hudRightShift(ui);
        var title_buf: [48]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "{s} {d}/{d}", .{ self.tool.label(), cur + 1, n }) catch "";
        ui.template("blank", x - 6 * scale, top - 6 * scale, panel_w + 12 * scale, line * @as(f32, @floatFromInt(shown + 1)) + 10 * scale, scale / 2, 1.5);
        _ = try ui.text(x, top, scale, title, white);
        // The whole panel is one hit area so the wheel scrolls it; rows override it.
        try self.hits.append(self.gpa, .{
            .x = x - 2 * scale,
            .y = top - 2 * scale,
            .w = panel_w + 4 * scale,
            .h = line * @as(f32, @floatFromInt(shown + 1)) + 4 * scale,
            .action = .none,
        });
        var row: usize = 0;
        while (row < shown) : (row += 1) {
            const i = first + row;
            const ry = top + line * @as(f32, @floatFromInt(row + 1));
            const label = self.itemLabel(i);
            const clipped = label[0..@min(label.len, max_chars)];
            const is_cur = i == cur;
            if (is_cur) try ui.rect(x - scale, ry - scale, panel_w + 2 * scale, line, .{ 0.3, 0.3, 0.1, 0.8 });
            _ = try ui.text(x, ry, scale, clipped, if (is_cur) yellow else white);
            // Row hits go before the panel hit so they win.
            try self.hits.insert(self.gpa, 0, .{ .x = x - scale, .y = ry - scale, .w = panel_w + 2 * scale, .h = line, .action = .{ .pick = i } });
        }
    }

    fn updateTitle(self: *App, win: platform.Window) void {
        var buf: [320]u8 = undefined;
        var detail: []const u8 = "";
        switch (self.tool) {
            .prop => if (self.props.items.len > 0) {
                detail = std.fs.path.basename(self.props.items[self.prop_i]);
            },
            .fence => if (self.fence_kinds.items.len > 0) {
                detail = self.fence_kinds.items[self.fence_i];
            },
            .path => if (self.path_textures.items.len > 0) {
                detail = std.fs.path.basename(self.path_textures.items[self.path_i]);
            },
            .actor => if (self.actor_names.items.len > 0) {
                detail = self.actor_names.items[self.actor_i];
            },
            .food => if (self.food_names.items.len > 0) {
                detail = self.food_names.items[self.food_i];
            },
            else => {},
        }
        const msg = self.message[0..self.message_len];
        const text = std.fmt.bufPrint(buf[0 .. buf.len - 1], "zootycon2 | {s}{s}{s} | {s} x{d:.2} | {d} agents | {s}", .{
            if (self.opts.tools) self.tool.label() else "view",
            if (detail.len > 0) ": " else "",
            detail,
            if (self.paused) "paused" else "running",
            self.speed,
            self.sim.agents.items.len,
            msg,
        }) catch return;
        buf[text.len] = 0;
        win.setTitle(buf[0..text.len :0]);
        self.title_dirty = false;
    }

    /// Terrain height for the camera to follow.
    /// The camera stays over the map.
    pub fn clampCenter(self: *App, c: *[3]f32) void {
        const t = &self.world.terrain;
        c[0] = std.math.clamp(c[0], 0, t.world_width);
        c[1] = std.math.clamp(c[1], 0, t.world_height);
    }

    pub fn groundZ(self: *App, x: f32, y: f32) f32 {
        return self.world.terrain.zAt(x, y);
    }

    pub fn frame(self: *App, ctx: *viewer.FrameCtx) !void {
        self.blink +%= 1;
        self.app_time += ctx.dt;
        self.scene.scrollWater(@floatCast(self.app_time));
        if (self.app_time - self.alert_check > 4 and self.menu == .none and self.opts.sim) {
            self.alert_check = self.app_time;
            self.checkAlerts();
        }
        self.playInput(ctx);
        if (self.reset_camera) {
            // A different map was loaded: look at its middle.
            const t = &self.world.terrain;
            const cx = t.world_width / 2;
            const cy = t.world_height / 2;
            ctx.cam.center = .{ cx, cy, t.zAt(cx, cy) };
            ctx.cam.radius = @max(t.world_width, t.world_height) / 2;
            ctx.cam.dist = ctx.cam.radius * 1.3;
            if (self.start_focus) |f| {
                ctx.cam.center = .{ f[0], f[1], t.zAt(f[0], f[1]) };
                ctx.cam.radius = 60;
                ctx.cam.dist = 90;
                self.start_focus = null;
            }
            ctx.snap_camera = true;
            self.reset_camera = false;
            self.audio_biome_dirty = true;
        }
        if (self.tod_auto) {
            self.tod += ctx.dt * (if (self.paused) 0 else self.speed) / self.day_len;
            self.tod -= @floor(self.tod);
        }
        self.scene.tod = self.tod;
        self.scene.lighting = if (self.env) |*e| e.sample(self.tod) else null;
        try self.syncScene(ctx.secs);

        // Hover point under the mouse.
        if (self.opts.tools) {
            self.over_ui = self.menu != .none or self.hitAt(toPixels(ctx, ctx.mouse[0], ctx.mouse[1])) != null;
            const r = ctx.cam.ray(ctx.mouse[0], ctx.mouse[1], @floatFromInt(ctx.win_width), @floatFromInt(ctx.win_height));
            self.hover = if (self.over_ui) null else terrainHit(&self.world.terrain, r.origin, r.dir);
            if (self.lmb and self.hover != null) switch (self.tool) {
                .raise, .lower, .flatten, .cliff, .ditch, .smooth => self.brush(self.hover.?[0], self.hover.?[1], ctx.dt),
                .path => self.placePath(self.hover.?) catch {},
                else => {},
            };
            try self.drawOverlays();
        }

        // Feeders look full or empty; redraw them when that changes.
        {
            var state: u64 = 0;
            for (self.sim.feeders.items) |f| state = state *% 31 +% f.prop_id *% 2 +% @intFromBool(f.food >= 1);
            if (state != self.feeder_state) {
                self.feeder_state = state;
                self.world.revision += 1;
            }
        }

        // Simulation.
        if (self.opts.sim) {
            self.updateGuestCap();
            const pop = self.challengeOpen();
            if (pop) if (self.scen) |m| {
                self.syncUiState();
                m.update(ctx.dt);
            };
            if (!self.paused and self.menu == .none and !pop) {
                self.sim.advance(&self.world, ctx.dt * self.speed);
                self.updateFame(ctx.dt * self.speed);
                self.lifeTick(ctx.dt * self.speed);
                if (self.scen) |m| {
                    self.syncUiState();
                    m.update(ctx.dt * self.speed);
                    if (self.scen_tutorial) {
                        const cur: ?*const scenario_mod.Node = m.currentPending();
                        if (cur != self.hint_node) {
                            self.hint_node = cur;
                            self.hint_since = self.app_time;
                        } else if (cur != null and self.app_time - self.hint_since > 90) {
                            self.hint_since = self.app_time;
                            self.pushAlert(2, "STUCK ON A GOAL? PRESS F10 TO SKIP IT", .{});
                        }
                    }
                    if (m.roots.items.len > 0) {
                        const st = m.roots.items[0].state;
                        if (st == .success) self.markScenarioDone();
                        if (self.scen_result == .running and !m.challenge_mode and (st == .success or st == .failed)) {
                            self.scen_result = if (st == .success) .won else .lost;
                            self.openMenu(.result);
                        }
                    }
                }
            }
            for (self.actor_ids.items, 0..) |id, i| {
                const ag = self.sim.agentFor(id) orelse continue;
                const root = self.modelMatrixAt(ag.pos, ag.yaw, self.actor_scales.items[i]);
                if (!std.mem.eql(u8, self.inst_anim.items[i], ag.anim_name)) {
                    const names = [_][]const u8{ ag.anim_name, "Stand_Idle", "Idle" };
                    self.scene.driveInstance(i, root, &names, ag.anim_time);
                    self.inst_anim.items[i] = ag.anim_name;
                    if (self.audio) |*au| if (self.scene.instances.items[i].manifest) |mf| if (mf.animation(ag.anim_name)) |an| {
                        au.animStarted(ag.binder, an.path, ag.pos);
                    };
                } else {
                    const inst = &self.scene.instances.items[i];
                    inst.root = root;
                    inst.time = ag.anim_time;
                }
            }
        }

        if (self.track_id) |tid| {
            if (self.sim.agentFor(tid)) |tag| {
                ctx.cam.center = .{ tag.pos[0], tag.pos[1], tag.pos[2] };
                ctx.snap_camera = true;
            } else self.track_id = null;
        }
        if (self.audio) |*a| {
            if (self.audio_biome_dirty) {
                self.audio_biome_dirty = false;
                if (a.enabled) a.setBiome(self.dominantBiome());
            }
            const cm = ctx.cam;
            a.setListener(.{
                cm.center[0] + cm.dist * @cos(cm.pitch) * @cos(cm.yaw),
                cm.center[1] + cm.dist * @cos(cm.pitch) * @sin(cm.yaw),
                cm.center[2] + cm.dist * @sin(cm.pitch),
            }, cm.yaw);
            a.update(ctx.dt);
        }

        if (self.title_dirty) self.updateTitle(ctx.win);
    }
};

/// Reads a file from disk if it exists there, otherwise from the game data.
fn readAny(gpa: std.mem.Allocator, io: Io, vfs: *vfs_mod.Vfs, path: []const u8) ![]u8 {
    if (Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited)) |data| return data else |_| {}
    return vfs.read(gpa, path);
}

/// Loads a map from the game data or a save from disk into a world.
pub fn loadWorld(gpa: std.mem.Allocator, io: Io, vfs: *vfs_mod.Vfs, path: []const u8) !world_mod.World {
    const map_bytes = try readAny(gpa, io, vfs, path);
    defer gpa.free(map_bytes);
    var mp = try map_mod.parse(gpa, map_bytes);
    defer mp.deinit();
    const dir = std.fs.path.dirname(path) orelse "";
    const terr_path = try std.fs.path.join(gpa, &.{ dir, mp.terrain_file });
    defer gpa.free(terr_path);
    const terr_bytes = try readAny(gpa, io, vfs, terr_path);
    defer gpa.free(terr_bytes);
    var terr = try terrain_mod.parse(gpa, terr_bytes);
    errdefer terr.deinit();
    return world_mod.World.fromMap(gpa, &mp, terr);
}

/// An empty flat map: no objects, a generated terrain and the game's plain environment.
pub fn loadBlankWorld(gpa: std.mem.Allocator, io: Io, vfs: *vfs_mod.Vfs, tiles: u32, biome: u8) !world_mod.World {
    _ = io;
    _ = vfs;
    var mp = try map_mod.parse(gpa,
        \\<BFContext><ZTWorldMgr terrFile="blank.dat" environment="world/environments/env1noskirt.xml"/></BFContext>
    );
    defer mp.deinit();
    var terr = try terrain_mod.blank(gpa, tiles, tiles, biome);
    errdefer terr.deinit();
    return world_mod.World.fromMap(gpa, &mp, terr);
}

/// Loads the lights, fog and sky timing for a map's environment file; null
/// if it cannot be found (the renderer then uses plain lighting).
fn loadEnvironment(gpa: std.mem.Allocator, vfs: *vfs_mod.Vfs, env_path: []const u8) ?environment.Environment {
    if (env_path.len == 0) return null;
    const env_bytes = vfs.read(gpa, env_path) catch return null;
    defer gpa.free(env_bytes);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = xml.parse(arena.allocator(), env_bytes, null) catch return null;
    const lights_path = root.attr("lights") orelse return null;
    const lights = vfs.read(gpa, lights_path) catch return null;
    defer gpa.free(lights);
    const fog: ?[]u8 = if (root.child("fog")) |f| (if (f.attr("file")) |p| vfs.read(gpa, p) catch null else null) else null;
    defer if (fog) |b| gpa.free(b);
    const sky: ?[]u8 = if (root.child("skylayers")) |f| (if (f.attr("file")) |p| vfs.read(gpa, p) catch null else null) else null;
    defer if (sky) |b| gpa.free(b);
    return environment.Environment.parse(gpa, lights, fog, sky) catch null;
}

pub fn run(gpa: std.mem.Allocator, io: Io, vfs: *vfs_mod.Vfs, path: []const u8, opts: Options) !void {
    var world = try loadWorld(gpa, io, vfs, path);
    errdefer world.deinit();

    var gfx: viewer.Gfx = undefined;
    try gfx.open(opts.viewer);
    defer gfx.close();

    var scene = try viewer.Scene.init(gpa, &gfx.g, vfs);
    defer scene.deinit();
    scene.interactive = false;
    scene.want_skin = false;
    scene.dynamic_draws = false;
    scene.fx.modern = opts.modern;
    scene.fx.shadows = opts.modern and !opts.no_shadows;
    scene.fx.ssao = opts.modern and !opts.no_post;
    scene.fx.bloom = opts.modern and !opts.no_post;
    scene.fx.fxaa = opts.modern and !opts.no_post;

    var look = try viewer.terrainLook(gpa, vfs, &scene, &world.terrain);
    viewer.waterLook(gpa, vfs, &scene, &world.terrain) catch {};
    errdefer look.deinit(gpa);
    var env = loadEnvironment(gpa, vfs, world.environment);
    errdefer if (env) |*e| e.deinit();
    scene.loadSky(if (env) |e| e.sky_times else &.{}) catch |e| std.debug.print("no sky: {s}\n", .{@errorName(e)});

    var reg = entity.Registry.init(gpa);
    errdefer reg.deinit();
    try reg.load(vfs);

    var app: App = .{
        .gpa = gpa,
        .io = io,
        .vfs = vfs,
        .gfx = &gfx,
        .scene = &scene,
        .world = world,
        .reg = reg,
        .sim = sim_mod.Sim.init(gpa, opts.seed),
        .look = look,
        .env = env,
        .tod = opts.tod,
        .tod_auto = opts.tod_auto,
        .opts = opts,
        .catalog_arena = .init(gpa),
        .save_arena = .init(gpa),
    };
    defer app.deinit();
    if (!opts.no_sound) app.audio = audio_mod.Engine.init(gpa, vfs, opts.seed, opts.viewer.screenshot == null);
    app.sim.zoo.income = app.world.income;
    app.sim.zoo.guests_total = app.world.guests_total;
    app.sim.zoo.views = app.world.views;
    app.loadHud();
    app.loadGuestConfig();
    app.installHooks();
    try app.buildMapList();
    if (opts.pick_map) app.openMenu(.main);
    try app.buildCatalogs();
    if (opts.scenario.len > 0) app.startScenario(opts.scenario);
    app.runScript(opts.script);
    try app.splitInput(opts.input);
    std.debug.print("{d} objects, {d} fence types, {d} path textures, {d} animals/people in the catalogs\n", .{
        app.props.items.len, app.fence_kinds.items.len, app.path_textures.items.len, app.actor_names.items.len,
    });

    const t = &app.world.terrain;
    const cx = t.world_width / 2;
    const cy = t.world_height / 2;
    const radius = @max(t.world_width, t.world_height) / 2;
    const fx = if (opts.viewer.focus) |f| f[0] else cx;
    const fy = if (opts.viewer.focus) |f| f[1] else cy;
    const cam: viewer.Camera = .{
        .center = .{ fx, fy, t.zAt(fx, fy) },
        .radius = radius,
        .dist = radius * 1.3,
        .pitch = 0.8,
    };
    var vopts = opts.viewer;
    if (opts.tools) vopts.orbit_button = 3;
    // With virtual input the script decides when the screenshot is taken.
    if (opts.input.len > 0) vopts.shot_frames = std.math.maxInt(u32);
    try viewer.loopWith(gpa, &gfx, &scene, cam, null, vopts, &app);
}
