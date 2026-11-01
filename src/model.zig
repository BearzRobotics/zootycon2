//! Model manifests (`.bfm`) and material files (`.bfmat`), both XML.
//!
//! A `.bfm` names the NIF model to load, lists its animations (`.bf` files)
//! with playback flags, and carries an animation state graph. A `.bfmat`
//! names a rendering effect and sets Direct3D-style render-state parameters
//! and textures.

const std = @import("std");
const xml = @import("xml.zig");

// ---------------------------------------------------------------- manifest

pub const Animation = struct {
    /// VFS path of the `.bf` animation file (as written, may use backslashes).
    path: []const u8,
    name: []const u8,
    speed: f32,
    /// Only played when asked for by name, never picked by the state graph.
    explicit_use_only: bool,
    load: bool,
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    /// VFS path of the `.nif` model.
    model_name: []const u8,
    animations: []const Animation,
    /// Animation state graph, kept as parsed XML for the behaviour code.
    graph: ?*const xml.Element,

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
    }

    pub fn animation(self: *const Manifest, name: []const u8) ?*const Animation {
        for (self.animations) |*a| {
            if (std.ascii.eqlIgnoreCase(a.name, name)) return a;
        }
        return null;
    }
};

pub const Error = error{ BadManifest, BadMaterial, OutOfMemory, XmlError };

fn attrBool(e: *const xml.Element, name: []const u8, default: bool) bool {
    const v = e.attr(name) orelse return default;
    return std.ascii.eqlIgnoreCase(v, "true") or std.mem.eql(u8, v, "1");
}

fn attrFloat(e: *const xml.Element, name: []const u8, default: f32) f32 {
    const v = e.attr(name) orelse return default;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch default;
}

pub fn parseManifest(gpa: std.mem.Allocator, data: []const u8) Error!Manifest {
    var m: Manifest = .{ .arena = .init(gpa), .model_name = "", .animations = &.{}, .graph = null };
    errdefer m.arena.deinit();
    const a = m.arena.allocator();

    const root = xml.parse(a, data, null) catch return error.XmlError;
    if (!std.ascii.eqlIgnoreCase(root.name, "BFM")) return error.BadManifest;
    m.model_name = root.attr("modelname") orelse return error.BadManifest;
    m.graph = root.child("Graph");

    var anims: std.ArrayList(Animation) = .empty;
    for (root.children) |c| {
        if (!std.ascii.eqlIgnoreCase(c.name, "animation")) continue;
        try anims.append(a, .{
            .path = c.attr("anim") orelse continue,
            .name = c.attr("animName") orelse continue,
            .speed = attrFloat(c, "animSpeed", 1),
            .explicit_use_only = attrBool(c, "explicitUseOnly", false),
            .load = attrBool(c, "load", true),
        });
    }
    m.animations = anims.items;
    return m;
}

// ---------------------------------------------------------------- material

pub const Value = union(enum) {
    dword: u32,
    boolean: bool,
    float: f32,
    vector4: [4]f32,
    matrix: [16]f32,
    texture: []const u8,
};

pub const Param = struct {
    name: []const u8,
    value: Value,
};

pub const Material = struct {
    arena: std.heap.ArenaAllocator,
    /// Rendering effect name ("Base", "BaseDetail", "VertexColor", ...).
    fx: []const u8,
    name: []const u8,
    params: []const Param,

    pub fn deinit(self: *Material) void {
        self.arena.deinit();
    }

    pub fn get(self: *const Material, name: []const u8) ?Value {
        for (self.params) |p| {
            if (std.ascii.eqlIgnoreCase(p.name, name)) return p.value;
        }
        return null;
    }

    pub fn dword(self: *const Material, name: []const u8) ?u32 {
        return if (self.get(name)) |v| switch (v) {
            .dword => |d| d,
            else => null,
        } else null;
    }

    pub fn boolean(self: *const Material, name: []const u8) ?bool {
        return if (self.get(name)) |v| switch (v) {
            .boolean => |b| b,
            else => null,
        } else null;
    }

    pub fn float(self: *const Material, name: []const u8) ?f32 {
        return if (self.get(name)) |v| switch (v) {
            .float => |f| f,
            else => null,
        } else null;
    }

    pub fn vector4(self: *const Material, name: []const u8) ?[4]f32 {
        return if (self.get(name)) |v| switch (v) {
            .vector4 => |f| f,
            else => null,
        } else null;
    }

    pub fn texture(self: *const Material, name: []const u8) ?[]const u8 {
        return if (self.get(name)) |v| switch (v) {
            .texture => |t| t,
            else => null,
        } else null;
    }
};

/// Parses `n` comma/space separated floats into `out`; returns false if any is missing.
fn parseFloats(text: []const u8, out: []f32) bool {
    var it = std.mem.tokenizeAny(u8, text, ", \t\r\n");
    for (out) |*f| {
        const tok = it.next() orelse return false;
        f.* = std.fmt.parseFloat(f32, tok) catch return false;
    }
    return true;
}

pub fn parseMaterial(gpa: std.mem.Allocator, data: []const u8) Error!Material {
    var m: Material = .{ .arena = .init(gpa), .fx = "", .name = "", .params = &.{} };
    errdefer m.arena.deinit();
    const a = m.arena.allocator();

    const root = xml.parse(a, data, null) catch return error.XmlError;
    if (!std.ascii.eqlIgnoreCase(root.name, "material")) return error.BadMaterial;
    m.fx = root.attr("fx") orelse "";
    m.name = root.attr("name") orelse "";

    var params: std.ArrayList(Param) = .empty;
    for (root.children) |c| {
        if (!std.ascii.eqlIgnoreCase(c.name, "param")) continue;
        const name = c.attr("name") orelse continue;
        const kind = c.attr("type") orelse continue;
        const text = c.text;
        const value: Value = if (std.ascii.eqlIgnoreCase(kind, "dword"))
            .{ .dword = std.fmt.parseInt(u32, std.mem.trim(u8, text, " "), 0) catch continue }
        else if (std.ascii.eqlIgnoreCase(kind, "bool"))
            .{ .boolean = std.ascii.eqlIgnoreCase(std.mem.trim(u8, text, " "), "true") or std.mem.eql(u8, std.mem.trim(u8, text, " "), "1") }
        else if (std.ascii.eqlIgnoreCase(kind, "float"))
            .{ .float = std.fmt.parseFloat(f32, std.mem.trim(u8, text, " ")) catch continue }
        else if (std.ascii.eqlIgnoreCase(kind, "vector4")) blk: {
            var v: [4]f32 = undefined;
            if (!parseFloats(text, &v)) continue;
            break :blk .{ .vector4 = v };
        } else if (std.ascii.eqlIgnoreCase(kind, "matrix")) blk: {
            var v: [16]f32 = undefined;
            if (!parseFloats(text, &v)) continue;
            break :blk .{ .matrix = v };
        } else if (std.ascii.eqlIgnoreCase(kind, "texture"))
            .{ .texture = text }
        else
            continue;
        try params.append(a, .{ .name = name, .value = value });
    }
    m.params = params.items;
    return m;
}

test "manifest lists animations and keeps the graph" {
    const gpa = std.testing.allocator;
    var m = try parseManifest(gpa,
        \\<?xml version="1.0"?>
        \\<BFM modelname="entities\a\b.nif">
        \\  <animation anim="entities\a\b_walk.bf" animName="Walk" animSpeed="1.5" explicitUseOnly="true" load="true" />
        \\  <animation anim="entities\a\b_idle.bf" animName="Idle" />
        \\  <Graph name="g"><node name="Walk"/></Graph>
        \\</BFM>
    );
    defer m.deinit();
    try std.testing.expectEqualStrings("entities\\a\\b.nif", m.model_name);
    try std.testing.expectEqual(@as(usize, 2), m.animations.len);
    try std.testing.expectEqual(@as(f32, 1.5), m.animation("walk").?.speed);
    try std.testing.expect(m.animation("Walk").?.explicit_use_only);
    try std.testing.expect(!m.animation("Idle").?.explicit_use_only);
    try std.testing.expect(m.graph != null);
}

test "material params are typed" {
    const gpa = std.testing.allocator;
    var m = try parseMaterial(gpa,
        \\<material fx="Base" name="Body">
        \\  <param name="CullMode" type="dword">2</param>
        \\  <param name="AlphaTestEnable" type="bool">true</param>
        \\  <param name="MaterialPower" type="float">10.000000</param>
        \\  <param name="MaterialDiffuse" type="vector4">1.0, 0.5, 0.25, 1.0</param>
        \\  <param name="Texture0" type="texture">Teeth_alpha</param>
        \\</material>
    );
    defer m.deinit();
    try std.testing.expectEqualStrings("Base", m.fx);
    try std.testing.expectEqual(@as(u32, 2), m.dword("cullmode").?);
    try std.testing.expect(m.boolean("AlphaTestEnable").?);
    try std.testing.expectEqual(@as(f32, 10), m.float("MaterialPower").?);
    try std.testing.expectEqual(@as(f32, 0.5), m.vector4("MaterialDiffuse").?[1]);
    try std.testing.expectEqualStrings("Teeth_alpha", m.texture("Texture0").?);
    try std.testing.expect(m.dword("Nope") == null);
    try std.testing.expect(m.boolean("CullMode") == null);
}
