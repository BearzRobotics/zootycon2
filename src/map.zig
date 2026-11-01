//! Map and save files (`.zt2`). A map is an XML document whose root is
//! `BFContext`; the same format stores saved zoos. This reader extracts what
//! is needed to show a map: which terrain file it uses and every placed
//! object that has a model.
//!
//! Placed objects are `BFPhysObj` elements. One that is drawable carries a
//! scene-graph component with a non-empty `modelfile` (`BFRSceneGraphComponent`,
//! `BFNISceneGraphComponent`, `BFSimpleLODComponent`) plus a `position` and a
//! `rotation` (three `row0..row2` vectors).

const std = @import("std");
const xml = @import("xml.zig");

pub const Object = struct {
    /// Model path as written (often without an extension).
    model: []const u8,
    scale: f32,
    position: [3]f32,
    /// Row-major 3x3 rotation.
    rotation: [9]f32,
};

/// One straight 3-unit fence (or curb) segment on a tile edge. `kind` names
/// an entity (`zoowall`, `chainlink`, `curb_jungle`, ...). The segment runs
/// from `position` in the direction given by `rotation` (radians about z).
pub const Fence = struct {
    kind: []const u8,
    rotation: f32,
    position: [3]f32,
};

/// A path tile: a texture quad draped over the terrain, centred on `position`.
pub const PathDecal = struct {
    texture: []const u8,
    position: [2]f32,
    width: f32,
    height: f32,
};

/// An entity whose model is not stored in the save: it comes from the
/// entity definition named `binder` (animals, guests, staff).
pub const Actor = struct {
    binder: []const u8,
    position: [3]f32,
    /// Row-major 3x3 rotation.
    rotation: [9]f32,
};

pub const Map = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    biome: []const u8,
    terrain_file: []const u8,
    environment: []const u8,
    camera: ?[3]f32,
    objects: []const Object,
    fences: []const Fence,
    paths: []const PathDecal,
    actors: []const Actor,

    pub fn deinit(self: *Map) void {
        self.arena.deinit();
    }
};

pub const Error = error{ BadMap, OutOfMemory };

const model_components = [_][]const u8{ "BFRSceneGraphComponent", "BFNISceneGraphComponent", "BFSimpleLODComponent" };

fn attrFloat(e: *const xml.Element, name: []const u8, default: f32) f32 {
    const v = e.attr(name) orelse return default;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch default;
}

fn vec3(e: *const xml.Element) [3]f32 {
    return .{ attrFloat(e, "x", 0), attrFloat(e, "y", 0), attrFloat(e, "z", 0) };
}

const Collector = struct {
    a: std.mem.Allocator,
    list: std.ArrayList(Object) = .empty,
    fences: std.ArrayList(Fence) = .empty,
    paths: std.ArrayList(PathDecal) = .empty,
    actors: std.ArrayList(Actor) = .empty,

    fn visit(self: *Collector, e: *const xml.Element) Error!void {
        if (std.ascii.eqlIgnoreCase(e.name, "BFGEntity")) {
            try self.pathEntity(e);
            try self.actorEntity(e);
        }
        if (std.ascii.eqlIgnoreCase(e.name, "ZTFenceEntity")) {
            try self.fence(e);
            return;
        }
        if (std.ascii.eqlIgnoreCase(e.name, "BFPhysObj")) {
            try self.physObj(e);
            return;
        }
        for (e.children) |c| try self.visit(c);
    }

    fn hasModel(phys: *const xml.Element) bool {
        for (phys.children) |c| for (model_components) |name| {
            if (std.ascii.eqlIgnoreCase(c.name, name)) {
                if (c.attr("modelfile")) |m| if (m.len > 0) return true;
            }
        };
        return false;
    }

    /// Entities whose `mainObj` carries no model of its own.
    fn actorEntity(self: *Collector, e: *const xml.Element) Error!void {
        const sub = e.child("subComponents") orelse return;
        if (sub.child("ZTPath") != null) return;
        const unique = e.attr("binderUniqueName") orelse return;
        const binder = unique[0 .. std.mem.indexOfScalar(u8, unique, '/') orelse unique.len];
        if (binder.len == 0) return;
        for (sub.children) |c| {
            if (!std.ascii.eqlIgnoreCase(c.name, "BFPhysObj")) continue;
            const name = c.attr("binderUniqueName") orelse continue;
            if (!std.mem.startsWith(u8, name, "mainObj/")) continue;
            if (hasModel(c)) return;
            const pos = c.child("position") orelse return;
            var rot = [9]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
            if (c.child("rotation")) |r| {
                const rows = [3][]const u8{ "row0", "row1", "row2" };
                for (rows, 0..) |rn, i| if (r.child(rn)) |row| {
                    const v = vec3(row);
                    rot[i * 3 + 0] = v[0];
                    rot[i * 3 + 1] = v[1];
                    rot[i * 3 + 2] = v[2];
                };
            }
            try self.actors.append(self.a, .{ .binder = binder, .position = vec3(pos), .rotation = rot });
            return;
        }
    }

    /// A path entity holds a `ZTPath` (the texture) and a physics object with
    /// a terrain-decal component (the placement).
    fn pathEntity(self: *Collector, e: *const xml.Element) Error!void {
        const sub = e.child("subComponents") orelse return;
        const zp = sub.child("ZTPath") orelse return;
        const texture = zp.attr("texture") orelse return;
        for (sub.children) |c| {
            if (!std.ascii.eqlIgnoreCase(c.name, "BFPhysObj")) continue;
            const decal = c.child("BFTerrainDecalComponent") orelse continue;
            const pos = c.child("position") orelse continue;
            const v = vec3(pos);
            try self.paths.append(self.a, .{
                .texture = texture,
                .position = .{ v[0], v[1] },
                .width = attrFloat(decal, "dwidth", 6),
                .height = attrFloat(decal, "dheight", 6),
            });
            return;
        }
    }

    fn fence(self: *Collector, e: *const xml.Element) Error!void {
        const kind = e.attr("ZTFenceType") orelse return;
        const pos_text = e.attr("position") orelse return;
        var pos: [3]f32 = .{ 0, 0, 0 };
        var it = std.mem.tokenizeScalar(u8, pos_text, ' ');
        for (&pos) |*v| {
            const tok = it.next() orelse break;
            v.* = std.fmt.parseFloat(f32, tok) catch 0;
        }
        try self.fences.append(self.a, .{
            .kind = kind,
            .rotation = attrFloat(e, "rotation", 0),
            .position = pos,
        });
    }

    fn physObj(self: *Collector, e: *const xml.Element) Error!void {
        var comp: ?*const xml.Element = null;
        for (e.children) |c| {
            for (model_components) |name| {
                if (std.ascii.eqlIgnoreCase(c.name, name)) comp = c;
            }
        }
        const sg = comp orelse return;
        const model = sg.attr("modelfile") orelse return;
        if (model.len == 0) return;
        if (sg.attr("visible")) |v| if (std.mem.eql(u8, v, "0")) return;
        const pos = e.child("position") orelse return;

        var rot = [9]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1 };
        if (e.child("rotation")) |r| {
            const rows = [3][]const u8{ "row0", "row1", "row2" };
            for (rows, 0..) |rn, i| if (r.child(rn)) |row| {
                const v = vec3(row);
                rot[i * 3 + 0] = v[0];
                rot[i * 3 + 1] = v[1];
                rot[i * 3 + 2] = v[2];
            };
        }
        try self.list.append(self.a, .{
            .model = model,
            .scale = attrFloat(sg, "scale", 1.0),
            .position = vec3(pos),
            .rotation = rot,
        });
    }
};

pub fn parse(gpa: std.mem.Allocator, data: []const u8) Error!Map {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var root: *const xml.Element = xml.parse(a, data, null) catch return error.BadMap;
    // Saves wrap the context in a `saveRoot` element.
    if (std.ascii.eqlIgnoreCase(root.name, "saveRoot")) root = root.child("BFContext") orelse return error.BadMap;
    if (!std.ascii.eqlIgnoreCase(root.name, "BFContext")) return error.BadMap;

    const map_data = root.child("ZTMapData");
    const world = root.child("ZTWorldMgr") orelse return error.BadMap;
    var cam: ?[3]f32 = null;
    if (world.child("camPos")) |c| cam = vec3(c);

    var col: Collector = .{ .a = a };
    try col.visit(root);

    return .{
        .arena = arena,
        .name = if (map_data) |m| m.attr("name") orelse "" else "",
        .biome = if (map_data) |m| m.attr("biome") orelse "" else "",
        .terrain_file = world.attr("terrFile") orelse return error.BadMap,
        .environment = world.attr("environment") orelse "",
        .camera = cam,
        .objects = try col.list.toOwnedSlice(a),
        .fences = try col.fences.toOwnedSlice(a),
        .paths = try col.paths.toOwnedSlice(a),
        .actors = try col.actors.toOwnedSlice(a),
    };
}

test "parses a synthetic map" {
    const src =
        \\<BFContext>
        \\  <ZTMapData name="mapname:x" biome="alpine" />
        \\  <ZTWorldMgr terrFile="x.dat" environment="env.xml"><camPos x="1" y="2" z="3"/></ZTWorldMgr>
        \\  <BFGManager><entityList><BFGEntity><subComponents>
        \\    <BFPhysObj>
        \\      <BFRSceneGraphComponent modelfile="a/b" scale="2.0" visible="1" />
        \\      <position x="10" y="20" z="30" />
        \\      <rotation><row0 x="0" y="1" z="0"/><row1 x="-1" y="0" z="0"/><row2 x="0" y="0" z="1"/></rotation>
        \\    </BFPhysObj>
        \\    <BFPhysObj><BFMovingBlobShadowComponent /><position x="0" y="0" z="0" /></BFPhysObj>
        \\    <ZTFenceEntity ZTFenceType="zoowall" rotation="1.5" position="6 9 0" />
        \\  </subComponents></BFGEntity></entityList></BFGManager>
        \\</BFContext>
    ;
    var m = try parse(std.testing.allocator, src);
    defer m.deinit();
    try std.testing.expectEqualStrings("x.dat", m.terrain_file);
    try std.testing.expectEqual(@as(usize, 1), m.objects.len);
    try std.testing.expectEqualStrings("a/b", m.objects[0].model);
    try std.testing.expectEqual(@as(f32, 30), m.objects[0].position[2]);
    try std.testing.expectEqual(@as(f32, 1), m.objects[0].rotation[1]);
    try std.testing.expectEqual(@as(f32, 3), m.camera.?[2]);
    try std.testing.expectEqual(@as(usize, 1), m.fences.len);
    try std.testing.expectEqualStrings("zoowall", m.fences[0].kind);
    try std.testing.expectEqual(@as(f32, 9), m.fences[0].position[1]);
}
