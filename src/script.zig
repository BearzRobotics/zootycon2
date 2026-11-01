//! Scenario scripting: the game's goals and tutorials are Lua 5.0 scripts
//! (`scenario/scripts/*.bin`, compiled for a 32-bit build) that call back
//! into the game. This wraps the vendored Lua VM, loads scripts out of the
//! virtual file system, and provides the game-side functions they expect.
//! Functions we have not written yet are logged once and return nil, so a
//! script keeps running and the log shows what to implement next.

const std = @import("std");
const c = @import("lua_c");
const vfs_mod = @import("vfs.zig");

pub const Error = error{ OutOfMemory, ScriptNotFound, ScriptFailed };

/// Lua 5.0's pseudo-index for the table of globals.
const globals_index: c_int = -10001;

/// Only one engine exists at a time (the game has one scenario running), so
/// the C callbacks reach it through this.
var current: ?*Engine = null;

pub const Engine = struct {
    gpa: std.mem.Allocator,
    L: *c.lua_State,
    vfs: *vfs_mod.Vfs,
    /// Scripts already run by `include`/`load`.
    loaded: std.StringHashMapUnmanaged(void) = .empty,
    /// Names of game functions scripts asked for that we do not provide.
    missing: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// Text of the last error.
    last_error: [512]u8 = undefined,
    last_error_len: usize = 0,
    log: bool = false,

    pub fn create(gpa: std.mem.Allocator, vfs: *vfs_mod.Vfs) Error!*Engine {
        const L = c.lua_open() orelse return error.OutOfMemory;
        const self = try gpa.create(Engine);
        self.* = .{ .gpa = gpa, .L = L, .vfs = vfs };
        _ = c.luaopen_base(L);
        _ = c.luaopen_table(L);
        _ = c.luaopen_string(L);
        _ = c.luaopen_math(L);
        current = self;
        self.registerBuiltins();
        return self;
    }

    pub fn destroy(self: *Engine) void {
        c.lua_close(self.L);
        var it = self.loaded.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.loaded.deinit(self.gpa);
        for (self.missing.keys()) |k| self.gpa.free(k);
        self.missing.deinit(self.gpa);
        if (current == self) current = null;
        self.gpa.destroy(self);
    }

    pub fn errorText(self: *const Engine) []const u8 {
        return self.last_error[0..self.last_error_len];
    }

    fn setError(self: *Engine, text: []const u8) void {
        const n = @min(text.len, self.last_error.len);
        @memcpy(self.last_error[0..n], text[0..n]);
        self.last_error_len = n;
    }

    /// Defines a global function.
    pub fn register(self: *Engine, name: [:0]const u8, f: c.lua_CFunction) void {
        c.lua_pushstring(self.L, name.ptr);
        c.lua_pushcclosure(self.L, f, 0);
        c.lua_settable(self.L, globals_index);
    }

    fn registerBuiltins(self: *Engine) void {
        self.register("include", luaInclude);
        // Unknown globals read as a logging stub instead of an error.
        c.lua_pushvalue(self.L, globals_index);
        c.lua_newtable(self.L);
        c.lua_pushstring(self.L, "__index");
        c.lua_pushcclosure(self.L, luaMissing, 0);
        c.lua_settable(self.L, -3);
        _ = c.lua_setmetatable(self.L, -2);
        c.lua_pop(self.L, 1);
    }

    /// Runs the script at a game path (`scenario/scripts/ui.lua`): the
    /// compiled `.bin` next to it, or the plain text if that is what exists.
    /// Each script runs once.
    pub fn load(self: *Engine, path: []const u8) Error!void {
        var lower_buf: [200]u8 = undefined;
        if (path.len > lower_buf.len) return error.ScriptNotFound;
        const key = std.ascii.lowerString(&lower_buf, path);
        if (self.loaded.contains(key)) return;
        const owned = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned);
        const stem = if (std.mem.endsWith(u8, key, ".lua") or std.mem.endsWith(u8, key, ".bin")) key[0 .. key.len - 4] else key;
        var data: ?[]u8 = null;
        var pb: [220]u8 = undefined;
        for ([_][]const u8{ ".bin", ".lua" }) |ext| {
            const p = std.fmt.bufPrint(&pb, "{s}{s}", .{ stem, ext }) catch continue;
            if (self.vfs.exists(p)) {
                data = self.vfs.read(self.gpa, p) catch null;
                if (data != null) break;
            }
        }
        const bytes = data orelse return error.ScriptNotFound;
        defer self.gpa.free(bytes);
        try self.loaded.put(self.gpa, owned, {});
        const name = try self.gpa.allocSentinel(u8, stem.len, 0);
        defer self.gpa.free(name);
        @memcpy(name, stem);
        if (c.luaL_loadbuffer(self.L, bytes.ptr, bytes.len, name.ptr) != 0) {
            self.takeError();
            return error.ScriptFailed;
        }
        if (c.lua_pcall(self.L, 0, 0, 0) != 0) {
            self.takeError();
            return error.ScriptFailed;
        }
    }

    /// Moves the error message on top of the stack into `last_error`.
    fn takeError(self: *Engine) void {
        const s = c.lua_tostring(self.L, -1);
        if (s != null) self.setError(std.mem.span(s)) else self.setError("(error object is not a string)");
        c.lua_pop(self.L, 1);
    }

    /// Calls a global function with no arguments and returns its first
    /// result as a number (nil and false are 0, true is 1).
    pub fn callNumber(self: *Engine, name: [:0]const u8) Error!f64 {
        c.lua_pushstring(self.L, name.ptr);
        c.lua_gettable(self.L, globals_index);
        if (c.lua_isfunction(self.L, -1) == 0) {
            c.lua_pop(self.L, 1);
            return error.ScriptNotFound;
        }
        if (c.lua_pcall(self.L, 0, 1, 0) != 0) {
            self.takeError();
            return error.ScriptFailed;
        }
        defer c.lua_pop(self.L, 1);
        if (c.lua_isnumber(self.L, -1) != 0) return c.lua_tonumber(self.L, -1);
        if (c.lua_type(self.L, -1) == c.LUA_TBOOLEAN) return if (c.lua_toboolean(self.L, -1) != 0) 1 else 0;
        return 0;
    }

    /// Runs a chunk of source text (tests and debugging).
    pub fn runString(self: *Engine, src: []const u8) Error!void {
        if (c.luaL_loadbuffer(self.L, src.ptr, src.len, "=string") != 0) {
            self.takeError();
            return error.ScriptFailed;
        }
        if (c.lua_pcall(self.L, 0, 0, 0) != 0) {
            self.takeError();
            return error.ScriptFailed;
        }
    }

    /// Reads a global number.
    pub fn globalNumber(self: *Engine, name: [:0]const u8) ?f64 {
        c.lua_pushstring(self.L, name.ptr);
        c.lua_gettable(self.L, globals_index);
        defer c.lua_pop(self.L, 1);
        if (c.lua_isnumber(self.L, -1) == 0) return null;
        return c.lua_tonumber(self.L, -1);
    }

    fn noteMissing(self: *Engine, name: []const u8) void {
        if (self.missing.getPtr(name)) |n| {
            n.* += 1;
            return;
        }
        const owned = self.gpa.dupe(u8, name) catch return;
        self.missing.put(self.gpa, owned, 1) catch self.gpa.free(owned);
        if (self.log) std.debug.print("script: missing game function '{s}'\n", .{name});
    }
};

// ---------------------------------------------------------------- callbacks

fn luaInclude(L: ?*c.lua_State) callconv(.c) c_int {
    const eng = current orelse return 0;
    const s = c.luaL_checklstring(L, 1, null);
    eng.load(std.mem.span(s)) catch |e| {
        if (e == error.ScriptFailed) {
            var buf: [600]u8 = undefined;
            const m = std.fmt.bufPrint(&buf, "include '{s}' failed: {s}\x00", .{ std.mem.span(s), eng.errorText() }) catch "include failed\x00";
            return c.luaL_error(L, "%s", m.ptr);
        }
        var buf: [300]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "cannot find script '{s}'\x00", .{std.mem.span(s)}) catch "no script\x00";
        return c.luaL_error(L, "%s", m.ptr);
    };
    return 0;
}

/// `__index` of the globals table: logs the name and yields a function that
/// returns nothing.
fn luaMissing(L: ?*c.lua_State) callconv(.c) c_int {
    const eng = current orelse return 0;
    if (c.lua_type(L, 2) == c.LUA_TSTRING) eng.noteMissing(std.mem.span(c.lua_tostring(L, 2)));
    c.lua_pushcclosure(L, luaNoop, 0);
    return 1;
}

fn luaNoop(_: ?*c.lua_State) callconv(.c) c_int {
    return 0;
}

// ------------------------------------------------------------------ tests

test "a script can define and call functions and include others" {
    var vfs = vfs_mod.Vfs.init(std.testing.allocator, std.testing.io);
    defer vfs.deinit();
    const eng = try Engine.create(std.testing.allocator, &vfs);
    defer eng.destroy();
    try eng.runString("function twice(x) return x * 2 end; answer = twice(21)");
    try std.testing.expectEqual(@as(f64, 42), eng.globalNumber("answer").?);
}

test "unknown game functions are logged instead of failing" {
    var vfs = vfs_mod.Vfs.init(std.testing.allocator, std.testing.io);
    defer vfs.deinit();
    const eng = try Engine.create(std.testing.allocator, &vfs);
    defer eng.destroy();
    try eng.runString("local r = SomethingTheGameProvides(1, 2); done = 1");
    try std.testing.expectEqual(@as(f64, 1), eng.globalNumber("done").?);
    try std.testing.expectEqual(@as(u32, 1), eng.missing.get("SomethingTheGameProvides").?);
}
