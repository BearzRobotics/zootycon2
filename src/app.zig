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
const vfs_mod = @import("vfs.zig");

const Mat4 = viewer.Mat4;

// SDL scancodes used by the tools.
const sc = struct {
    const c: u32 = 6;
    const p: u32 = 19;
    const r: u32 = 21;
    const x: u32 = 27;
    const z: u32 = 29;
    const k1: u32 = 30;
    const k8: u32 = 37;
    const tab: u32 = 43;
    const lbracket: u32 = 47;
    const rbracket: u32 = 48;
    const comma: u32 = 54;
    const period: u32 = 55;
    const t: u32 = 23;
    const f1: u32 = 58;
    const f2: u32 = 59;
    const f3: u32 = 60;
    const f5: u32 = 62;
    const f9: u32 = 66;
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
    actor,

    fn label(self: Tool) []const u8 {
        return switch (self) {
            .select => "select",
            .prop => "place object",
            .fence => "fence line",
            .path => "paths",
            .raise => "raise terrain",
            .lower => "lower terrain",
            .flatten => "flatten terrain",
            .actor => "place animal/guest",
        };
    }
};

const SelKind = enum { prop, fence, path, actor };
const Sel = struct { kind: SelKind, id: u32 };

/// Something the undo key can reverse.
const UndoOp = union(enum) {
    /// Remove records that were added.
    added: []u32,
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
    /// Build commands run at startup, separated by `;` (for tests and demos):
    ///   prop X Y | actor X Y | path X Y | fence X1 Y1 X2 Y2 | raise X Y SECS
    ///   lower X Y SECS | flatten X Y SECS | delete X Y | undo | save | load
    ///   wait SECS | propname TEXT | actorname NAME | fencekind NAME | yaw RAD
    script: []const u8 = "",
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
    synced_terrain_rev: u32 = std.math.maxInt(u32),
    last_terrain_secs: f32 = -1,

    // Instance bookkeeping: instance i shows actor `actor_ids[i]`.
    actor_ids: std.ArrayList(u32) = .empty,
    actor_scales: std.ArrayList(f32) = .empty,
    inst_anim: std.ArrayList(?sim_mod.Anim) = .empty,
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
    catalog_arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *App) void {
        for (self.undo.items) |op| if (op == .added) self.gpa.free(op.added);
        self.undo.deinit(self.gpa);
        self.input_cmds.deinit(self.gpa);
        self.props.deinit(self.gpa);
        self.fence_kinds.deinit(self.gpa);
        self.path_textures.deinit(self.gpa);
        self.actor_names.deinit(self.gpa);
        self.catalog_arena.deinit();
        var it = self.actor_defs.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.actor_defs.deinit(self.gpa);
        self.actor_ids.deinit(self.gpa);
        self.actor_scales.deinit(self.gpa);
        self.inst_anim.deinit(self.gpa);
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
                const bad = [_][]const u8{ "broken", "gate", "_end", "_mm" };
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
        const z = self.world.terrain.zAt(f.position[0], f.position[1]);
        return viewer.fromTransform(.{
            .translation = .{ f.position[0], f.position[1], z },
            .rotation = world_mod.yawRotation(f.rotation),
            .scale = 1,
        });
    }

    /// Rebuilds every static draw from the world.
    fn rebuildStatic(self: *App) !void {
        const scene = self.scene;
        scene.clearStatic();
        for (self.world.props.items) |p| {
            const draws = (try scene.loadModel(p.model)) orelse continue;
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
            try self.inst_anim.append(self.gpa, null);
        }
    }

    fn rebuildTerrain(self: *App) !void {
        try self.scene.addTerrain(&self.world.terrain, .{ 1, 1, 1, 1 }, self.look.flat, self.look.steep, self.look.slot_of);
    }

    fn syncScene(self: *App, secs: f32) !void {
        if (self.synced_rev != self.world.revision) {
            try self.rebuildStatic();
            try self.rebuildActors();
            try self.sim.sync(&self.world);
            // Match walking speed to the walk animation so feet do not slide.
            for (self.actor_ids.items, 0..) |id, i| {
                const ag = self.sim.agentFor(id) orelse continue;
                if (self.scene.walkSpeed(i)) |sp| ag.speed = sp * self.actor_scales.items[i];
            }
            self.synced_rev = self.world.revision;
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

    fn pushAdded(self: *App, ids: []const u32) void {
        const copy = self.gpa.dupe(u32, ids) catch return;
        self.undo.append(self.gpa, .{ .added = copy }) catch self.gpa.free(copy);
    }

    fn placeProp(self: *App, at: [3]f32) !void {
        if (self.props.items.len == 0) return;
        const model = self.props.items[self.prop_i];
        const id = try self.world.addProp(model, at, world_mod.yawRotation(self.yaw), 1.0, &.{});
        self.pushAdded(&.{id});
        self.say("placed {s}", .{std.fs.path.basename(model)});
    }

    fn placeActor(self: *App, at: [3]f32) !void {
        if (self.actor_names.items.len == 0) return;
        const name = self.actor_names.items[self.actor_i];
        const def = self.actorDef(name) orelse {
            self.say("{s} has no model", .{name});
            return;
        };
        _ = def;
        const id = try self.world.addActor(name, at, world_mod.yawRotation(self.yaw), &.{});
        self.pushAdded(&.{id});
        self.say("placed {s}", .{name});
    }

    fn placePath(self: *App, at: [3]f32) !void {
        if (self.path_textures.items.len == 0) return;
        const x = snap(at[0], 1.5);
        const y = snap(at[1], 1.5);
        for (self.world.paths.items) |p| {
            if (@abs(p.position[0] - x) < 1.0 and @abs(p.position[1] - y) < 1.0) return;
        }
        const id = try self.world.addPath(self.path_textures.items[self.path_i], .{ x, y }, 6, 6);
        self.pushAdded(&.{id});
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
        for (0..n) |i| {
            const k = @as(f32, @floatFromInt(i)) * 3.0;
            const x = a[0] + @cos(theta) * k;
            const y = a[1] + @sin(theta) * k;
            const id = try self.world.addFence(kind, .{ x, y, 0 }, theta);
            try ids.append(self.gpa, id);
        }
        self.pushAdded(ids.items);
        self.say("fence: {d} x {s}", .{ n, kind });
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
                self.undo.append(self.gpa, .{ .removed_actor = p }) catch {};
                break;
            },
        }
        if (self.world.remove(sel.id)) self.say("deleted", .{});
        self.selected = null;
    }

    fn doUndo(self: *App) void {
        const op = self.undo.pop() orelse return self.say("nothing to undo", .{});
        switch (op) {
            .added => |ids| {
                for (ids) |id| _ = self.world.remove(id);
                self.gpa.free(ids);
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
        const radius: f32 = 7.0;
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
                const w = f * f;
                const z = &t.z[j * t.width + i];
                switch (self.tool) {
                    .raise => z.* += 6.0 * dt * w,
                    .lower => z.* -= 6.0 * dt * w,
                    .flatten => z.* += (self.flatten_to - z.*) * @min(1.0, 8.0 * dt) * w,
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
        var name: []const u8 = self.world.name;
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

    fn saveWorld(self: *App) !void {
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
        const fresh = loadWorld(self.gpa, self.io, self.vfs, zt2_path) catch |e| {
            self.say("no save to load ({s})", .{@errorName(e)});
            return;
        };
        self.world.deinit();
        self.world = fresh;
        self.look.deinit(self.gpa);
        self.look = try viewer.terrainLook(self.gpa, self.vfs, self.scene, &self.world.terrain);
        for (self.undo.items) |op| if (op == .added) self.gpa.free(op.added);
        self.undo.clearRetainingCapacity();
        self.selected = null;
        self.fence_start = null;
        self.synced_rev = std.math.maxInt(u32);
        self.synced_terrain_rev = std.math.maxInt(u32);
        self.sim.deinit();
        self.sim = sim_mod.Sim.init(self.gpa, self.opts.seed);
        self.say("loaded {s}", .{zt2_path});
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
        } else if (std.mem.eql(u8, verb, "wait")) {
            const secs = try num(it.next());
            try self.sim.sync(&self.world);
            var t: f32 = 0;
            while (t < secs) : (t += 0.2) self.sim.advance(&self.world, 0.2);
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
            .{ .n = "f5", .c = sc.f5 },
            .{ .n = "f9", .c = sc.f9 },
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
                std.debug.print("agent #{d}: {s} speed={d:.2} state={s}\n", .{ ag.id, @tagName(ag.kind), ag.speed, @tagName(ag.state) });
            }
            std.debug.print("perf: {d:.1} fps ({d} static draws, {d} actor draws)\n", .{ if (ctx.dt > 0) 1.0 / ctx.dt else 0.0, self.scene.draws.items.len, self.scene.actor_draws.items.len });
            std.debug.print("cam: yaw={d:.3} pitch={d:.3} dist={d:.2} center=({d:.1},{d:.1})\n", .{ ctx.cam.yaw, ctx.cam.pitch, ctx.cam.dist, ctx.cam.center[0], ctx.cam.center[1] });
        } else if (std.mem.eql(u8, verb, "shot")) {
            ctx.shot_request = true;
        } else if (std.mem.eql(u8, verb, "quit")) {
            ctx.quit = true;
        } else return error.UnknownCommand;
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
                    sc.t => {
                        self.tod_auto = !self.tod_auto;
                        self.say("time of day {s}", .{if (self.tod_auto) "running" else "stopped"});
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
            .mouse_button => |b| if (self.opts.tools and b.button == 1) {
                if (b.down) {
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

    fn toolKey(self: *App, code: u32) void {
        if (code >= sc.k1 and code <= sc.k8) {
            const tools = [_]Tool{ .select, .prop, .fence, .path, .raise, .lower, .flatten, .actor };
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
            },
            .prop => if (hit) |h| self.placeProp(h) catch {},
            .actor => if (hit) |h| self.placeActor(h) catch {},
            .path => if (hit) |h| self.placePath(h) catch {},
            .fence => if (hit) |h| {
                const p = [2]f32{ snap(h[0], 3.0), snap(h[1], 3.0) };
                if (self.fence_start) |s| {
                    self.placeFenceLine(s, p) catch {};
                    self.fence_start = p; // keep drawing from the end
                } else self.fence_start = p;
                self.title_dirty = true;
            },
            .flatten => if (hit) |h| {
                self.flatten_to = h[2];
            },
            .raise, .lower => {},
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
            .prop => "CLICK THE GROUND TO PLACE. [ ] CHANGE OBJECT, R ROTATES",
            .fence => "CLICK WHERE THE FENCE STARTS, THEN CLICK EACH CORNER. C ENDS THE LINE",
            .path => "CLICK OR DRAG TO PAINT PATH TILES. [ ] CHANGE PATH",
            .raise => "HOLD LEFT MOUSE TO RAISE THE GROUND",
            .lower => "HOLD LEFT MOUSE TO LOWER THE GROUND",
            .flatten => "CLICK TO PICK A HEIGHT, THEN HOLD TO FLATTEN TO IT",
            .actor => "CLICK THE GROUND TO PLACE. [ ] CHANGE ANIMAL OR PERSON",
        };
    }

    /// The on-screen display, drawn over the scene each frame.
    pub fn overlay(self: *App, ui: *viewer.Ui, ctx: *viewer.FrameCtx) !void {
        const scale: f32 = @max(1, @floor(ui.height / 360));
        const pad = 6 * scale;
        const line = 10 * scale;
        const white = [4]f32{ 1, 1, 1, 1 };
        const yellow = [4]f32{ 1, 0.92, 0.5, 1 };
        const grey = [4]f32{ 0.8, 0.85, 0.9, 1 };
        var buf: [256]u8 = undefined;
        var y = pad;

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
            else => {},
        }
        const head = if (self.opts.tools)
            std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ self.tool.label(), if (detail.len > 0) ": " else "", detail }) catch ""
        else
            "VIEW";
        try ui.label(pad, y, scale, head, white);
        y += line + 2 * scale;
        if (self.opts.tools and self.show_help) {
            try ui.label(pad, y, scale, self.toolHint(), grey);
            y += line + 2 * scale;
        }
        if (self.message_len > 0) {
            try ui.label(pad, y, scale, self.message[0..self.message_len], yellow);
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
        try ui.label(ui.width - sw - pad, pad, scale, status, white);

        // Selection.
        if (self.selected) |sel| {
            const t = std.fmt.bufPrint(&buf, "SELECTED {s} #{d}", .{ @tagName(sel.kind), sel.id }) catch "";
            const w2 = viewer.Ui.textWidth(t, scale);
            try ui.label(ui.width - w2 - pad, pad + line + 2 * scale, scale, t, yellow);
        }

        // Key reference.
        if (self.show_help) {
            const lines = if (self.opts.tools) [_][]const u8{
                "1 SELECT  2 OBJECT  3 FENCE  4 PATH  5 RAISE  6 LOWER  7 FLATTEN  8 ANIMAL/PERSON",
                "[ ] CHOOSE (SHIFT: x10)  R ROTATE  Z UNDO  TAB PAUSE  , . SPEED  F5 SAVE  F9 LOAD",
                "T RUN/STOP CLOCK   F2 F3 PREVIOUS/NEXT TIME OF DAY",
                "RIGHT-DRAG ORBIT   WHEEL ZOOM   WASD PAN   F1 HIDE THIS   ESC QUIT",
            } else [_][]const u8{
                "TAB PAUSE  , . SPEED   T RUN/STOP CLOCK   F2 F3 TIME OF DAY",
                "RIGHT OR LEFT-DRAG ORBIT   WHEEL ZOOM   WASD PAN   ESC QUIT",
                "",
                "",
            };
            var by = ui.height - pad - line * @as(f32, @floatFromInt(lines.len));
            for (lines) |l| {
                if (l.len > 0) try ui.label(pad, by, scale, l, grey);
                by += line;
            }
        }
        _ = ctx;
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

    pub fn frame(self: *App, ctx: *viewer.FrameCtx) !void {
        self.playInput(ctx);
        if (self.tod_auto) {
            self.tod += ctx.dt * (if (self.paused) 0 else self.speed) / self.day_len;
            self.tod -= @floor(self.tod);
        }
        self.scene.tod = self.tod;
        self.scene.lighting = if (self.env) |*e| e.sample(self.tod) else null;
        try self.syncScene(ctx.secs);

        // Hover point under the mouse.
        if (self.opts.tools) {
            const r = ctx.cam.ray(ctx.mouse[0], ctx.mouse[1], @floatFromInt(ctx.win_width), @floatFromInt(ctx.win_height));
            self.hover = terrainHit(&self.world.terrain, r.origin, r.dir);
            if (self.lmb and self.hover != null) switch (self.tool) {
                .raise, .lower, .flatten => self.brush(self.hover.?[0], self.hover.?[1], ctx.dt),
                .path => self.placePath(self.hover.?) catch {},
                else => {},
            };
            try self.drawOverlays();
        }

        // Simulation.
        if (self.opts.sim) {
            if (!self.paused) self.sim.advance(&self.world, ctx.dt * self.speed);
            for (self.actor_ids.items, 0..) |id, i| {
                const ag = self.sim.agentFor(id) orelse continue;
                const root = self.modelMatrixAt(ag.pos, ag.yaw, self.actor_scales.items[i]);
                if (self.inst_anim.items[i] != ag.anim) {
                    const names: []const []const u8 = switch (ag.anim) {
                        .idle => &.{ "Stand_Idle", "Idle" },
                        .walk => &.{ "Walk_Ahead", "Walk" },
                    };
                    self.scene.driveInstance(i, root, names, ag.anim_time);
                    self.inst_anim.items[i] = ag.anim;
                } else {
                    const inst = &self.scene.instances.items[i];
                    inst.root = root;
                    inst.time = ag.anim_time;
                }
            }
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

    var look = try viewer.terrainLook(gpa, vfs, &scene, &world.terrain);
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
    };
    defer app.deinit();
    try app.buildCatalogs();
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
