//! The editable world: terrain plus everything placed on it. It is built
//! from a parsed map or save, changed by the build tools, and written back
//! out as a `.zt2` that `map.parse` reads again.
//!
//! Saves use the same XML schema as the game's own maps (a subset of it), so
//! one reader covers both. They are not loadable by the original game.

const std = @import("std");
const map_mod = @import("map.zig");
const terrain_mod = @import("terrain.zig");

pub const Swap = map_mod.Swap;

pub const Prop = struct {
    id: u32,
    /// The entity this prop is (`BrowseHolder_Hay`), empty for plain scenery.
    binder: []const u8 = "",
    /// For feeders: how much food is left, 0..100.
    food: f32 = 0,
    model: []const u8,
    scale: f32,
    position: [3]f32,
    /// Row-major 3x3.
    rotation: [9]f32,
    swaps: []const Swap = &.{},
};

pub const Fence = struct {
    id: u32,
    kind: []const u8,
    rotation: f32,
    position: [3]f32,
};

pub const PathTile = struct {
    id: u32,
    texture: []const u8,
    position: [2]f32,
    width: f32,
    height: f32,
};

pub const Head = struct {
    model: []const u8,
    yaw: f32 = 0,
    swaps: []const Swap = &.{},
};

pub const Actor = struct {
    id: u32,
    head: ?Head = null,
    binder: []const u8,
    position: [3]f32,
    rotation: [9]f32,
    swaps: []const Swap = &.{},
};

pub const identity_rotation = [9]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };

/// Rotation about z by `yaw` radians, row-major.
pub fn yawRotation(yaw: f32) [9]f32 {
    const c = @cos(yaw);
    const s = @sin(yaw);
    return .{ c, -s, 0, s, c, 0, 0, 0, 1 };
}

pub const World = struct {
    gpa: std.mem.Allocator,
    /// Owns every string in the world's records.
    strings: std.heap.ArenaAllocator,
    name: []const u8 = "",
    biome: []const u8 = "",
    environment: []const u8 = "",
    /// File name written into saves for the terrain (`<save name>.dat`).
    terrain_file: []const u8 = "",
    camera: ?[3]f32 = null,
    terrain: terrain_mod.Terrain,
    props: std.ArrayList(Prop) = .empty,
    fences: std.ArrayList(Fence) = .empty,
    paths: std.ArrayList(PathTile) = .empty,
    actors: std.ArrayList(Actor) = .empty,
    next_id: u32 = 1,
    /// Zoo statistics, kept here so they are saved and loaded with the world.
    income: f64 = 0,
    guests_total: u32 = 0,
    views: u32 = 0,
    /// Bumped on every edit so views know to rebuild.
    revision: u32 = 0,
    /// Bumped when actors are added or removed (separately from `revision`,
    /// so people arriving does not rebuild every static mesh).
    actors_revision: u32 = 0,
    terrain_revision: u32 = 0,

    /// Takes ownership of `terrain`.
    pub fn init(gpa: std.mem.Allocator, terrain: terrain_mod.Terrain) World {
        return .{ .gpa = gpa, .strings = .init(gpa), .terrain = terrain };
    }

    pub fn deinit(self: *World) void {
        self.props.deinit(self.gpa);
        self.fences.deinit(self.gpa);
        self.paths.deinit(self.gpa);
        self.actors.deinit(self.gpa);
        self.terrain.deinit();
        self.strings.deinit();
    }

    fn str(self: *World, s: []const u8) ![]const u8 {
        return self.strings.allocator().dupe(u8, s);
    }

    fn newId(self: *World) u32 {
        defer self.next_id += 1;
        return self.next_id;
    }

    fn swapsCopy(self: *World, swaps: []const Swap) ![]const Swap {
        if (swaps.len == 0) return &.{};
        const a = self.strings.allocator();
        const out = try a.alloc(Swap, swaps.len);
        for (swaps, out) |s, *o| o.* = .{ .image = try a.dupe(u8, s.image), .layer = try a.dupe(u8, s.layer) };
        return out;
    }

    /// Builds a world from a parsed map. Takes ownership of `terrain`.
    pub fn fromMap(gpa: std.mem.Allocator, m: *const map_mod.Map, terrain: terrain_mod.Terrain) !World {
        var w = World.init(gpa, terrain);
        errdefer w.deinit();
        w.name = try w.str(m.name);
        w.biome = try w.str(m.biome);
        w.environment = try w.str(m.environment);
        w.terrain_file = try w.str(m.terrain_file);
        w.camera = m.camera;
        w.income = m.income;
        w.guests_total = m.guests_total;
        w.views = m.views;
        for (m.objects) |o| {
            _ = try w.addPropEx(o.model, o.position, o.rotation, o.scale, o.swaps, o.binder, o.food);
        }
        for (m.fences) |f| _ = try w.addFence(f.kind, f.position, f.rotation);
        for (m.paths) |p| _ = try w.addPath(p.texture, p.position, p.width, p.height);
        for (m.actors) |a| {
            const id = try w.addActor(a.binder, a.position, a.rotation, a.swaps);
            if (a.head) |h| w.actors.items[w.actors.items.len - 1].head = .{
                .model = try w.str(h.model),
                .yaw = h.yaw,
                .swaps = try w.swapsCopy(h.swaps),
            };
            _ = id;
        }
        w.revision = 0;
        w.actors_revision = 0;
        return w;
    }

    pub fn addProp(self: *World, model: []const u8, pos: [3]f32, rot: [9]f32, scale: f32, swaps: []const Swap) !u32 {
        return self.addPropEx(model, pos, rot, scale, swaps, "", 0);
    }

    pub fn addPropEx(self: *World, model: []const u8, pos: [3]f32, rot: [9]f32, scale: f32, swaps: []const Swap, binder: []const u8, food: f32) !u32 {
        const id = self.newId();
        try self.props.append(self.gpa, .{
            .id = id,
            .binder = if (binder.len > 0) try self.str(binder) else "",
            .food = food,
            .model = try self.str(model),
            .scale = scale,
            .position = pos,
            .rotation = rot,
            .swaps = try self.swapsCopy(swaps),
        });
        self.revision += 1;
        return id;
    }

    pub fn addFence(self: *World, kind: []const u8, pos: [3]f32, rotation: f32) !u32 {
        const id = self.newId();
        try self.fences.append(self.gpa, .{ .id = id, .kind = try self.str(kind), .rotation = rotation, .position = pos });
        self.revision += 1;
        return id;
    }

    pub fn addPath(self: *World, texture: []const u8, pos: [2]f32, width: f32, height: f32) !u32 {
        const id = self.newId();
        try self.paths.append(self.gpa, .{ .id = id, .texture = try self.str(texture), .position = pos, .width = width, .height = height });
        self.revision += 1;
        return id;
    }

    pub fn addActor(self: *World, binder: []const u8, pos: [3]f32, rot: [9]f32, swaps: []const Swap) !u32 {
        const id = self.newId();
        try self.actors.append(self.gpa, .{
            .id = id,
            .binder = try self.str(binder),
            .position = pos,
            .rotation = rot,
            .swaps = try self.swapsCopy(swaps),
        });
        self.actors_revision += 1;
        return id;
    }

    /// Removes the record with this id from whichever list holds it.
    /// Returns false if no such record exists.
    pub fn remove(self: *World, id: u32) bool {
        inline for (.{ &self.props, &self.fences, &self.paths }) |list| {
            for (list.items, 0..) |item, i| if (item.id == id) {
                _ = list.orderedRemove(i);
                self.revision += 1;
                return true;
            };
        }
        for (self.actors.items, 0..) |a, i| if (a.id == id) {
            _ = self.actors.orderedRemove(i);
            self.actors_revision += 1;
            return true;
        };
        return false;
    }

    /// Marks terrain heights as edited.
    pub fn terrainEdited(self: *World) void {
        self.terrain_revision += 1;
    }

    // ---------------------------------------------------------------- save

    fn attr(w: *std.Io.Writer, name: []const u8, value: []const u8) !void {
        try w.print(" {s}=\"", .{name});
        for (value) |ch| switch (ch) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            else => try w.writeByte(ch),
        };
        try w.writeByte('"');
    }

    fn rotationXml(w: *std.Io.Writer, r: [9]f32) !void {
        try w.writeAll("<rotation>");
        const rows = [3][]const u8{ "row0", "row1", "row2" };
        for (rows, 0..) |name, i| {
            try w.print("<{s} x=\"{d:.6}\" y=\"{d:.6}\" z=\"{d:.6}\" />", .{ name, r[i * 3], r[i * 3 + 1], r[i * 3 + 2] });
        }
        try w.writeAll("</rotation>");
    }

    fn swapsXml(w: *std.Io.Writer, swaps: []const Swap) !void {
        if (swaps.len == 0) return;
        try w.writeAll("<BFTextureSwapInfo version=\"0\">");
        for (swaps) |s| {
            try w.writeAll("<texture");
            try attr(w, "imageName", s.image);
            try attr(w, "layer", s.layer);
            try w.writeAll(" />");
        }
        try w.writeAll("</BFTextureSwapInfo>");
    }

    /// Writes the world as a `.zt2`. `terrain_name` is the terrain file the
    /// save refers to (written alongside by the caller).
    pub fn save(self: *const World, w: *std.Io.Writer, terrain_name: []const u8) !void {
        try w.writeAll("<BFContext version=\"1\" generator=\"zootycon2\">\n");
        try w.writeAll("\t<ZTMapData version=\"0\"");
        try attr(w, "name", self.name);
        try attr(w, "biome", self.biome);
        try w.print(" />\n\t<ZTStatus version=\"0\" zootycon_income=\"{d:.2}\" zootycon_guests=\"{d}\" zootycon_views=\"{d}\" />\n\t<ZTWorldMgr version=\"0\"", .{ self.income, self.guests_total, self.views });
        try attr(w, "environment", self.environment);
        try attr(w, "terrFile", terrain_name);
        try w.writeAll(">");
        if (self.camera) |c| try w.print("<camPos x=\"{d:.6}\" y=\"{d:.6}\" z=\"{d:.6}\" />", .{ c[0], c[1], c[2] });
        try w.writeAll("</ZTWorldMgr>\n\t<BFGManager><entityList>\n");

        for (self.props.items) |p| {
            try w.writeAll("\t\t<BFPhysObj version=\"0\"");
            if (p.binder.len > 0) {
                try attr(w, "zootycon_binder", p.binder);
                try w.print(" zootycon_food=\"{d:.2}\"", .{p.food});
            }
            try w.writeAll("><BFRSceneGraphComponent version=\"0\"");
            try attr(w, "modelfile", p.model);
            try w.print(" scale=\"{d:.6}\" visible=\"1\" />", .{p.scale});
            try w.print("<position x=\"{d:.6}\" y=\"{d:.6}\" z=\"{d:.6}\" />", .{ p.position[0], p.position[1], p.position[2] });
            try rotationXml(w, p.rotation);
            try swapsXml(w, p.swaps);
            try w.writeAll("</BFPhysObj>\n");
        }
        for (self.fences.items) |f| {
            try w.writeAll("\t\t<ZTFenceEntity version=\"0\"");
            try attr(w, "ZTFenceType", f.kind);
            try w.print(" rotation=\"{d:.6}\" position=\"{d:.6} {d:.6} {d:.6}\" />\n", .{ f.rotation, f.position[0], f.position[1], f.position[2] });
        }
        for (self.paths.items) |p| {
            try w.writeAll("\t\t<BFGEntity version=\"0\"><subComponents><ZTPath version=\"0\"");
            try attr(w, "texture", p.texture);
            try w.writeAll(" /><BFPhysObj version=\"0\"><BFTerrainDecalComponent version=\"0\"");
            try w.print(" dwidth=\"{d:.6}\" dheight=\"{d:.6}\" />", .{ p.width, p.height });
            try w.print("<position x=\"{d:.6}\" y=\"{d:.6}\" z=\"0\" />", .{ p.position[0], p.position[1] });
            try w.writeAll("</BFPhysObj></subComponents></BFGEntity>\n");
        }
        for (self.actors.items) |a| {
            try w.writeAll("\t\t<BFGEntity version=\"0\"");
            const unique = try std.fmt.allocPrint(self.gpa, "{s}/BFBinderRoot", .{a.binder});
            defer self.gpa.free(unique);
            try attr(w, "binderUniqueName", unique);
            try w.writeAll("><subComponents><BFPhysObj version=\"0\"");
            const main_name = try std.fmt.allocPrint(self.gpa, "mainObj/{s}/BFBinderRoot", .{a.binder});
            defer self.gpa.free(main_name);
            try attr(w, "binderUniqueName", main_name);
            try w.print("><position x=\"{d:.6}\" y=\"{d:.6}\" z=\"{d:.6}\" />", .{ a.position[0], a.position[1], a.position[2] });
            try rotationXml(w, a.rotation);
            try swapsXml(w, a.swaps);
            try w.writeAll("</BFPhysObj>");
            if (a.head) |h| {
                const head_name = try std.fmt.allocPrint(self.gpa, "headObj/{s}/BFBinderRoot", .{a.binder});
                defer self.gpa.free(head_name);
                try w.writeAll("<BFPhysObj version=\"0\"");
                try attr(w, "binderUniqueName", head_name);
                try w.writeAll("><BFSimpleLODComponent version=\"0\"");
                try attr(w, "modelfile", h.model);
                try w.print(" worldyaw=\"{d:.6}\" visible=\"1\" />", .{h.yaw});
                try swapsXml(w, h.swaps);
                try w.writeAll("</BFPhysObj>");
            }
            try w.writeAll("</subComponents></BFGEntity>\n");
        }
        try w.writeAll("\t</entityList></BFGManager>\n</BFContext>\n");
    }
};

fn testTerrain(gpa: std.mem.Allocator) !terrain_mod.Terrain {
    const rs = 28;
    var buf: [48 + 4 + 4 + 4 * rs]u8 = undefined;
    @memset(&buf, 0);
    const wr = std.mem.writeInt;
    wr(u32, buf[0..4], 11, .little);
    wr(u32, buf[4..8], @bitCast(@as(f32, 3.0)), .little);
    wr(u32, buf[8..12], @bitCast(@as(f32, 3.0)), .little);
    wr(u32, buf[28..32], 2, .little);
    wr(u32, buf[32..36], 2, .little);
    wr(u32, buf[44..48], 1, .little);
    wr(u32, buf[48..52], 4, .little);
    @memcpy(buf[52..55], "abc");
    for (0..4) |i| {
        const rec = 56 + i * rs;
        wr(u32, buf[rec + 18 ..][0..4], @bitCast(@as(f32, 6.0)), .little);
        wr(u32, buf[rec + 22 ..][0..4], @bitCast(@as(f32, 26.0)), .little);
    }
    return terrain_mod.parse(gpa, &buf);
}

test "save and reload round trip" {
    const gpa = std.testing.allocator;
    var w = World.init(gpa, try testTerrain(gpa));
    defer w.deinit();
    w.name = "mapname:test";
    w.biome = "alpine";
    w.camera = .{ 1, 2, 3 };
    w.income = 1234.5;
    w.guests_total = 7;
    const swaps = [_]Swap{.{ .image = "a/b.dds", .layer = "base" }};
    const prop_id = try w.addPropEx("entities/objects/x", .{ 1, 2, 3 }, yawRotation(0.5), 1.5, &swaps, "FoodDish_Hay", 42.5);
    _ = try w.addFence("zoowall", .{ 6, 9, 0 }, 1.5708);
    _ = try w.addPath("tex/path.dds", .{ 4.5, 7.5 }, 6, 6);
    _ = try w.addActor("Guest_Adult_F_05", .{ 10, 11, 12 }, identity_rotation, &.{});
    w.actors.items[0].head = .{ .model = "entities/units/guests/head", .yaw = 3.14 };
    const gone = try w.addProp("entities/objects/y", .{ 0, 0, 0 }, identity_rotation, 1, &.{});
    try std.testing.expect(w.remove(gone));
    try std.testing.expect(!w.remove(gone));
    try std.testing.expect(prop_id != gone);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try w.save(&out.writer, "t.dat");

    var m = try map_mod.parse(gpa, out.written());
    defer m.deinit();
    try std.testing.expectEqualStrings("t.dat", m.terrain_file);
    try std.testing.expectApproxEqAbs(@as(f64, 1234.5), m.income, 1e-6);
    try std.testing.expectEqual(@as(u32, 7), m.guests_total);
    try std.testing.expectEqualStrings("alpine", m.biome);
    try std.testing.expectEqual(@as(usize, 1), m.objects.len);
    try std.testing.expectEqualStrings("entities/objects/x", m.objects[0].model);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), m.objects[0].scale, 1e-5);
    try std.testing.expectApproxEqAbs(@cos(@as(f32, 0.5)), m.objects[0].rotation[0], 1e-5);
    try std.testing.expectEqualStrings("a/b.dds", m.objects[0].swaps[0].image);
    try std.testing.expectEqualStrings("FoodDish_Hay", m.objects[0].binder);
    try std.testing.expectApproxEqAbs(@as(f32, 42.5), m.objects[0].food, 1e-4);
    try std.testing.expectEqual(@as(usize, 1), m.fences.len);
    try std.testing.expectEqualStrings("zoowall", m.fences[0].kind);
    try std.testing.expectEqual(@as(usize, 1), m.paths.len);
    try std.testing.expectApproxEqAbs(@as(f32, 7.5), m.paths[0].position[1], 1e-5);
    try std.testing.expectEqual(@as(usize, 1), m.actors.len);
    try std.testing.expectEqualStrings("Guest_Adult_F_05", m.actors[0].binder);
    try std.testing.expectApproxEqAbs(@as(f32, 12), m.actors[0].position[2], 1e-5);
    try std.testing.expectEqualStrings("entities/units/guests/head", m.actors[0].head.?.model);
    try std.testing.expectApproxEqAbs(@as(f32, 3.14), m.actors[0].head.?.yaw, 1e-4);
    try std.testing.expectEqual(@as(usize, 1), m.objects.len); // the head is not a prop
}
