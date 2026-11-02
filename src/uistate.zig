//! Run-time state of the game's UI nodes, by name. Scenario scripts drive the
//! interface through this (`UIRoot:UI_GET_CHILD("goal panel"):UI_SHOW()`), and
//! the application both draws from it and writes what the player does back
//! into it, so scripts can see that a button was pressed or a panel opened.

const std = @import("std");

pub const Entry = struct {
    /// null = whatever the layout file says.
    visible: ?bool = null,
    enabled: bool = true,
    /// A pressed toggle, or an "alternate" button state.
    activated: bool = false,
    text: []const u8 = "",
    pos: ?[2]f32 = null,
    size: ?[2]f32 = null,
    /// Counts presses, so a script can notice a click that already ended.
    presses: u32 = 0,
    /// A stand-in for a layout loaded by a script: every child lookup succeeds.
    loaded: bool = false,
};

pub const State = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(Entry) = .empty,

    pub fn init(gpa: std.mem.Allocator) State {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *State) void {
        self.arena.deinit();
    }

    fn key(buf: []u8, name: []const u8) []const u8 {
        const n = @min(name.len, buf.len);
        return std.ascii.lowerString(buf[0..n], name[0..n]);
    }

    pub fn get(self: *const State, name: []const u8) ?*const Entry {
        var kb: [96]u8 = undefined;
        return self.map.getPtr(key(&kb, name));
    }

    /// The entry for a node, created on first use.
    pub fn at(self: *State, name: []const u8) *Entry {
        var kb: [96]u8 = undefined;
        const k = key(&kb, name);
        if (self.map.getPtr(k)) |e| return e;
        const a = self.arena.allocator();
        const owned = a.dupe(u8, k) catch return &scratch;
        self.map.put(a, owned, .{}) catch return &scratch;
        return self.map.getPtr(owned).?;
    }

    var scratch: Entry = .{};

    pub fn setText(self: *State, name: []const u8, text: []const u8) void {
        const e = self.at(name);
        e.text = self.arena.allocator().dupe(u8, text) catch "";
    }
};

test "entries are created on demand and found ignoring case" {
    var s = State.init(std.testing.allocator);
    defer s.deinit();
    try std.testing.expect(s.get("Goal Panel") == null);
    s.at("Goal Panel").visible = true;
    try std.testing.expect(s.get("goal panel").?.visible.?);
    s.setText("tutorial text", "Hello");
    try std.testing.expectEqualStrings("Hello", s.get("Tutorial Text").?.text);
}
