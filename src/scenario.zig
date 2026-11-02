//! Scenario goals. A scenario is a tree of groups and rules read from
//! `scenario/goals/*.xml`; every rule names Lua entries (in the game's
//! compiled scripts) that decide whether it is met, and what happens when it
//! is. The manager walks the tree every couple of seconds, calls those
//! entries with the rule's persistent `comp` table, and keeps the results.
//!
//! An `evaluate` entry returns 1 (done), -1 (failed) or anything else (still
//! going). `success` and `failure` entries run once when a rule resolves.

const std = @import("std");
const c = @import("lua_c");
const xml = @import("xml.zig");
const script = @import("script.zig");
const loc_mod = @import("loc.zig");
const vfs_mod = @import("vfs.zig");
const uistate = @import("uistate.zig");

pub const State = enum { pending, success, failed };

/// A Lua entry point: `script` is the game path, `entry` the function name.
pub const Action = struct {
    script: []const u8,
    entry: [:0]const u8,
};

/// Texts a rule shows, as localized ids. `alt_*` hold text scripts built at
/// run time (setalttext), which replace the id when set.
pub const Info = struct {
    primary: bool = false,
    neutral: []const u8 = "",
    neutral_overview: []const u8 = "",
    success: []const u8 = "",
    success_overview: []const u8 = "",
    failure: []const u8 = "",
    failure_overview: []const u8 = "",
};

pub const Node = struct {
    name: []const u8,
    is_group: bool,
    hidden: bool = false,
    chain: bool = false,
    allsuccess: bool = true,
    sticky: bool = true,
    state: State = .pending,
    info: Info = .{},
    children: []const *Node = &.{},
    on_eval: ?Action = null,
    on_success: ?Action = null,
    on_failure: ?Action = null,
    /// Registry reference of the rule's persistent Lua table (0 = none yet).
    comp: c_int = 0,
    /// Texts set by scripts at run time.
    alt_neutral: ?[]const u8 = null,
    alt_neutral_overview: ?[]const u8 = null,
    alt_success: ?[]const u8 = null,
    alt_success_overview: ?[]const u8 = null,
    alt_failure: ?[]const u8 = null,
};

/// The game as scenario scripts see it. The application fills this in;
/// the defaults describe an empty world so the manager runs on its own.
pub const Host = struct {
    ctx: *anyopaque = undefined,
    /// Handles of the entities of a kind: a category (`animal`, `entrance`),
    /// a species (`TigerBengal`) or a binder (`frontgate_df`). `direct`
    /// means exactly that type rather than anything derived from it.
    entities: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, kind: []const u8, direct: bool, out: *std.ArrayList(u32)) void = noEntities,
    /// A number about an entity (`hunger`, `hygiene`...), if it has one.
    attr: *const fn (ctx: *anyopaque, id: u32, name: []const u8) ?f64 = noAttr,
    set_attr: *const fn (ctx: *anyopaque, id: u32, name: []const u8, value: f64) void = noSetAttr,
    /// Entity flags (`b_Adult`) and text attributes (`s_Name`).
    attr_bool: *const fn (ctx: *anyopaque, id: u32, name: []const u8) bool = noBool,
    attr_str: *const fn (ctx: *anyopaque, id: u32, name: []const u8) ?[]const u8 = noStr,
    /// Whether the entity is of a kind (category, species or binder).
    kind_of: *const fn (ctx: *anyopaque, id: u32, kind: []const u8) bool = noKind,
    /// The entity's binder name.
    binder: *const fn (ctx: *anyopaque, id: u32) []const u8 = noBinder,
    /// The interface the scripts drive; null until the application sets it.
    ui: ?*uistate.State = null,
    /// Whether a UI node exists in the layouts that are loaded.
    ui_known: *const fn (ctx: *anyopaque, name: []const u8) bool = noKnown,
    /// The entity the player has selected, if any.
    selected: *const fn (ctx: *anyopaque) ?u32 = noSelected,
    /// Zoo-wide numbers by name: `cash`, `month`, `day`, `time`, `fame`
    /// (in half stars), `guests`.
    stat: *const fn (ctx: *anyopaque, name: []const u8) f64 = noStat,
    give_cash: *const fn (ctx: *anyopaque, amount: f64) void = noCash,
};

fn noEntities(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: bool, _: *std.ArrayList(u32)) void {}
fn noAttr(_: *anyopaque, _: u32, _: []const u8) ?f64 {
    return null;
}
fn noKnown(_: *anyopaque, _: []const u8) bool {
    return false;
}
fn noSelected(_: *anyopaque) ?u32 {
    return null;
}
fn noBool(_: *anyopaque, _: u32, _: []const u8) bool {
    return false;
}
fn noStr(_: *anyopaque, _: u32, _: []const u8) ?[]const u8 {
    return null;
}
fn noKind(_: *anyopaque, _: u32, _: []const u8) bool {
    return false;
}
fn noSetAttr(_: *anyopaque, _: u32, _: []const u8, _: f64) void {}
fn noBinder(_: *anyopaque, _: u32) []const u8 {
    return "";
}
fn noStat(_: *anyopaque, _: []const u8) f64 {
    return 0;
}
fn noCash(_: *anyopaque, _: f64) void {}

/// What a finished scenario came to.
pub const Outcome = enum { running, won, lost };

pub const Manager = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    vfs: *vfs_mod.Vfs,
    eng: *script.Engine,
    loc: *const loc_mod.Loc,
    roots: std.ArrayList(*Node) = .empty,
    /// Game-wide and per-user script variables (strings).
    vars: std.StringHashMapUnmanaged([]const u8) = .empty,
    accum: f32 = 0,
    interval: f32 = 2,
    outcome: Outcome = .running,
    /// Lines scripts asked to show (win/fail panels, hints), oldest first.
    messages: std.ArrayList([]const u8) = .empty,
    log: bool = false,
    host: Host = .{},
    /// Localized id of the scenario's introduction (the root's `info`).
    intro: []const u8 = "",

    pub fn create(gpa: std.mem.Allocator, vfs: *vfs_mod.Vfs, loc: *const loc_mod.Loc) !*Manager {
        const eng = try script.Engine.create(gpa, vfs);
        errdefer eng.destroy();
        const self = try gpa.create(Manager);
        self.* = .{ .gpa = gpa, .arena = .init(gpa), .vfs = vfs, .eng = eng, .loc = loc };
        active = self;
        registerApi(eng);
        return self;
    }

    pub fn destroy(self: *Manager) void {
        self.eng.destroy();
        self.roots.deinit(self.gpa);
        self.vars.deinit(self.gpa);
        self.messages.deinit(self.gpa);
        self.arena.deinit();
        if (active == self) active = null;
        self.gpa.destroy(self);
    }

    /// Loads a goals file and adds its tree to the running scenario.
    pub fn add(self: *Manager, path: []const u8) !void {
        const data = try self.vfs.read(self.gpa, normalize(path, &path_buf));
        defer self.gpa.free(data);
        var scratch: std.heap.ArenaAllocator = .init(self.gpa);
        defer scratch.deinit();
        const root = try xml.parse(scratch.allocator(), data, null);
        const node = try self.buildNode(root);
        if (std.ascii.eqlIgnoreCase(root.name, "ZTScenarioMgr")) {
            if (root.child("info")) |inf| if (inf.attr("locid")) |id| {
                self.intro = try self.dup(id);
            };
            if (root.attr("interval")) |v| self.interval = std.fmt.parseFloat(f32, v) catch self.interval;
        }
        try self.roots.append(self.gpa, node);
    }

    var path_buf: [256]u8 = undefined;

    fn normalize(path: []const u8, buf: []u8) []const u8 {
        const n = @min(path.len, buf.len);
        for (path[0..n], buf[0..n]) |ch, *o| o.* = if (ch == '\\') '/' else std.ascii.toLower(ch);
        return buf[0..n];
    }

    fn dup(self: *Manager, s: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, s);
    }

    fn boolAttr(e: *const xml.Element, name: []const u8, default: bool) bool {
        const v = e.attr(name) orelse return default;
        return std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true");
    }

    fn parseAction(self: *Manager, e: ?*const xml.Element) !?Action {
        const act = (e orelse return null).child("BFScenarioScriptAction") orelse return null;
        const a = self.arena.allocator();
        const sc = act.attr("script") orelse return null;
        const en = act.attr("entry") orelse return null;
        const entry = try a.allocSentinel(u8, en.len, 0);
        @memcpy(entry, en);
        return .{ .script = try self.dup(sc), .entry = entry };
    }

    fn parseInfo(self: *Manager, e: ?*const xml.Element) !Info {
        var info: Info = .{};
        const el = e orelse return info;
        info.primary = if (el.attr("type")) |t| std.ascii.eqlIgnoreCase(t, "primary") else false;
        if (el.child("neutral")) |n| {
            info.neutral = try self.dup(n.attr("locid") orelse "");
            info.neutral_overview = try self.dup(n.attr("overview") orelse "");
        }
        if (el.child("success")) |n| {
            info.success = try self.dup(n.attr("locid") orelse "");
            info.success_overview = try self.dup(n.attr("overview") orelse "");
        }
        if (el.child("failure")) |n| {
            info.failure = try self.dup(n.attr("locid") orelse "");
            info.failure_overview = try self.dup(n.attr("overview") orelse "");
        }
        return info;
    }

    fn buildNode(self: *Manager, e: *const xml.Element) !*Node {
        const a = self.arena.allocator();
        const node = try a.create(Node);
        const is_group = !std.ascii.eqlIgnoreCase(e.name, "BFScenarioRule");
        node.* = .{
            .name = try self.dup(e.attr("name") orelse ""),
            .is_group = is_group,
            .hidden = boolAttr(e, "hidden", false),
            .chain = boolAttr(e, "chain", false),
            .allsuccess = boolAttr(e, "allsuccess", true),
            .sticky = boolAttr(e, "sticky", true),
            .info = try self.parseInfo(e.child("info")),
            .on_eval = try self.parseAction(e.child("evaluate")),
            .on_success = try self.parseAction(e.child("success")),
            .on_failure = try self.parseAction(e.child("failure")),
        };
        if (e.child("children")) |ch| {
            var list: std.ArrayList(*Node) = .empty;
            for (ch.children) |k| {
                if (!std.ascii.eqlIgnoreCase(k.name, "BFScenarioRule") and !std.ascii.eqlIgnoreCase(k.name, "BFScenarioGroup")) continue;
                try list.append(a, try self.buildNode(k));
            }
            node.children = try list.toOwnedSlice(a);
        }
        return node;
    }

    pub fn find(self: *Manager, name: []const u8) ?*Node {
        for (self.roots.items) |r| if (findIn(r, name)) |n| return n;
        return null;
    }

    fn findIn(n: *Node, name: []const u8) ?*Node {
        if (std.ascii.eqlIgnoreCase(n.name, name)) return n;
        for (n.children) |k| if (findIn(k, name)) |f| return f;
        return null;
    }

    // ------------------------------------------------------------ running

    /// Advances the scenario clock; rules are checked every `interval` seconds.
    pub fn update(self: *Manager, dt: f32) void {
        if (self.outcome != .running) return;
        self.accum += dt;
        if (self.accum < self.interval) return;
        self.accum = 0;
        self.tick();
    }

    /// Checks every rule once.
    pub fn tick(self: *Manager) void {
        active = self;
        script.setCurrent(self.eng);
        // The tree can grow while we walk it (scripts add scenarios).
        var i: usize = 0;
        while (i < self.roots.items.len) : (i += 1) _ = self.evaluate(self.roots.items[i]);
    }

    fn evaluate(self: *Manager, n: *Node) State {
        if (n.state != .pending and n.sticky) return n.state;
        if (n.is_group) return self.evaluateGroup(n);
        return self.evaluateRule(n);
    }

    fn evaluateGroup(self: *Manager, n: *Node) State {
        var done: usize = 0;
        var failed = false;
        for (n.children) |k| {
            const s = self.evaluate(k);
            if (s == .success) done += 1;
            if (s == .failed) failed = true;
            if (n.chain and s == .pending) break;
        }
        if (n.children.len > 0) {
            if (failed and n.allsuccess) n.state = .failed else if ((n.allsuccess and done == n.children.len) or (!n.allsuccess and done > 0)) n.state = .success;
        }
        return n.state;
    }

    fn evaluateRule(self: *Manager, n: *Node) State {
        const act = n.on_eval orelse return n.state;
        const r = self.call(n, act) orelse return n.state;
        if (self.log and r != 0) std.debug.print("scenario: {s} -> {d}\n", .{ n.name, r });
        if (r >= 0.5) {
            n.state = .success;
            if (n.on_success) |s| _ = self.call(n, s);
        } else if (r <= -0.5) {
            n.state = .failed;
            if (n.on_failure) |s| _ = self.call(n, s);
        }
        return n.state;
    }

    /// Calls a rule's Lua entry with its comp table; null if the script
    /// failed (the error is kept in the engine).
    fn call(self: *Manager, n: *Node, act: Action) ?f64 {
        self.eng.load(act.script) catch |e| {
            if (self.log) std.debug.print("scenario: cannot load {s}: {s} {s}\n", .{ act.script, @errorName(e), self.eng.errorText() });
            return null;
        };
        if (n.comp == 0) n.comp = self.eng.newTableRef();
        const r = self.eng.callWithTable(act.entry, n.comp) catch |e| {
            if (self.log) std.debug.print("scenario: {s}.{s} failed: {s} {s}\n", .{ act.script, act.entry, @errorName(e), self.eng.errorText() });
            return null;
        };
        return r;
    }

    /// The text to show for a rule right now.
    pub fn textFor(self: *const Manager, n: *const Node) []const u8 {
        const pick = switch (n.state) {
            .pending => .{ n.alt_neutral, n.info.neutral },
            .success => .{ n.alt_success, n.info.success },
            .failed => .{ n.alt_failure, n.info.failure },
        };
        if (pick[0]) |t| return t;
        return self.loc.get(pick[1]) orelse pick[1];
    }

    /// The longer text of a rule for its current state, if it has one.
    pub fn overviewFor(self: *const Manager, n: *const Node) []const u8 {
        const pick = switch (n.state) {
            .pending => .{ n.alt_neutral_overview, n.info.neutral_overview },
            .success => .{ n.alt_success_overview, n.info.success_overview },
            .failed => .{ null, n.info.failure_overview },
        };
        if (pick[0]) |t| return t;
        if (pick[1].len == 0) return "";
        return self.loc.get(pick[1]) orelse "";
    }

    // ------------------------------------------------------------ vars

    pub fn setVar(self: *Manager, key: []const u8, value: []const u8) void {
        const a = self.arena.allocator();
        const v = a.dupe(u8, value) catch return;
        if (self.vars.getPtr(key)) |p| {
            p.* = v;
            return;
        }
        const k = a.dupe(u8, key) catch return;
        self.vars.put(self.gpa, k, v) catch {};
    }

    pub fn getVar(self: *const Manager, key: []const u8) ?[]const u8 {
        return self.vars.get(key);
    }

    /// Calls on game components (`ZTStatus:...`). Returns the number of
    /// results pushed, or null when the call is not handled.
    fn handleCall(self: *Manager, L: ?*c.lua_State, comp: []const u8, method: []const u8) ?c_int {
        const h = self.host;
        const eq = std.mem.eql;
        if (eq(u8, comp, "BFGManager")) {
            const cam = [_]struct { m: []const u8, n: []const u8 }{
                .{ .m = "BFG_GET_CAMERA_X", .n = "cam_x" },
                .{ .m = "BFG_GET_CAMERA_Y", .n = "cam_y" },
                .{ .m = "BFG_GET_CAMERA_Z", .n = "cam_z" },
                .{ .m = "BFG_GET_CAMERA_ZOOM", .n = "cam_zoom" },
                .{ .m = "BFG_GET_CAMERA_YAW", .n = "cam_yaw" },
            };
            for (cam) |cm| if (eq(u8, method, cm.m)) {
                c.lua_pushnumber(L, h.stat(h.ctx, cm.n));
                return 1;
            };
            if (eq(u8, method, "BFG_GET_SELECTED_ENTITY")) {
                if (h.selected(h.ctx)) |id| {
                    pushEntity(L, id);
                    return 1;
                }
                c.lua_pushnil(L);
                return 1;
            }
            const direct = eq(u8, method, "BFG_GET_ENTITIES_DIRECT");
            if (direct or eq(u8, method, "BFG_GET_ENTITIES")) {
                const kind = l.str(L, 2) orelse "";
                var ids: std.ArrayList(u32) = .empty;
                defer ids.deinit(self.gpa);
                h.entities(h.ctx, self.gpa, kind, direct, &ids);
                c.lua_newtable(L);
                for (ids.items, 1..) |id, i| {
                    c.lua_pushnumber(L, @floatFromInt(i));
                    c.lua_newtable(L);
                    c.lua_pushstring(L, "value");
                    c.lua_pushnumber(L, @floatFromInt(id));
                    c.lua_settable(L, -3);
                    c.lua_settable(L, -3);
                }
                return 1;
            }
        } else if (eq(u8, comp, "ZTStatus")) {
            const simple = [_]struct { m: []const u8, n: []const u8 }{
                .{ .m = "ZT_GET_ZOO_CASH", .n = "cash" },
                .{ .m = "ZT_GET_ZOO_FAME", .n = "fame" },
                .{ .m = "ZT_GET_ZOO_INCOME", .n = "income" },
                .{ .m = "ZT_GET_ZOO_PROFIT", .n = "profit" },
                .{ .m = "ZT_GET_ADMISSION_PRICE", .n = "admission" },
                .{ .m = "ZT_GET_SIM_TIME", .n = "simtime" },
                .{ .m = "ZT_GET_REAL_TIME", .n = "simtime" },
                .{ .m = "ZT_GET_IS_CAMPAIGN", .n = "is_campaign" },
                .{ .m = "ZT_GET_LIFETIME_INCOME", .n = "lifetime_income" },
                .{ .m = "ZT_GET_LIFETIME_USERS", .n = "guests_total" },
            };
            for (simple) |sm| if (eq(u8, method, sm.m)) {
                c.lua_pushnumber(L, h.stat(h.ctx, sm.n));
                return 1;
            };
            if (eq(u8, method, "ZT_GET_IS_FREEFORM")) {
                c.lua_pushnumber(L, 1 - h.stat(h.ctx, "is_campaign"));
                return 1;
            }
            if (eq(u8, method, "ZT_SET_ZOO_CASH")) {
                const want = if (c.lua_isnumber(L, 2) != 0) c.lua_tonumber(L, 2) else 0;
                h.give_cash(h.ctx, want - h.stat(h.ctx, "cash"));
                return 0;
            }
            if (eq(u8, method, "ZT_GET_ALL_ANIMALS_RELEASED") or eq(u8, method, "ZT_GET_ANIMALS_RELEASED") or eq(u8, method, "ZT_GET_ANIMALS_PUTUPFORADOPTION")) {
                c.lua_newtable(L);
                return 1;
            }
            if (eq(u8, method, "ZT_GET_DONATIONBYANIMALTYPE") or eq(u8, method, "ZT_GET_DONATION_ALLANIMALS") or eq(u8, method, "ZT_GET_DONATION_ENDANGERMENT")) {
                c.lua_pushnumber(L, h.stat(h.ctx, "donations"));
                return 1;
            }
            const stat: ?[]const u8 = if (eq(u8, method, "ZT_GET_FAME_HALFSTARS")) "fame" else if (eq(u8, method, "ZT_GET_CURRENT_MONTH")) "month" else if (eq(u8, method, "ZT_GET_CURRENT_DAYOFMONTH")) "day" else if (eq(u8, method, "ZT_GET_CURRENT_TIMEOFDAY")) "time" else if (eq(u8, method, "ZT_GET_NUM_GUESTS")) "guests" else null;
            if (stat) |name| {
                c.lua_pushnumber(L, h.stat(h.ctx, name));
                return 1;
            }
        }
        return null;
    }

    /// Calls on interface nodes (`ui:<name>`; the root is the empty name).
    fn uiCall(self: *Manager, L: ?*c.lua_State, name: []const u8, method: []const u8) c_int {
        const eq = std.mem.eql;
        const st = self.host.ui orelse return 0;
        if (eq(u8, method, "UI_GET_CHILD")) {
            const child = l.str(L, 2) orelse "";
            if (!self.host.ui_known(self.host.ctx, child)) {
                c.lua_pushnil(L);
                return 1;
            }
            var nb: [100]u8 = undefined;
            pushComponent(L, std.fmt.bufPrint(&nb, "ui:{s}", .{child}) catch "ui:");
            return 1;
        }
        if (name.len == 0) return 0;
        const e = st.at(name);
        if (eq(u8, method, "UI_SHOW")) {
            e.visible = true;
        } else if (eq(u8, method, "UI_HIDE")) {
            e.visible = false;
        } else if (eq(u8, method, "UI_ENABLE")) {
            e.enabled = true;
        } else if (eq(u8, method, "UI_DISABLE")) {
            e.enabled = false;
        } else if (eq(u8, method, "UI_ACTIVATE_ON")) {
            e.activated = true;
        } else if (eq(u8, method, "UI_ACTIVATE_OFF") or eq(u8, method, "UI_REPRESS")) {
            e.activated = false;
        } else if (eq(u8, method, "UI_ACTIVATE")) {
            e.activated = !e.activated;
        } else if (eq(u8, method, "UI_IS_ALTERNATE") or eq(u8, method, "UI_IS_ACTIVATED")) {
            c.lua_pushboolean(L, @intFromBool(e.activated));
            return 1;
        } else if (eq(u8, method, "UI_IS_HIDDEN")) {
            c.lua_pushboolean(L, @intFromBool(if (e.visible) |v| !v else false));
            return 1;
        } else if (eq(u8, method, "UI_IS_DISABLED")) {
            c.lua_pushboolean(L, @intFromBool(!e.enabled));
            return 1;
        } else if (eq(u8, method, "UI_IS_NORMAL")) {
            c.lua_pushboolean(L, @intFromBool(e.enabled and !e.activated));
            return 1;
        } else if (eq(u8, method, "UI_SET_LOCID")) {
            const id = l.str(L, 2) orelse "";
            st.setText(name, self.loc.get(id) orelse id);
        } else if (eq(u8, method, "UI_SET_TEXT")) {
            st.setText(name, l.str(L, 2) orelse "");
        } else if (eq(u8, method, "UI_GET_TEXT")) {
            l.pushStr(L, e.text);
            return 1;
        } else if (eq(u8, method, "UI_SET_POS")) {
            if (c.lua_isnumber(L, 2) != 0 and c.lua_isnumber(L, 3) != 0) e.pos = .{ @floatCast(c.lua_tonumber(L, 2)), @floatCast(c.lua_tonumber(L, 3)) };
        } else if (eq(u8, method, "UI_SET_SIZE")) {
            if (c.lua_isnumber(L, 2) != 0 and c.lua_isnumber(L, 3) != 0) e.size = .{ @floatCast(c.lua_tonumber(L, 2)), @floatCast(c.lua_tonumber(L, 3)) };
        } else if (eq(u8, method, "UI_GET_CHILDREN")) {
            c.lua_newtable(L);
            return 1;
        } else if (eq(u8, method, "UI_GET_STRING_SIZE")) {
            // width and height of a text as a table (the tutorial panel is 216 wide)
            const txt: []const u8 = l.str(L, 2) orelse e.text;
            const lines = (txt.len + 35) / 36;
            pushRect(L, 0, 0, @floatFromInt(@min(txt.len, 36) * 6), @floatFromInt(@max(1, lines) * 10));
            return 1;
        } else if (eq(u8, method, "UI_GET_SRC_RECT") or eq(u8, method, "UI_GET_SCREEN_RECT") or eq(u8, method, "UI_GET_IMAGE_SRC_RECT")) {
            const p = e.pos orelse .{ 0, 0 };
            const sz = e.size orelse .{ 70, 70 };
            pushRect(L, p[0], p[1], sz[0], sz[1]);
            return 1;
        } else {
            // placement, animation and sound calls have no effect here
            var nb: [160]u8 = undefined;
            if (script.currentEngine()) |en| en.noteMissing(std.fmt.bufPrint(&nb, "ui:{s}", .{method}) catch method);
        }
        return 0;
    }

    pub fn say(self: *Manager, text: []const u8) void {
        const t = self.arena.allocator().dupe(u8, text) catch return;
        self.messages.append(self.gpa, t) catch {};
    }
};

var active: ?*Manager = null;

// ---------------------------------------------------------------- Lua API

const l = struct {
    fn str(L: ?*c.lua_State, i: c_int) ?[]const u8 {
        if (c.lua_type(L, i) != c.LUA_TSTRING and c.lua_type(L, i) != c.LUA_TNUMBER) return null;
        return std.mem.span(c.lua_tostring(L, i));
    }
    fn pushStr(L: ?*c.lua_State, s: []const u8) void {
        c.lua_pushlstring(L, s.ptr, s.len);
    }
};

fn registerApi(eng: *script.Engine) void {
    eng.setGlobalNumber("SYSTRACE", 0);
    eng.setGlobalNumber("SYSNOTE", 1);
    eng.setGlobalNumber("SYSWARN", 2);
    eng.setGlobalNumber("SYSERROR", 3);
    eng.register("BFLOG", apiLog);
    eng.register("LUALOG", apiLog);
    eng.register("setglobalvar", apiSetVar);
    eng.register("getglobalvar", apiGetVar);
    eng.register("setuservar", apiSetVar);
    eng.register("getuservar", apiGetVar);
    eng.register("getLocID", apiLocId);
    eng.register("queryObject", apiQueryObject);
    eng.register("resolveTable", apiResolve);
    eng.register("areCompsEqual", apiCompsEqual);
    eng.register("giveCash", apiGiveCash);
    eng.register("howMuchCash", apiHowMuchCash);
    eng.register("getCurrentMonth", apiCurrentMonth);
    eng.register("getCurrentTimeOfDay", apiTimeOfDay);
}

fn statOf(name: []const u8) f64 {
    const m = active orelse return 0;
    return m.host.stat(m.host.ctx, name);
}

fn apiGiveCash(L: ?*c.lua_State) callconv(.c) c_int {
    const m = active orelse return 0;
    if (c.lua_isnumber(L, 1) != 0) m.host.give_cash(m.host.ctx, c.lua_tonumber(L, 1));
    return 0;
}

fn apiHowMuchCash(L: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushnumber(L, statOf("cash"));
    return 1;
}

fn apiCurrentMonth(L: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushnumber(L, statOf("month"));
    return 1;
}

fn apiTimeOfDay(L: ?*c.lua_State) callconv(.c) c_int {
    c.lua_pushnumber(L, statOf("time"));
    return 1;
}

/// An entity object for a handle: its methods are looked up on demand.
fn pushEntity(L: ?*c.lua_State, id: u32) void {
    c.lua_newtable(L);
    c.lua_pushstring(L, "__ent");
    c.lua_pushnumber(L, @floatFromInt(id));
    c.lua_settable(L, -3);
    c.lua_newtable(L);
    c.lua_pushstring(L, "__index");
    c.lua_pushcclosure(L, entityIndex, 0);
    c.lua_settable(L, -3);
    _ = c.lua_setmetatable(L, -2);
}

/// `resolveTable(entry.value)` turns an entity handle into an object.
fn apiResolve(L: ?*c.lua_State) callconv(.c) c_int {
    if (c.lua_isnumber(L, 1) == 0) {
        c.lua_pushnil(L);
        return 1;
    }
    pushEntity(L, @intFromFloat(c.lua_tonumber(L, 1)));
    return 1;
}

fn handleOf(L: ?*c.lua_State, i: c_int) ?f64 {
    switch (c.lua_type(L, i)) {
        c.LUA_TNUMBER => return c.lua_tonumber(L, i),
        c.LUA_TTABLE => {
            c.lua_pushstring(L, "__ent");
            c.lua_rawget(L, i);
            defer c.lua_pop(L, 1);
            if (c.lua_isnumber(L, -1) != 0) return c.lua_tonumber(L, -1);
            c.lua_pushstring(L, "value");
            c.lua_rawget(L, i);
            defer c.lua_pop(L, 1);
            if (c.lua_isnumber(L, -1) != 0) return c.lua_tonumber(L, -1);
            return null;
        },
        else => return null,
    }
}

fn apiCompsEqual(L: ?*c.lua_State) callconv(.c) c_int {
    const a = handleOf(L, 1);
    const b = handleOf(L, 2);
    c.lua_pushboolean(L, @intFromBool(a != null and b != null and a.? == b.?));
    return 1;
}

fn entityIndex(L: ?*c.lua_State) callconv(.c) c_int {
    if (c.lua_type(L, 2) != c.LUA_TSTRING) {
        c.lua_pushnil(L);
        return 1;
    }
    c.lua_pushstring(L, "__ent");
    c.lua_rawget(L, 1);
    c.lua_pushvalue(L, 2);
    c.lua_pushcclosure(L, entityCall, 2);
    return 1;
}

fn entityCall(L: ?*c.lua_State) callconv(.c) c_int {
    const id: u32 = @intFromFloat(c.lua_tonumber(L, upvalue_base - 1));
    const method = std.mem.span(c.lua_tostring(L, upvalue_base - 2));
    const m = active orelse return 0;
    const h = m.host;
    const eq = std.mem.eql;
    if (eq(u8, method, "BFG_GET_ATTR_FLOAT")) {
        c.lua_pushnumber(L, h.attr(h.ctx, id, l.str(L, 2) orelse "") orelse 0);
        return 1;
    } else if (eq(u8, method, "BFG_SET_ATTR_FLOAT")) {
        if (c.lua_isnumber(L, 3) != 0) h.set_attr(h.ctx, id, l.str(L, 2) orelse "", c.lua_tonumber(L, 3));
        return 0;
    } else if (eq(u8, method, "BFG_GET_ATTR_BOOLEAN")) {
        c.lua_pushboolean(L, @intFromBool(h.attr_bool(h.ctx, id, l.str(L, 2) orelse "")));
        return 1;
    } else if (eq(u8, method, "BFG_GET_ATTR_STRING")) {
        if (h.attr_str(h.ctx, id, l.str(L, 2) orelse "")) |v| l.pushStr(L, v) else c.lua_pushnil(L);
        return 1;
    } else if (eq(u8, method, "isKindOf")) {
        c.lua_pushboolean(L, @intFromBool(h.kind_of(h.ctx, id, l.str(L, 2) orelse "")));
        return 1;
    } else if (eq(u8, method, "BFAI_GET_PRESSING_THRESHOLD")) {
        c.lua_pushnumber(L, 60);
        return 1;
    } else if (eq(u8, method, "BFAI_GET_CRITICAL_THRESHOLD")) {
        c.lua_pushnumber(L, 90);
        return 1;
    } else if (eq(u8, method, "BFAI_GET_TRIGGERED")) {
        const v = h.attr(h.ctx, id, l.str(L, 2) orelse "") orelse 0;
        c.lua_pushboolean(L, @intFromBool(v >= 60));
        return 1;
    } else if (eq(u8, method, "BFG_GET_BINDER_TYPE")) {
        l.pushStr(L, h.binder(h.ctx, id));
        return 1;
    } else if (eq(u8, method, "BFG_GET_ENTITY_ID")) {
        c.lua_pushnumber(L, @floatFromInt(id));
        return 1;
    }
    var nb: [160]u8 = undefined;
    if (script.currentEngine()) |e| e.noteMissing(std.fmt.bufPrint(&nb, "entity:{s}", .{method}) catch method);
    return 0;
}

fn apiLog(L: ?*c.lua_State) callconv(.c) c_int {
    const m = active orelse return 0;
    if (!m.log) return 0;
    if (l.str(L, 2)) |s| std.debug.print("lua: {s}\n", .{s}) else if (l.str(L, 1)) |s| std.debug.print("lua: {s}\n", .{s});
    return 0;
}

fn apiSetVar(L: ?*c.lua_State) callconv(.c) c_int {
    const m = active orelse return 0;
    const k = l.str(L, 1) orelse return 0;
    m.setVar(k, l.str(L, 2) orelse "");
    return 0;
}

fn apiGetVar(L: ?*c.lua_State) callconv(.c) c_int {
    const m = active orelse return 0;
    const k = l.str(L, 1) orelse {
        c.lua_pushnil(L);
        return 1;
    };
    if (m.getVar(k)) |v| l.pushStr(L, v) else c.lua_pushnil(L);
    return 1;
}

fn apiLocId(L: ?*c.lua_State) callconv(.c) c_int {
    const m = active orelse return 0;
    const id = l.str(L, 1) orelse "";
    l.pushStr(L, m.loc.get(id) orelse id);
    return 1;
}

/// Game objects scripts can look up by name. Only the scenario manager is
/// real so far; everything else reads as absent.
fn apiQueryObject(L: ?*c.lua_State) callconv(.c) c_int {
    const name = l.str(L, 1) orelse "";
    if (std.mem.eql(u8, name, "BFScenarioMgr")) {
        c.lua_newtable(L);
        inline for (.{
            .{ "BFS_ADDSCENARIO", mgrAdd },
            .{ "BFS_SHOWRULE", mgrShowRule },
            .{ "BFS_HIDERULE", mgrHideRule },
            .{ "BFS_LOCALIZEFLOAT", mgrLocalizeFloat },
            .{ "BFS_SETRULESTATE", mgrSetRuleState },
            .{ "BFS_GETRULESTATE", mgrGetRuleState },
            .{ "BFS_SETALTTEXT", mgrSetAltText },
            .{ "BFS_SETALTOVERVIEWTEXT", mgrSetAltOverview },
            .{ "BFS_SETGLOBALVAR", apiSetVar2 },
            .{ "BFS_GETGLOBALVAR", apiGetVar2 },
            .{ "BFS_SETUSERVAL", apiSetVar2 },
            .{ "BFS_GETUSERVAL", apiGetVar2 },
            .{ "BFS_GETLOCID", mgrLocId },
            .{ "UI_DISABLE", mgrUi("UI_DISABLE") },
            .{ "UI_ENABLE", mgrUi("UI_ENABLE") },
            .{ "UI_HIDE", mgrUi("UI_HIDE") },
            .{ "UI_SHOW", mgrUi("UI_SHOW") },
            .{ "UI_ACTIVATE_ON", mgrUi("UI_ACTIVATE_ON") },
            .{ "UI_ACTIVATE_OFF", mgrUi("UI_ACTIVATE_OFF") },
            .{ "UI_REPRESS", mgrUi("UI_REPRESS") },
        }) |m| {
            c.lua_pushstring(L, m[0]);
            c.lua_pushcclosure(L, m[1], 0);
            c.lua_settable(L, -3);
        }
        return 1;
    }
    const known = [_][]const u8{ "BFGManager", "UIRoot", "ZTStatus", "ZTEconomyMgr", "ZTPhotoChallengesComponent", "ZTAIMgr", "ZTMode", "ZTPuzzleMgr", "ZTWorldMgr", "ZTResearchMgr" };
    for (known) |k| if (std.mem.eql(u8, k, name)) {
        pushComponent(L, if (std.mem.eql(u8, k, "UIRoot")) "ui:" else name);
        return 1;
    };
    if (script.currentEngine()) |e| {
        var nb: [120]u8 = undefined;
        e.noteMissing(std.fmt.bufPrint(&nb, "queryObject:{s}", .{name}) catch name);
    }
    c.lua_pushnil(L);
    return 1;
}

fn pushRect(L: ?*c.lua_State, x: f32, y: f32, w: f32, h: f32) void {
    c.lua_newtable(L);
    inline for (.{ .{ "x", x }, .{ "y", y }, .{ "w", w }, .{ "h", h } }) |kv| {
        c.lua_pushstring(L, kv[0]);
        c.lua_pushnumber(L, kv[1]);
        c.lua_settable(L, -3);
    }
}

/// A game component as scripts see it: a table whose methods are looked up
/// on demand and routed to `componentCall`.
fn pushComponent(L: ?*c.lua_State, name: []const u8) void {
    c.lua_newtable(L);
    c.lua_pushstring(L, "__comp");
    l.pushStr(L, name);
    c.lua_settable(L, -3);
    c.lua_newtable(L);
    c.lua_pushstring(L, "__index");
    c.lua_pushcclosure(L, componentIndex, 0);
    c.lua_settable(L, -3);
    _ = c.lua_setmetatable(L, -2);
}

/// `comp.METHOD` -> a closure remembering the component and method names.
fn componentIndex(L: ?*c.lua_State) callconv(.c) c_int {
    if (c.lua_type(L, 2) != c.LUA_TSTRING) {
        c.lua_pushnil(L);
        return 1;
    }
    c.lua_pushstring(L, "__comp");
    c.lua_rawget(L, 1);
    c.lua_pushvalue(L, 2);
    c.lua_pushcclosure(L, componentCall, 2);
    return 1;
}

const upvalue_base: c_int = -10001;

fn componentCall(L: ?*c.lua_State) callconv(.c) c_int {
    const comp = std.mem.span(c.lua_tostring(L, upvalue_base - 1));
    const method = std.mem.span(c.lua_tostring(L, upvalue_base - 2));
    const m = active orelse return 0;
    if (std.mem.startsWith(u8, comp, "ui:")) return m.uiCall(L, comp[3..], method);
    if (m.handleCall(L, comp, method)) |n| return n;
    var nb: [400]u8 = undefined;
    if (script.currentEngine()) |e| {
        var w: std.Io.Writer = .fixed(&nb);
        w.print("{s}:{s}(", .{ comp, method }) catch {};
        const top = c.lua_gettop(L);
        var i: c_int = 2;
        while (i <= top) : (i += 1) {
            switch (c.lua_type(L, i)) {
                c.LUA_TSTRING => w.print("\"{s}\",", .{std.mem.span(c.lua_tostring(L, i))}) catch {},
                c.LUA_TNUMBER => w.print("{d},", .{c.lua_tonumber(L, i)}) catch {},
                c.LUA_TTABLE => w.writeAll("table,") catch {},
                c.LUA_TNIL => w.writeAll("nil,") catch {},
                else => w.writeAll("?,") catch {},
            }
        }
        w.writeAll(")") catch {};
        if (e.log) e.noteMissing(w.buffered()) else e.noteMissing(w.buffered());
    }
    return 0;
}

// Methods are called with the object first (`mgr:BFS_X(a)`), so arguments start at 2.

fn mgrAdd(L: ?*c.lua_State) callconv(.c) c_int {
    const m = active orelse return 0;
    const path = l.str(L, 2) orelse return 0;
    m.add(path) catch |e| {
        if (m.log) std.debug.print("scenario: cannot add {s}: {s}\n", .{ path, @errorName(e) });
    };
    return 0;
}

fn mgrShowRule(L: ?*c.lua_State) callconv(.c) c_int {
    const m = active orelse return 0;
    if (m.find(l.str(L, 2) orelse return 0)) |n| n.hidden = false;
    return 0;
}

fn mgrHideRule(L: ?*c.lua_State) callconv(.c) c_int {
    const m = active orelse return 0;
    if (m.find(l.str(L, 2) orelse return 0)) |n| n.hidden = true;
    return 0;
}

/// The scenario manager also takes UI calls naming a node (`mgr:UI_DISABLE("undo")`).
fn mgrUi(comptime method: []const u8) c.lua_CFunction {
    return struct {
        fn f(L: ?*c.lua_State) callconv(.c) c_int {
            const m = active orelse return 0;
            const name = l.str(L, 2) orelse return 0;
            const st = m.host.ui orelse return 0;
            const e = st.at(name);
            if (std.mem.eql(u8, method, "UI_DISABLE")) e.enabled = false else if (std.mem.eql(u8, method, "UI_ENABLE")) e.enabled = true else if (std.mem.eql(u8, method, "UI_HIDE")) e.visible = false else if (std.mem.eql(u8, method, "UI_SHOW")) e.visible = true else if (std.mem.eql(u8, method, "UI_ACTIVATE_ON")) e.activated = true else e.activated = false;
            return 0;
        }
    }.f;
}

fn mgrSetRuleState(L: ?*c.lua_State) callconv(.c) c_int {
    const m = active orelse return 0;
    const n = m.find(l.str(L, 2) orelse return 0) orelse return 0;
    const v = if (c.lua_isnumber(L, 3) != 0) c.lua_tonumber(L, 3) else 0;
    n.state = if (v >= 0.5 and v < 1.5) .success else if (v >= 1.5 or v <= -0.5) .failed else .pending;
    return 0;
}

fn mgrGetRuleState(L: ?*c.lua_State) callconv(.c) c_int {
    const m = active orelse return 0;
    const n = m.find(l.str(L, 2) orelse "") orelse {
        c.lua_pushnumber(L, 0);
        return 1;
    };
    c.lua_pushnumber(L, switch (n.state) {
        .pending => 0,
        .success => 1,
        .failed => 2,
    });
    return 1;
}

/// `BFS_SETALTTEXT(rule, "neutral"|"success"|"failure", text)`.
fn mgrSetAltText(L: ?*c.lua_State) callconv(.c) c_int {
    return setAlt(L, false);
}

fn mgrSetAltOverview(L: ?*c.lua_State) callconv(.c) c_int {
    return setAlt(L, true);
}

fn setAlt(L: ?*c.lua_State, overview: bool) c_int {
    const m = active orelse return 0;
    const n = m.find(l.str(L, 2) orelse return 0) orelse return 0;
    const which = l.str(L, 3) orelse return 0;
    const text = m.arena.allocator().dupe(u8, l.str(L, 4) orelse return 0) catch return 0;
    if (std.mem.eql(u8, which, "neutral")) {
        if (overview) n.alt_neutral_overview = text else n.alt_neutral = text;
    } else if (std.mem.eql(u8, which, "success")) {
        if (overview) n.alt_success_overview = text else n.alt_success = text;
    } else if (std.mem.eql(u8, which, "failure")) n.alt_failure = text;
    return 0;
}

fn apiSetVar2(L: ?*c.lua_State) callconv(.c) c_int {
    const m = active orelse return 0;
    const k = l.str(L, 2) orelse return 0;
    m.setVar(k, l.str(L, 3) orelse "");
    return 0;
}

fn apiGetVar2(L: ?*c.lua_State) callconv(.c) c_int {
    const m = active orelse return 0;
    const k = l.str(L, 2) orelse {
        c.lua_pushnil(L);
        return 1;
    };
    if (m.getVar(k)) |v| l.pushStr(L, v) else c.lua_pushnil(L);
    return 1;
}

fn mgrLocId(L: ?*c.lua_State) callconv(.c) c_int {
    const m = active orelse return 0;
    const id = l.str(L, 2) orelse "";
    l.pushStr(L, m.loc.get(id) orelse id);
    return 1;
}

/// 1234567 -> "$1,234,567".
fn mgrLocalizeFloat(L: ?*c.lua_State) callconv(.c) c_int {
    const v: f64 = if (c.lua_isnumber(L, 2) != 0) c.lua_tonumber(L, 2) else 0;
    var digits: [32]u8 = undefined;
    const raw = std.fmt.bufPrint(&digits, "{d:.0}", .{@abs(v)}) catch "0";
    var out: [48]u8 = undefined;
    var n: usize = 0;
    if (v < 0) {
        out[n] = '-';
        n += 1;
    }
    out[n] = '$';
    n += 1;
    for (raw, 0..) |ch, i| {
        if (i > 0 and (raw.len - i) % 3 == 0) {
            out[n] = ',';
            n += 1;
        }
        out[n] = ch;
        n += 1;
    }
    l.pushStr(L, out[0..n]);
    return 1;
}
