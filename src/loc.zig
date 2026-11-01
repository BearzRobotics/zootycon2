//! Localized text. The game's strings live in `lang/1033/*.xml` as
//! `<ZT2Strings><Section><Key>text</Key></Section></ZT2Strings>` and are
//! referenced as `Section:Key` (`AfricaCampaign:MeerkatsIntro`). Later files
//! (expansion edits) replace earlier ones.

const std = @import("std");
const xml = @import("xml.zig");
const vfs_mod = @import("vfs.zig");

pub const Loc = struct {
    arena: std.heap.ArenaAllocator,
    /// Lowercased `section:key` -> text.
    map: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Loc {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Loc) void {
        self.arena.deinit();
    }

    /// Reads every string file of the language folder (`lang/1033`).
    pub fn load(self: *Loc, vfs: *vfs_mod.Vfs, folder: []const u8) !void {
        const gpa = self.arena.child_allocator;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        const Collect = struct {
            list: *std.ArrayList([]const u8),
            gpa: std.mem.Allocator,
            folder: []const u8,
            fn add(c: @This(), name: []const u8) anyerror!void {
                if (std.mem.startsWith(u8, name, c.folder) and std.mem.endsWith(u8, name, ".xml")) try c.list.append(c.gpa, name);
            }
        };
        try vfs.forEach(Collect{ .list = &names, .gpa = gpa, .folder = folder }, Collect.add);
        // Plain files first, then the expansion edits that override them.
        std.mem.sort([]const u8, names.items, {}, lessThan);
        for (names.items) |n| {
            const data = vfs.read(gpa, n) catch continue;
            defer gpa.free(data);
            self.addXml(data) catch {};
        }
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        const ae = std.mem.indexOf(u8, a, "edits") != null;
        const be = std.mem.indexOf(u8, b, "edits") != null;
        if (ae != be) return be;
        return std.mem.lessThan(u8, a, b);
    }

    pub fn addXml(self: *Loc, data: []const u8) !void {
        const a = self.arena.allocator();
        var scratch: std.heap.ArenaAllocator = .init(self.arena.child_allocator);
        defer scratch.deinit();
        const root = try xml.parse(scratch.allocator(), data, null);
        for (root.children) |section| {
            // `<LOC_STRING _locID="Section:Key">text</LOC_STRING>`
            if (section.attr("_locID")) |id| {
                try self.put(a, id, section.text);
                continue;
            }
            // `<Section><Key>text</Key></Section>`
            for (section.children) |entry| {
                var kb: [200]u8 = undefined;
                const key = std.fmt.bufPrint(&kb, "{s}:{s}", .{ section.name, entry.name }) catch continue;
                try self.put(a, key, entry.text);
            }
        }
    }

    fn put(self: *Loc, a: std.mem.Allocator, id: []const u8, text: []const u8) !void {
        const lowered = try a.alloc(u8, id.len);
        _ = std.ascii.lowerString(lowered, id);
        try self.map.put(a, lowered, try a.dupe(u8, text));
    }

    /// The text for an id such as `Section:Key`, if there is one.
    pub fn get(self: *const Loc, id: []const u8) ?[]const u8 {
        var kb: [200]u8 = undefined;
        if (id.len > kb.len) return null;
        return self.map.get(std.ascii.lowerString(&kb, id));
    }
};

test "strings are found by section and key, ignoring case" {
    var loc = Loc.init(std.testing.allocator);
    defer loc.deinit();
    try loc.addXml("<ZT2Strings><Intro><Hello>Welcome to the zoo</Hello></Intro></ZT2Strings>");
    try std.testing.expectEqualStrings("Welcome to the zoo", loc.get("intro:HELLO").?);
    try std.testing.expect(loc.get("Intro:Missing") == null);
    try loc.addXml("<ZT2Strings><LOC_STRING _locID=\"Camp:Intro\">A Mob</LOC_STRING></ZT2Strings>");
    try std.testing.expectEqualStrings("A Mob", loc.get("camp:intro").?);
    // a later definition replaces the earlier one
    try loc.addXml("<ZT2Strings><Intro><Hello>Hi</Hello></Intro></ZT2Strings>");
    try std.testing.expectEqualStrings("Hi", loc.get("Intro:Hello").?);
}
