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
        }) |m| {
            c.lua_pushstring(L, m[0]);
            c.lua_pushcclosure(L, m[1], 0);
            c.lua_settable(L, -3);
        }
        return 1;
    }
    if (script.currentEngine()) |e| {
        var nb: [120]u8 = undefined;
        e.noteMissing(std.fmt.bufPrint(&nb, "queryObject:{s}", .{name}) catch name);
    }
    c.lua_pushnil(L);
    return 1;
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
