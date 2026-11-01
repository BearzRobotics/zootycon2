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

pub const Map = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    biome: []const u8,
    terrain_file: []const u8,
    environment: []const u8,
    camera: ?[3]f32,
    objects: []const Object,

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

    fn visit(self: *Collector, e: *const xml.Element) Error!void {
        if (std.ascii.eqlIgnoreCase(e.name, "BFPhysObj")) {
            try self.physObj(e);
            return;
        }
        for (e.children) |c| try self.visit(c);
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
}
