//! Entity definitions. The game describes animals, guests, buildings and
//! scenery as `BFTypedBinder` XML files under `entities/`. Each binder has a
//! name (`binderType`), a position in a type hierarchy (the nested element
//! chain inside `<types>`), and `shared` / `instance` / `binder` sections of
//! component elements whose attributes carry the data.
//!
//! Observed model, implemented here and checked against the data: a binder
//! inherits the component attributes of binders whose names appear earlier on
//! its type path (e.g. `TigerBengal` data applies to `TigerBengal_Adult_F`),
//! with the more specific binder winning.

const std = @import("std");
const xml = @import("xml.zig");
const Vfs = @import("vfs.zig").Vfs;

pub const Section = enum { shared, instance, binder };

pub const Binder = struct {
    /// `binderType` attribute, original case.
    name: []const u8,
    abstract: bool,
    /// Type hierarchy from root (`entity`) to this binder's own type name.
    type_path: []const []const u8,
    root: *const xml.Element,
    /// Normalized VFS path of the defining file.
    source: []const u8,

    pub fn section(self: *const Binder, which: Section) ?*const xml.Element {
        return self.root.child(@tagName(which));
    }
};

pub const Registry = struct {
    arena: std.heap.ArenaAllocator,
    /// Lowercased binder name -> binder. A later definition replaces an earlier one.
    binders: std.StringHashMapUnmanaged(*Binder) = .empty,
    gpa: std.mem.Allocator,
    /// Number of definitions that replaced an earlier one with the same name.
    overridden: usize = 0,
    /// Files under entities/ that were not binders or failed to parse.
    skipped: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Registry {
        return .{ .arena = .init(gpa), .gpa = gpa };
    }

    pub fn deinit(self: *Registry) void {
        self.binders.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Loads every `entities/**/*.xml` visible in `vfs`.
    pub fn load(self: *Registry, vfs: *Vfs) !void {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.gpa);
        const Collect = struct {
            list: *std.ArrayList([]const u8),
            gpa: std.mem.Allocator,
            fn add(c: @This(), name: []const u8) anyerror!void {
                if (std.mem.startsWith(u8, name, "entities/") and std.mem.endsWith(u8, name, ".xml"))
                    try c.list.append(c.gpa, name);
            }
        };
        try vfs.forEach(Collect{ .list = &names, .gpa = self.gpa }, Collect.add);
        // Deterministic order so overrides don't depend on hash iteration.
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);

        for (names.items) |path| {
            const data = try vfs.read(self.gpa, path);
            defer self.gpa.free(data);
            try self.add(path, data);
        }
    }

    /// Parses one file; non-binder or malformed files are counted as skipped.
    pub fn add(self: *Registry, path: []const u8, data: []const u8) !void {
        const a = self.arena.allocator();
        const root = xml.parse(a, data, null) catch {
            self.skipped += 1;
            return;
        };
        if (!std.ascii.eqlIgnoreCase(root.name, "BFTypedBinder")) {
            self.skipped += 1;
            return;
        }
        const name = root.attr("binderType") orelse {
            self.skipped += 1;
            return;
        };

        var path_list: std.ArrayList([]const u8) = .empty;
        if (root.child("types")) |types| {
            var cur: *const xml.Element = types;
            while (cur.children.len > 0) {
                cur = cur.children[0];
                try path_list.append(a, cur.name);
            }
        }

        const b = try a.create(Binder);
        b.* = .{
            .name = name,
            .abstract = if (root.attr("abstract")) |v| std.ascii.eqlIgnoreCase(v, "true") else false,
            .type_path = try path_list.toOwnedSlice(a),
            .root = root,
            .source = try a.dupe(u8, path),
        };
        const key = try a.dupe(u8, name);
        _ = std.ascii.lowerString(key, key);
        const gop = try self.binders.getOrPut(self.gpa, key);
        if (gop.found_existing) self.overridden += 1;
        gop.value_ptr.* = b;
    }

    pub fn get(self: *const Registry, name: []const u8) ?*const Binder {
        var buf: [256]u8 = undefined;
        if (name.len > buf.len) return null;
        const key = std.ascii.lowerString(&buf, name);
        return self.binders.get(key);
    }

    /// The binders `b` inherits from, most general first, ending with `b`
    /// itself. Binders are matched by the names on `b`'s type path.
    pub fn chain(self: *const Registry, gpa: std.mem.Allocator, b: *const Binder) ![]const *const Binder {
        var out: std.ArrayList(*const Binder) = .empty;
        errdefer out.deinit(gpa);
        for (b.type_path) |t| {
            const anc = self.get(t) orelse continue;
            if (anc == b) continue;
            // Avoid listing the same binder twice if names repeat on the path.
            if (std.mem.indexOfScalar(*const Binder, out.items, anc) != null) continue;
            try out.append(gpa, anc);
        }
        try out.append(gpa, b);
        return out.toOwnedSlice(gpa);
    }

    /// Looks up `attr` on component `component` within `section`, preferring
    /// the most specific binder in `chain_` (as returned by `chain`).
    pub fn attr(
        chain_: []const *const Binder,
        which: Section,
        component: []const u8,
        attr_name: []const u8,
    ) ?[]const u8 {
        var i = chain_.len;
        while (i > 0) {
            i -= 1;
            const sec = chain_[i].section(which) orelse continue;
            for (sec.children) |c| {
                if (!std.ascii.eqlIgnoreCase(c.name, component)) continue;
                if (c.attr(attr_name)) |v| return v;
            }
        }
        return null;
    }
};

test "type path and inheritance chain" {
    const gpa = std.testing.allocator;
    var reg = Registry.init(gpa);
    defer reg.deinit();
    try reg.add("entities/a.xml",
        \\<BFTypedBinder binderType="Tiger" abstract="true"><types><entity><animal><Tiger/></animal></entity></types>
        \\<shared><Data s_Species="Tiger" b_Male="1"/></shared></BFTypedBinder>
    );
    try reg.add("entities/b.xml",
        \\<BFTypedBinder binderType="Tiger_F"><types><entity><animal><Tiger><Tiger_F/></Tiger></animal></entity></types>
        \\<shared><Data b_Male="0"/></shared></BFTypedBinder>
    );
    try reg.add("entities/c.xml", "<NotABinder/>");
    try std.testing.expectEqual(@as(usize, 1), reg.skipped);

    const f = reg.get("TIGER_f").?;
    try std.testing.expectEqual(@as(usize, 4), f.type_path.len);
    const ch = try reg.chain(gpa, f);
    defer gpa.free(ch);
    try std.testing.expectEqual(@as(usize, 2), ch.len);
    try std.testing.expectEqualStrings("Tiger", Registry.attr(ch, .shared, "Data", "s_Species").?);
    try std.testing.expectEqualStrings("0", Registry.attr(ch, .shared, "Data", "b_Male").?);
    try std.testing.expect(Registry.attr(ch, .shared, "Data", "nope") == null);
}
