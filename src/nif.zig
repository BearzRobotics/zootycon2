//! Reader for NetImmerse/Gamebryo NIF files, version 10.0.1.0 (the only
//! version Zoo Tycoon 2 uses). The layout of each block comes from the
//! community-maintained NIF format documentation; the code is our own.
//!
//! Version 10.0.1.0 stores no block sizes, so every block type must be
//! understood to find where the next one starts. Unknown block types stop
//! parsing with `error.UnsupportedBlock` (and name the type in `Nif.failed_type`)
//! rather than guessing.

const std = @import("std");

pub const version_10_0_1_0: u32 = 0x0A000100;
const header_prefix = "NetImmerse File Format, Version 10.0.1.0\n";

pub const Vec3 = [3]f32;
pub const Mat3 = [9]f32; // as stored in the file (see `Transform`)

pub const Transform = struct {
    translation: Vec3,
    /// Row-major rotation matrix as read from the file.
    rotation: Mat3,
    scale: f32,
};

pub const Ref = i32; // block index, or -1 for none
pub const none: Ref = -1;

pub const ObjectNet = struct {
    name: []const u8,
    extra_data: []const Ref,
    controller: Ref,
};

pub const AvObject = struct {
    net: ObjectNet,
    flags: u16,
    transform: Transform,
    properties: []const Ref,
    collision: Ref,
};

pub const NodeKind = enum { node, lod, billboard };

pub const Node = struct {
    kind: NodeKind,
    av: AvObject,
    children: []const Ref,
    effects: []const Ref,
};

pub const Geometry = struct {
    av: AvObject,
    data: Ref,
    skin: Ref,
    shader_name: ?[]const u8,
};

pub const MeshData = struct {
    vertices: []const Vec3,
    normals: []const Vec3,
    colors: []const [4]f32,
    /// `uv_sets[s][v]`
    uv_sets: []const []const [2]f32,
    /// Triangle list indices (strips are expanded when read).
    indices: []const u16,
};

pub const TexDesc = struct {
    source: Ref,
    clamp_mode: u32,
    filter_mode: u32,
    uv_set: u32,
};

pub const Texturing = struct {
    net: ObjectNet,
    flags: u16,
    apply_mode: u32,
    base: ?TexDesc,
    dark: ?TexDesc,
    detail: ?TexDesc,
    gloss: ?TexDesc,
    glow: ?TexDesc,
    bump: ?TexDesc,
    decals: [4]?TexDesc,
};

pub const SourceTexture = struct {
    net: ObjectNet,
    /// File name when the texture is external.
    file_name: ?[]const u8,
};

pub const Material = struct {
    net: ObjectNet,
    ambient: Vec3,
    diffuse: Vec3,
    specular: Vec3,
    emissive: Vec3,
    glossiness: f32,
    alpha: f32,
};

pub const SkinWeight = struct { vertex: u16, weight: f32 };

pub const SkinBone = struct {
    /// Maps geometry (bind-pose) space into this bone's space.
    transform: Transform,
    weights: []const SkinWeight,
};

pub const SkinInstance = struct {
    data: Ref,
    root: Ref,
    /// Bone node for each entry of the skin data.
    bones: []const Ref,
};

pub const SkinData = struct {
    overall: Transform,
    bones: []const SkinBone,
};

pub const Block = union(enum) {
    node: Node,
    geometry: Geometry,
    mesh_data: MeshData,
    texturing: Texturing,
    source_texture: SourceTexture,
    material: Material,
    alpha: struct { net: ObjectNet, flags: u16, threshold: u8 },
    zbuffer: struct { net: ObjectNet, flags: u16, function: u32 },
    string_extra: struct { name: []const u8, value: []const u8 },
    integer_extra: struct { name: []const u8, value: u32 },
    boolean_extra: struct { name: []const u8, value: bool },
    skin_instance: SkinInstance,
    skin_data: SkinData,
    /// Parsed for layout only; contents are not kept.
    other,
};

pub const Nif = struct {
    arena: std.heap.ArenaAllocator,
    block_types: []const []const u8,
    /// Type name index (into `block_types`) for each block.
    block_type_index: []const u16,
    blocks: []const Block,
    roots: []const Ref,

    pub fn deinit(self: *Nif) void {
        self.arena.deinit();
    }

    pub fn typeName(self: *const Nif, block: usize) []const u8 {
        return self.block_types[self.block_type_index[block]];
    }
};

pub const Error = error{
    NotNif,
    UnsupportedVersion,
    UnsupportedBlock,
    Truncated,
    BadData,
    OutOfMemory,
};

const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    a: std.mem.Allocator,

    fn need(self: *Reader, n: usize) Error!void {
        if (self.data.len - self.pos < n) return error.Truncated;
    }
    fn u8_(self: *Reader) Error!u8 {
        try self.need(1);
        defer self.pos += 1;
        return self.data[self.pos];
    }
    fn u16_(self: *Reader) Error!u16 {
        try self.need(2);
        defer self.pos += 2;
        return std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
    }
    fn u32_(self: *Reader) Error!u32 {
        try self.need(4);
        defer self.pos += 4;
        return std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
    }
    fn i32_(self: *Reader) Error!i32 {
        return @bitCast(try self.u32_());
    }
    fn f32_(self: *Reader) Error!f32 {
        return @bitCast(try self.u32_());
    }
    fn bool_(self: *Reader) Error!bool {
        return (try self.u8_()) != 0;
    }
    fn skip(self: *Reader, n: usize) Error!void {
        try self.need(n);
        self.pos += n;
    }
    /// Count that must fit in the remaining data at `elem_size` bytes each.
    fn count(self: *Reader, n: u32, elem_size: usize) Error!usize {
        const total = std.math.mul(usize, n, elem_size) catch return error.BadData;
        if (total > self.data.len - self.pos) return error.BadData;
        return n;
    }
    fn vec3(self: *Reader) Error!Vec3 {
        return .{ try self.f32_(), try self.f32_(), try self.f32_() };
    }
    fn string(self: *Reader) Error![]const u8 {
        const len = try self.u32_();
        _ = try self.count(len, 1);
        const s = self.data[self.pos..][0..len];
        self.pos += len;
        return self.a.dupe(u8, s);
    }
    fn refs(self: *Reader) Error![]const Ref {
        const n = try self.count(try self.u32_(), 4);
        const out = try self.a.alloc(Ref, n);
        for (out) |*r| r.* = try self.i32_();
        return out;
    }
    fn transform(self: *Reader) Error!Transform {
        var m: Mat3 = undefined;
        for (&m) |*x| x.* = try self.f32_();
        const t = try self.vec3();
        return .{ .translation = t, .rotation = m, .scale = try self.f32_() };
    }
    /// Translation, rotation, scale in the order NiAVObject stores them.
    fn avTransform(self: *Reader) Error!Transform {
        const t = try self.vec3();
        var m: Mat3 = undefined;
        for (&m) |*x| x.* = try self.f32_();
        return .{ .translation = t, .rotation = m, .scale = try self.f32_() };
    }
    fn objectNet(self: *Reader) Error!ObjectNet {
        return .{
            .name = try self.string(),
            .extra_data = try self.refs(),
            .controller = try self.i32_(),
        };
    }
    fn avObject(self: *Reader) Error!AvObject {
        const net = try self.objectNet();
        const flags = try self.u16_();
        const tr = try self.avTransform();
        const props = try self.refs();
        const coll = try self.i32_();
        return .{ .net = net, .flags = flags, .transform = tr, .properties = props, .collision = coll };
    }
    fn texDesc(self: *Reader) Error!TexDesc {
        const src = try self.i32_();
        const clamp = try self.u32_();
        const filter = try self.u32_();
        const uv = try self.u32_();
        try self.skip(4); // PS2 L, PS2 K
        return .{ .source = src, .clamp_mode = clamp, .filter_mode = filter, .uv_set = uv };
    }
    fn optTex(self: *Reader) Error!?TexDesc {
        return if (try self.bool_()) try self.texDesc() else null;
    }
    /// NiTimeController common fields.
    fn controllerBase(self: *Reader) Error!void {
        try self.skip(4 + 2 + 4 * 4 + 4); // next, flags, frequency, phase, start, stop, target
    }
    fn boundingVolume(self: *Reader) Error!void {
        const kind = try self.u32_();
        switch (kind) {
            0 => try self.skip(16), // sphere
            1 => try self.skip(12 + 36 + 12), // box
            2 => try self.skip(12 + 12 + 4 + 4), // capsule
            4 => {
                const n = try self.count(try self.u32_(), 4);
                for (0..n) |_| try self.boundingVolume();
            },
            5 => try self.skip(16 + 12), // half space
            else => return error.BadData,
        }
    }
    /// Key<T> group; `elem_floats` is the number of floats in T.
    fn keyGroup(self: *Reader, elem_floats: usize) Error!void {
        const n = try self.u32_();
        if (n == 0) return;
        const interp = try self.u32_();
        const per: usize = switch (interp) {
            1, 5 => 4 + 4 * elem_floats,
            2 => 4 + 3 * 4 * elem_floats,
            3 => 4 + 4 * elem_floats + 12,
            else => return error.BadData,
        };
        _ = try self.count(n, per);
        try self.skip(@as(usize, n) * per);
    }
};

/// Where a failed parse stopped.
pub const Diagnostic = struct {
    block_index: usize = 0,
    /// Byte offset where the failing block started.
    block_start: usize = 0,
    type_buf: [64]u8 = undefined,
    type_len: usize = 0,

    pub fn blockType(self: *const Diagnostic) []const u8 {
        return self.type_buf[0..self.type_len];
    }
};

/// Parses a complete NIF file. Strings in the result are copied into the
/// returned object's arena.
pub fn parse(gpa: std.mem.Allocator, data: []const u8) Error!Nif {
    return parseDiag(gpa, data, null);
}

pub fn parseDiag(gpa: std.mem.Allocator, data: []const u8, diag: ?*Diagnostic) Error!Nif {
    if (!std.mem.startsWith(u8, data, "NetImmerse File Format, Version ")) return error.NotNif;
    if (!std.mem.startsWith(u8, data, header_prefix)) return error.UnsupportedVersion;

    var nif: Nif = .{
        .arena = .init(gpa),
        .block_types = &.{},
        .block_type_index = &.{},
        .blocks = &.{},
        .roots = &.{},
    };
    errdefer nif.arena.deinit();
    const a = nif.arena.allocator();

    var r: Reader = .{ .data = data, .pos = header_prefix.len, .a = a };
    if ((try r.u32_()) != version_10_0_1_0) return error.UnsupportedVersion;
    const num_blocks = try r.count(try r.u32_(), 2);
    const num_types = try r.count(try r.u16_(), 4);

    const types = try a.alloc([]const u8, num_types);
    for (types) |*t| t.* = try r.string();
    const type_index = try a.alloc(u16, num_blocks);
    for (type_index) |*ti| {
        ti.* = try r.u16_();
        if (ti.* >= num_types) return error.BadData;
    }
    _ = try r.u32_(); // unknown, always 0
    // Each block is then preceded by a zero u32.
    nif.block_types = types;
    nif.block_type_index = type_index;

    const blocks = try a.alloc(Block, num_blocks);
    nif.blocks = blocks;
    for (blocks, 0..) |*b, i| {
        const start = r.pos;
        b.* = (blk: {
            _ = r.u32_() catch |e| break :blk e; // per-block prefix, always 0
            break :blk readBlock(&r, types[type_index[i]]);
        }) catch |err| {
            if (diag) |d| {
                d.block_index = i;
                d.block_start = start;
                const name = types[type_index[i]];
                d.type_len = @min(name.len, d.type_buf.len);
                @memcpy(d.type_buf[0..d.type_len], name[0..d.type_len]);
            }
            return err;
        };
    }

    // Footer: root references.
    const num_roots = try r.count(try r.u32_(), 4);
    const roots = try a.alloc(Ref, num_roots);
    for (roots) |*x| x.* = try r.i32_();
    nif.roots = roots;
    if (r.pos != data.len) return error.BadData;
    return nif;
}

const GeometryCommon = struct {
    num_vertices: usize,
    vertices: []const Vec3,
    normals: []const Vec3,
    colors: []const [4]f32,
    uv_sets: []const []const [2]f32,
};

/// The NiGeometryData fields shared by every geometry data block.
fn readGeometryCommon(r: *Reader) Error!GeometryCommon {
    const a = r.a;
    const n_verts = try r.u16_();
    const nv: usize = n_verts;
    var vertices: []const Vec3 = &.{};
    if (try r.bool_()) {
        _ = try r.count(n_verts, 12);
        const v = try a.alloc(Vec3, nv);
        for (v) |*x| x.* = try r.vec3();
        vertices = v;
    }
    const data_flags = try r.u16_();
    var normals: []const Vec3 = &.{};
    if (try r.bool_()) {
        _ = try r.count(n_verts, 12);
        const v = try a.alloc(Vec3, nv);
        for (v) |*x| x.* = try r.vec3();
        normals = v;
        // Tangents and bitangents follow when bit 12 of the data flags is set.
        if (data_flags & 0x1000 != 0) try r.skip(nv * 24);
    }
    try r.skip(16); // bounding sphere
    var colors: []const [4]f32 = &.{};
    if (try r.bool_()) {
        _ = try r.count(n_verts, 16);
        const v = try a.alloc([4]f32, nv);
        for (v) |*x| x.* = .{ try r.f32_(), try r.f32_(), try r.f32_(), try r.f32_() };
        colors = v;
    }
    const num_uv = data_flags & 63;
    const uv_sets = try a.alloc([]const [2]f32, num_uv);
    for (uv_sets) |*set| {
        _ = try r.count(n_verts, 8);
        const v = try a.alloc([2]f32, nv);
        for (v) |*x| x.* = .{ try r.f32_(), try r.f32_() };
        set.* = v;
    }
    try r.skip(2); // consistency flags
    return .{ .num_vertices = nv, .vertices = vertices, .normals = normals, .colors = colors, .uv_sets = uv_sets };
}

fn readBlock(r: *Reader, type_name: []const u8) Error!Block {
    const a = r.a;
    const eql = std.mem.eql;

    if (eql(u8, type_name, "NiNode") or eql(u8, type_name, "NiBillboardNode") or eql(u8, type_name, "NiLODNode")) {
        const av = try r.avObject();
        const children = try r.refs();
        const effects = try r.refs();
        var kind: NodeKind = .node;
        if (eql(u8, type_name, "NiBillboardNode")) {
            kind = .billboard;
        } else if (eql(u8, type_name, "NiLODNode")) {
            kind = .lod;
            try r.skip(4 + 12); // index, LOD center
            const n = try r.count(try r.u32_(), 8);
            try r.skip(n * 8); // LOD ranges
        }
        return .{ .node = .{ .kind = kind, .av = av, .children = children, .effects = effects } };
    }

    if (eql(u8, type_name, "NiTriShape") or eql(u8, type_name, "NiTriStrips") or
        eql(u8, type_name, "NiParticles") or eql(u8, type_name, "NiParticleMeshes"))
    {
        const av = try r.avObject();
        const data = try r.i32_();
        const skin = try r.i32_();
        const has_shader = try r.bool_();
        var shader: ?[]const u8 = null;
        if (has_shader) {
            shader = try r.string();
            try r.skip(4);
        }
        return .{ .geometry = .{ .av = av, .data = data, .skin = skin, .shader_name = shader } };
    }

    if (eql(u8, type_name, "NiParticlesData") or eql(u8, type_name, "NiParticleMeshesData")) {
        const g = try readGeometryCommon(r);
        try r.skip(4); // particle radius
        try r.skip(2); // number of active particles
        if (try r.bool_()) try r.skip(g.num_vertices * 4); // sizes
        if (try r.bool_()) try r.skip(g.num_vertices * 16); // rotations
        if (eql(u8, type_name, "NiParticleMeshesData")) try r.skip(4); // container node
        return .{ .mesh_data = .{ .vertices = g.vertices, .normals = g.normals, .colors = g.colors, .uv_sets = g.uv_sets, .indices = &.{} } };
    }

    if (eql(u8, type_name, "NiTriShapeData") or eql(u8, type_name, "NiTriStripsData")) {
        const g = try readGeometryCommon(r);
        var indices: std.ArrayList(u16) = .empty;
        if (eql(u8, type_name, "NiTriShapeData")) {
            const n_tris = try r.u16_();
            _ = try r.u32_(); // number of triangle points
            _ = try r.count(n_tris, 6);
            try indices.ensureTotalCapacity(a, @as(usize, n_tris) * 3);
            for (0..@as(usize, n_tris) * 3) |_| indices.appendAssumeCapacity(try r.u16_());
            const n_groups = try r.u16_();
            for (0..n_groups) |_| {
                const m = try r.count(try r.u16_(), 2);
                try r.skip(m * 2);
            }
        } else {
            _ = try r.u16_(); // number of triangles
            const n_strips = try r.count(try r.u16_(), 2);
            const lens = try a.alloc(u16, n_strips);
            for (lens) |*l| l.* = try r.u16_();
            for (lens) |len| {
                _ = try r.count(len, 2);
                var prev2: u16 = 0;
                var prev1: u16 = 0;
                for (0..len) |k| {
                    const cur = try r.u16_();
                    if (k >= 2 and prev2 != prev1 and prev1 != cur and prev2 != cur) {
                        // Strips alternate winding; flip every other triangle.
                        if (k % 2 == 0) {
                            try indices.appendSlice(a, &.{ prev2, prev1, cur });
                        } else {
                            try indices.appendSlice(a, &.{ prev1, prev2, cur });
                        }
                    }
                    prev2 = prev1;
                    prev1 = cur;
                }
            }
        }
        return .{ .mesh_data = .{
            .vertices = g.vertices,
            .normals = g.normals,
            .colors = g.colors,
            .uv_sets = g.uv_sets,
            .indices = indices.items,
        } };
    }

    // ---- properties ----
    if (eql(u8, type_name, "NiTexturingProperty")) {
        const net = try r.objectNet();
        const flags = try r.u16_();
        const apply = try r.u32_();
        const tex_count = try r.u32_();
        const base = try r.optTex();
        const dark = try r.optTex();
        const detail = try r.optTex();
        const gloss = try r.optTex();
        const glow = try r.optTex();
        var bump: ?TexDesc = null;
        if (tex_count > 5 and try r.bool_()) {
            bump = try r.texDesc();
            try r.skip(8 + 16); // luma scale, offset, 2x2 matrix
        }
        var decals: [4]?TexDesc = .{ null, null, null, null };
        for (&decals, 0..) |*d, i| {
            if (tex_count > 6 + i) d.* = try r.optTex();
        }
        const n_shader = try r.count(try r.u32_(), 5);
        for (0..n_shader) |_| {
            if (try r.bool_()) {
                _ = try r.texDesc();
                _ = try r.u32_();
            }
        }
        return .{ .texturing = .{ .net = net, .flags = flags, .apply_mode = apply, .base = base, .dark = dark, .detail = detail, .gloss = gloss, .glow = glow, .bump = bump, .decals = decals } };
    }
    if (eql(u8, type_name, "NiSourceTexture")) {
        const net = try r.objectNet();
        const external = try r.u8_();
        var file: ?[]const u8 = null;
        if (external == 1) {
            file = try r.string();
        } else {
            const internal = try r.u8_();
            if (internal == 1) try r.skip(4); // pixel data ref
        }
        try r.skip(12 + 1); // format prefs, is static
        return .{ .source_texture = .{ .net = net, .file_name = file } };
    }
    if (eql(u8, type_name, "NiMaterialProperty")) {
        const net = try r.objectNet();
        try r.skip(2); // flags
        const amb = try r.vec3();
        const dif = try r.vec3();
        const spec = try r.vec3();
        const emis = try r.vec3();
        const gloss = try r.f32_();
        const alpha = try r.f32_();
        return .{ .material = .{ .net = net, .ambient = amb, .diffuse = dif, .specular = spec, .emissive = emis, .glossiness = gloss, .alpha = alpha } };
    }
    if (eql(u8, type_name, "NiAlphaProperty")) {
        const net = try r.objectNet();
        const flags = try r.u16_();
        return .{ .alpha = .{ .net = net, .flags = flags, .threshold = try r.u8_() } };
    }
    if (eql(u8, type_name, "NiZBufferProperty")) {
        const net = try r.objectNet();
        const flags = try r.u16_();
        return .{ .zbuffer = .{ .net = net, .flags = flags, .function = try r.u32_() } };
    }
    if (eql(u8, type_name, "NiVertexColorProperty")) {
        _ = try r.objectNet();
        try r.skip(2 + 4 + 4);
        return .other;
    }
    if (eql(u8, type_name, "NiStencilProperty")) {
        _ = try r.objectNet();
        try r.skip(2 + 1 + 4 * 7);
        return .other;
    }
    if (eql(u8, type_name, "NiSpecularProperty") or eql(u8, type_name, "NiWireframeProperty") or
        eql(u8, type_name, "NiDitherProperty") or eql(u8, type_name, "NiShadeProperty"))
    {
        _ = try r.objectNet();
        try r.skip(2);
        return .other;
    }

    // ---- extra data ----
    if (eql(u8, type_name, "NiStringExtraData")) {
        // NiExtraData: just a name at this version.
        const name = try r.string();
        return .{ .string_extra = .{ .name = name, .value = try r.string() } };
    }
    if (eql(u8, type_name, "NiIntegerExtraData")) {
        const name = try r.string();
        return .{ .integer_extra = .{ .name = name, .value = try r.u32_() } };
    }
    if (eql(u8, type_name, "NiBooleanExtraData")) {
        const name = try r.string();
        return .{ .boolean_extra = .{ .name = name, .value = try r.bool_() } };
    }
    if (eql(u8, type_name, "NiTextKeyExtraData")) {
        _ = try r.string(); // name
        const n = try r.count(try r.u32_(), 8);
        for (0..n) |_| {
            try r.skip(4); // time
            _ = try r.string();
        }
        return .other;
    }

    // ---- collision ----
    if (eql(u8, type_name, "NiCollisionData")) {
        try r.skip(4 + 4); // target, propagation mode
        if ((try r.u8_()) == 1) try r.boundingVolume();
        return .other;
    }

    // ---- skinning ----
    if (eql(u8, type_name, "NiSkinInstance")) {
        const data = try r.i32_();
        const root = try r.i32_();
        const bones = try r.refs();
        return .{ .skin_instance = .{ .data = data, .root = root, .bones = bones } };
    }
    if (eql(u8, type_name, "NiSkinData")) {
        const overall = try r.transform();
        const n_bones = try r.count(try r.u32_(), 52 + 16 + 2);
        try r.skip(4); // skin partition ref
        const has_weights = try r.bool_();
        const bones = try r.a.alloc(SkinBone, n_bones);
        for (bones) |*b| {
            b.transform = try r.transform();
            try r.skip(16); // bounding sphere
            const n = try r.count(try r.u16_(), 0);
            b.weights = &.{};
            if (has_weights) {
                _ = try r.count(@intCast(n), 6);
                const w = try r.a.alloc(SkinWeight, n);
                for (w) |*e| {
                    e.vertex = try r.u16_();
                    e.weight = try r.f32_();
                }
                b.weights = w;
            }
        }
        return .{ .skin_data = .{ .overall = overall, .bones = bones } };
    }
    if (eql(u8, type_name, "NiSkinPartition")) {
        const n_parts = try r.count(try r.u32_(), 10);
        for (0..n_parts) |_| {
            const n_verts: usize = try r.u16_();
            const n_tris: usize = try r.u16_();
            const n_bones: usize = try r.u16_();
            const n_strips: usize = try r.u16_();
            const n_weights: usize = try r.u16_();
            try r.skip(n_bones * 2); // bones
            try r.skip(n_verts * 2); // vertex map
            try r.skip(n_verts * n_weights * 4); // vertex weights
            var strip_total: usize = 0;
            const lens = try r.a.alloc(u16, n_strips);
            for (lens) |*l| {
                l.* = try r.u16_();
                strip_total += l.*;
            }
            if (n_strips != 0) try r.skip(strip_total * 2) else try r.skip(n_tris * 6);
            if (try r.bool_()) try r.skip(n_verts * n_weights); // bone indices
        }
        return .other;
    }

    // ---- controllers and animation data ----
    if (eql(u8, type_name, "NiKeyframeController")) {
        try r.controllerBase();
        try r.skip(4); // data ref
        return .other;
    }
    if (eql(u8, type_name, "NiKeyframeData")) {
        const n_rot = try r.u32_();
        if (n_rot != 0) {
            const rot_type = try r.u32_();
            if (rot_type == 4) {
                try r.skip(4); // order
                for (0..3) |_| try r.keyGroup(1);
            } else {
                const per: usize = switch (rot_type) {
                    1, 5 => 4 + 16,
                    2 => 4 + 16 + 0, // quadratic quaternion keys carry no tangents in this form
                    3 => 4 + 16 + 12,
                    else => return error.BadData,
                };
                _ = try r.count(n_rot, per);
                try r.skip(@as(usize, n_rot) * per);
            }
        }
        try r.keyGroup(3); // translations
        try r.keyGroup(1); // scales
        return .other;
    }
    if (eql(u8, type_name, "NiBoneLODController")) {
        try r.controllerBase();
        try r.skip(4); // LOD
        const n_lods = try r.count(try r.u32_(), 4);
        try r.skip(4); // number of node groups (total)
        for (0..n_lods) |_| {
            const n = try r.count(try r.u32_(), 4);
            try r.skip(n * 4);
        }
        const n_shape_groups = try r.count(try r.u32_(), 4);
        for (0..n_shape_groups) |_| {
            const n = try r.count(try r.u32_(), 8);
            try r.skip(n * 8); // skin info: shape ref + skin instance ref
        }
        const n2 = try r.count(try r.u32_(), 4);
        try r.skip(n2 * 4);
        return .other;
    }


    // ---- lights and effects ----
    if (eql(u8, type_name, "NiDirectionalLight") or eql(u8, type_name, "NiAmbientLight") or eql(u8, type_name, "NiPointLight")) {
        _ = try r.avObject();
        try r.skip(4 + 36); // dimmer, ambient/diffuse/specular
        if (eql(u8, type_name, "NiPointLight")) try r.skip(12);
        return .other;
    }
    if (eql(u8, type_name, "NiTextureEffect")) {
        _ = try r.avObject();
        try r.skip(36 + 12 + 4 * 4 + 4 + 1 + 16 + 4);
        return .other;
    }

    // ---- particle system ----
    if (eql(u8, type_name, "NiParticleSystemController")) {
        try r.controllerBase();
        try r.skip(24 + 12 + 16 + 4 + 4 + 4 + 1 + 4 + 4 + 4 + 1 + 1 + 12 + 4);
        try r.skip(2 + 4 + 2 + 4 + 4); // spawn generations .. dir chaos
        const n_particles = try r.u16_();
        try r.skip(2); // num valid
        _ = try r.count(n_particles, 40);
        try r.skip(@as(usize, n_particles) * 40);
        try r.skip(4 + 4 + 4 + 1); // emitter modifier, particle modifier, collider, static target bound
        return .other;
    }
    if (eql(u8, type_name, "NiParticleGrowFade")) {
        try r.skip(8 + 8);
        return .other;
    }
    if (eql(u8, type_name, "NiParticleRotation")) {
        try r.skip(8 + 1 + 12 + 4);
        return .other;
    }
    if (eql(u8, type_name, "NiParticleColorModifier")) {
        try r.skip(8 + 4);
        return .other;
    }
    if (eql(u8, type_name, "NiGravity")) {
        try r.skip(8 + 4 + 4 + 4 + 12 + 12);
        return .other;
    }
    if (eql(u8, type_name, "NiPlanarCollider")) {
        try r.skip(8 + 4 + 1 + 1 + 4 + 4 + 12 + 12 + 12 + 16);
        return .other;
    }
    if (eql(u8, type_name, "NiParticleMeshModifier")) {
        try r.skip(8);
        const n = try r.count(try r.u32_(), 4);
        try r.skip(n * 4);
        return .other;
    }

    // ---- more controllers and their data ----
    if (eql(u8, type_name, "NiAlphaController") or eql(u8, type_name, "NiMaterialColorController") or eql(u8, type_name, "NiVisController")) {
        try r.controllerBase();
        try r.skip(4);
        return .other;
    }
    if (eql(u8, type_name, "NiUVController")) {
        try r.controllerBase();
        try r.skip(2 + 4);
        return .other;
    }
    if (eql(u8, type_name, "NiGeomMorpherController")) {
        try r.controllerBase();
        try r.skip(4 + 1);
        return .other;
    }
    if (eql(u8, type_name, "NiFloatData")) {
        try r.keyGroup(1);
        return .other;
    }
    if (eql(u8, type_name, "NiPosData")) {
        try r.keyGroup(3);
        return .other;
    }
    if (eql(u8, type_name, "NiColorData")) {
        try r.keyGroup(4);
        return .other;
    }
    if (eql(u8, type_name, "NiUVData")) {
        for (0..4) |_| try r.keyGroup(1);
        return .other;
    }
    if (eql(u8, type_name, "NiVisData")) {
        const n = try r.count(try r.u32_(), 5);
        try r.skip(n * 5);
        return .other;
    }
    if (eql(u8, type_name, "NiMorphData")) {
        const n_morphs = try r.count(try r.u32_(), 8);
        const n_verts = try r.u32_();
        try r.skip(1); // relative targets
        for (0..n_morphs) |_| {
            const n_keys = try r.u32_();
            const interp = try r.u32_();
            const per: usize = switch (interp) {
                1, 5 => 8,
                2 => 16,
                3 => 20,
                else => return error.BadData,
            };
            _ = try r.count(n_keys, per);
            try r.skip(@as(usize, n_keys) * per);
            _ = try r.count(n_verts, 12);
            try r.skip(@as(usize, n_verts) * 12);
        }
        return .other;
    }
    if (eql(u8, type_name, "NiControllerSequence")) {
        _ = try r.string(); // name
        _ = try r.string(); // accum root name
        try r.skip(4); // text keys
        const n = try r.count(try r.u32_(), 8);
        for (0..n) |_| {
            _ = try r.string(); // target name
            try r.skip(4); // controller
        }
        return .other;
    }

    // ---- embedded pixel data ----
    if (eql(u8, type_name, "NiPixelData")) {
        try r.skip(4 + 16 + 4 + 8 + 4); // format, masks, bpp, fast compare, palette
        const n_mips = try r.count(try r.u32_(), 12);
        try r.skip(4); // bytes per pixel
        try r.skip(n_mips * 12);
        const n_pixels = try r.count(try r.u32_(), 1);
        try r.skip(n_pixels);
        return .other;
    }

    return error.UnsupportedBlock;
}

test "rejects non-NIF and other versions" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NotNif, parse(gpa, "hello"));
    try std.testing.expectError(error.UnsupportedVersion, parse(gpa, "NetImmerse File Format, Version 4.0.0.2\n"));
}

test "parses a minimal file with one empty node" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const w = struct {
        fn int(l: *std.ArrayList(u8), g: std.mem.Allocator, comptime T: type, v: T) !void {
            var b: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &b, v, .little);
            try l.appendSlice(g, &b);
        }
    };
    try buf.appendSlice(gpa, header_prefix);
    try w.int(&buf, gpa, u32, version_10_0_1_0);
    try w.int(&buf, gpa, u32, 1); // blocks
    try w.int(&buf, gpa, u16, 1); // types
    try w.int(&buf, gpa, u32, 6);
    try buf.appendSlice(gpa, "NiNode");
    try w.int(&buf, gpa, u16, 0); // block 0 -> type 0
    try w.int(&buf, gpa, u32, 0); // header unknown
    try w.int(&buf, gpa, u32, 0); // block prefix
    // NiNode body
    try w.int(&buf, gpa, u32, 4);
    try buf.appendSlice(gpa, "root");
    try w.int(&buf, gpa, u32, 0); // extra data count
    try w.int(&buf, gpa, i32, -1); // controller
    try w.int(&buf, gpa, u16, 0); // flags
    for ([_]f32{ 1, 2, 3, 1, 0, 0, 0, 1, 0, 0, 0, 1, 2 }) |f| try w.int(&buf, gpa, u32, @bitCast(f));
    try w.int(&buf, gpa, u32, 0); // properties
    try w.int(&buf, gpa, i32, -1); // collision
    try w.int(&buf, gpa, u32, 0); // children
    try w.int(&buf, gpa, u32, 0); // effects
    try w.int(&buf, gpa, u32, 1); // roots
    try w.int(&buf, gpa, i32, 0);

    var nif = try parse(gpa, buf.items);
    defer nif.deinit();
    try std.testing.expectEqual(@as(usize, 1), nif.blocks.len);
    const n = nif.blocks[0].node;
    try std.testing.expectEqualStrings("root", n.av.net.name);
    try std.testing.expectEqual(@as(f32, 2), n.av.transform.scale);
    try std.testing.expectEqual(@as(f32, 3), n.av.transform.translation[2]);
}
