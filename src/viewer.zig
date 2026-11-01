//! Static model viewer: flattens a NIF scene graph into draw calls and
//! renders it with OpenGL 3.3 under an orbit camera. Skinning and animation
//! are not applied yet; skinned meshes are drawn in their bind pose.

const std = @import("std");
const Gl = @import("gl.zig").Gl;
const gl = @import("gl.zig");
const nif = @import("nif.zig");
const dds = @import("dds.zig");
const model = @import("model.zig");
const terrain_mod = @import("terrain.zig");
const map_mod = @import("map.zig");
const entity = @import("entity.zig");
const font = @import("font.zig");
const environment = @import("environment.zig");
const bf = @import("bf.zig");
const vfs_mod = @import("vfs.zig");
const platform = @import("platform.zig");

// ------------------------------------------------------------------ math

pub const Mat4 = [16]f32; // column-major

pub const identity: Mat4 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var r: Mat4 = undefined;
    for (0..4) |col| for (0..4) |row| {
        var s: f32 = 0;
        for (0..4) |k| s += a[k * 4 + row] * b[col * 4 + k];
        r[col * 4 + row] = s;
    };
    return r;
}

/// The NIF stores a row-major rotation R; a point maps to `scale * R * p + t`.
pub fn fromTransform(t: nif.Transform) Mat4 {
    var m = identity;
    for (0..3) |col| for (0..3) |row| {
        m[col * 4 + row] = t.rotation[row * 3 + col] * t.scale;
    };
    m[12] = t.translation[0];
    m[13] = t.translation[1];
    m[14] = t.translation[2];
    return m;
}

fn transformPoint(m: Mat4, p: nif.Vec3) nif.Vec3 {
    return .{
        m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12],
        m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13],
        m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14],
    };
}

/// Rotation matrix for a unit quaternion (x, y, z, w), times `scale`,
/// written into the upper 3x3 of `m` (column-major).
fn setRotation(m: *Mat4, q: [4]f32, scale: f32) void {
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];
    const r = [9]f32{ // row-major
        1 - 2 * (y * y + z * z), 2 * (x * y - z * w),     2 * (x * z + y * w),
        2 * (x * y + z * w),     1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
        2 * (x * z - y * w),     2 * (y * z + x * w),     1 - 2 * (x * x + y * y),
    };
    for (0..3) |col| for (0..3) |row| {
        m[col * 4 + row] = r[row * 3 + col] * scale;
    };
}

fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(fovy / 2.0);
    var m = std.mem.zeroes(Mat4);
    m[0] = f / aspect;
    m[5] = f;
    m[10] = (far + near) / (near - far);
    m[11] = -1;
    m[14] = 2 * far * near / (near - far);
    return m;
}

fn normalize3(v: [3]f32) [3]f32 {
    const l = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (l == 0) return v;
    return .{ v[0] / l, v[1] / l, v[2] / l };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn lookAt(eye: [3]f32, target: [3]f32, up: [3]f32) Mat4 {
    const f = normalize3(.{ target[0] - eye[0], target[1] - eye[1], target[2] - eye[2] });
    const s = normalize3(cross(f, up));
    const u = cross(s, f);
    var m = identity;
    m[0] = s[0];
    m[4] = s[1];
    m[8] = s[2];
    m[1] = u[0];
    m[5] = u[1];
    m[9] = u[2];
    m[2] = -f[0];
    m[6] = -f[1];
    m[10] = -f[2];
    m[12] = -(s[0] * eye[0] + s[1] * eye[1] + s[2] * eye[2]);
    m[13] = -(u[0] * eye[0] + u[1] * eye[1] + u[2] * eye[2]);
    m[14] = (f[0] * eye[0] + f[1] * eye[1] + f[2] * eye[2]);
    return m;
}

// ---------------------------------------------------------------- shaders

const vs_src: [:0]const u8 =
    \\#version 330 core
    \\layout(location=0) in vec3 aPos;
    \\layout(location=1) in vec3 aNormal;
    \\layout(location=2) in vec2 aUv;
    \\layout(location=3) in vec4 aIdx;
    \\layout(location=4) in vec4 aWeight;
    \\layout(location=5) in vec2 aUv2;
    \\out vec2 vUv2;
    \\out vec4 vW;
    \\uniform mat4 uBones[96];
    \\uniform int uSkinned;
    \\uniform mat4 uModel;
    \\uniform mat4 uViewProj;
    \\out vec3 vN;
    \\out vec3 vP;
    \\out vec2 vUv;
    \\void main() {
    \\  mat4 m = uModel;
    \\  if (uSkinned == 1) {
    \\    m = aWeight.x * uBones[int(aIdx.x)] + aWeight.y * uBones[int(aIdx.y)]
    \\      + aWeight.z * uBones[int(aIdx.z)] + aWeight.w * uBones[int(aIdx.w)];
    \\  }
    \\  vec4 w = m * vec4(aPos, 1.0);
    \\  vP = w.xyz;
    \\  vN = mat3(m) * aNormal;
    \\  vUv = aUv;
    \\  vUv2 = aUv2;
    \\  vW = aWeight;
    \\  gl_Position = uViewProj * w;
    \\}
;

const fs_src: [:0]const u8 =
    \\#version 330 core
    \\in vec3 vN;
    \\in vec3 vP;
    \\in vec2 vUv;
    \\in vec2 vUv2;
    \\in vec4 vW;
    \\uniform sampler2D uFlat1;
    \\uniform sampler2D uFlat2;
    \\uniform sampler2D uFlat3;
    \\uniform sampler2D uDecal;
    \\uniform int uDecalMode; // 0 none, 1 decal on uv set 0, 2 decal on uv set 1
    \\uniform sampler2D uTex;
    \\uniform sampler2D uTex2;
    \\uniform int uTerrain;
    \\uniform int uLightSet;      // 0 terrain and ground decals, 1 objects
    \\uniform vec3 uAmb[2];
    \\uniform vec3 uLdir[6];
    \\uniform vec3 uLcol[6];
    \\uniform vec3 uFogColor;
    \\uniform vec2 uFogRange;
    \\uniform vec3 uEye;
    \\uniform vec4 uTint;
    \\uniform float uAlphaCut;
    \\out vec4 outColor;
    \\void main() {
    \\  vec3 n = dot(vN, vN) > 1e-6 ? normalize(vN) : normalize(cross(dFdx(vP), dFdy(vP)));
    \\  vec4 c = texture(uTex, vUv) * uTint;
    \\  if (uDecalMode != 0) {
    \\    vec4 d = texture(uDecal, uDecalMode == 2 ? vUv2 : vUv);
    \\    c.rgb = mix(c.rgb, d.rgb, d.a);
    \\  }
    \\  if (uTerrain == 1) {
    \\    // Flat ground shows the cover texture, steep slopes the cliff texture.
    \\    float steep = smoothstep(0.2, 0.5, 1.0 - n.z);
    \\    vec4 flat_c = c * vW.x + texture(uFlat1, vUv) * vW.y + texture(uFlat2, vUv) * vW.z + texture(uFlat3, vUv) * vW.w;
    \\    c = mix(flat_c, texture(uTex2, vUv * 0.5), steep);
    \\  }
    \\  if (c.a < uAlphaCut) discard;
    \\  // Two-sided lighting: flip the normal towards the viewer.
    \\  vec3 toEye = uEye - vP;
    \\  if (dot(n, toEye) < 0.0) n = -n;
    \\  vec3 lit = uAmb[uLightSet];
    \\  for (int i = 0; i < 3; i++) {
    \\    lit += uLcol[uLightSet * 3 + i] * max(dot(n, -uLdir[uLightSet * 3 + i]), 0.0);
    \\  }
    \\  float fogF = clamp((length(toEye) - uFogRange.x) / max(uFogRange.y - uFogRange.x, 1.0), 0.0, 1.0);
    \\  outColor = vec4(mix(c.rgb * lit, uFogColor, fogF), c.a);
    \\}
;

fn compile(g: *const Gl, kind: gl.Enum, src: [:0]const u8) !gl.Uint {
    const sh = g.createShader(kind);
    const srcs = [_][*:0]const u8{src.ptr};
    g.shaderSource(sh, 1, &srcs, null);
    g.compileShader(sh);
    var ok: gl.Int = 0;
    g.getShaderiv(sh, gl.COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log: [1024]u8 = undefined;
        var n: gl.Sizei = 0;
        g.getShaderInfoLog(sh, log.len, &n, &log);
        std.debug.print("shader error: {s}\n", .{log[0..@intCast(n)]});
        return error.ShaderCompile;
    }
    return sh;
}

fn makeProgram(g: *const Gl) !gl.Uint {
    return makeProgramFrom(g, vs_src, fs_src);
}

fn makeProgramFrom(g: *const Gl, vs_text: [:0]const u8, fs_text: [:0]const u8) !gl.Uint {
    const vs = try compile(g, gl.VERTEX_SHADER, vs_text);
    const fs = try compile(g, gl.FRAGMENT_SHADER, fs_text);
    const p = g.createProgram();
    g.attachShader(p, vs);
    g.attachShader(p, fs);
    g.linkProgram(p);
    var ok: gl.Int = 0;
    g.getProgramiv(p, gl.LINK_STATUS, &ok);
    if (ok == 0) {
        var log: [1024]u8 = undefined;
        var n: gl.Sizei = 0;
        g.getProgramInfoLog(p, log.len, &n, &log);
        std.debug.print("link error: {s}\n", .{log[0..@intCast(n)]});
        return error.ShaderLink;
    }
    g.deleteShader(vs);
    g.deleteShader(fs);
    return p;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn poseWorld(world: []Mat4, nf: *const nif.Nif, root: Mat4, anim: ?*const bf.Animation, t: f32) void {
    for (nf.roots) |r| poseNode(world, nf, r, root, anim, t, false);
}

/// Like `poseWorld`, but also positions every level of detail of LOD nodes.
fn poseWorldAllLods(world: []Mat4, nf: *const nif.Nif, root: Mat4) void {
    for (nf.roots) |r| poseNode(world, nf, r, root, null, 0, true);
}

fn poseNode(world: []Mat4, nf: *const nif.Nif, ref: nif.Ref, parent: Mat4, anim: ?*const bf.Animation, t: f32, all_lods: bool) void {
    if (ref < 0) return;
    const idx: usize = @intCast(ref);
    switch (nf.blocks[idx]) {
        .node => |n| {
            if (n.av.flags & 1 != 0) return; // hidden
            var local = fromTransform(n.av.transform);
            if (anim) |an| if (an.bone(n.av.net.name)) |bone| {
                if (bf.sampleRot(bone, t)) |q| setRotation(&local, q, n.av.transform.scale);
                if (bf.samplePos(bone, t)) |p| {
                    local[12] = p[0];
                    local[13] = p[1];
                    local[14] = p[2];
                }
            };
            const w = mul(parent, local);
            world[idx] = w;
            if (n.kind == .lod) {
                // Child 0 is the most detailed level.
                if (all_lods) {
                    for (n.children) |c| poseNode(world, nf, c, w, anim, t, true);
                } else if (n.children.len > 0) poseNode(world, nf, n.children[0], w, anim, t, false);
                return;
            }
            for (n.children) |c| poseNode(world, nf, c, w, anim, t, all_lods);
        },
        .geometry => |geo| world[idx] = mul(parent, fromTransform(geo.av.transform)),
        else => {},
    }
}

const sky_vs: [:0]const u8 =
    \\#version 330 core
    \\layout(location=0) in vec3 aPos;
    \\layout(location=1) in vec3 aColor;
    \\uniform mat4 uVP;
    \\uniform vec3 uEye;
    \\uniform float uScale;
    \\out vec3 vColor;
    \\out vec3 vDir;
    \\void main() {
    \\  vColor = aColor;
    \\  vDir = aPos;
    \\  gl_Position = uVP * vec4(aPos * uScale + uEye, 1.0);
    \\}
;

const sky_fs: [:0]const u8 =
    \\#version 330 core
    \\in vec3 vColor;
    \\in vec3 vDir;
    \\uniform vec3 uSunDir;   // unit vector towards the sun (or moon)
    \\uniform vec3 uSunCol;
    \\out vec4 outColor;
    \\void main() {
    \\  vec3 d = normalize(vDir);
    \\  float s = dot(d, uSunDir);
    \\  float disc = smoothstep(0.9988, 0.9994, s);
    \\  float glow = pow(max(s, 0.0), 48.0) * 0.45;
    \\  vec3 col = vColor + uSunCol * (disc + glow);
    \\  outColor = vec4(col, 1.0);
    \\}
;

const ui_vs: [:0]const u8 =
    \\#version 330 core
    \\layout(location=0) in vec2 aPos;
    \\layout(location=1) in vec2 aUv;
    \\layout(location=2) in vec4 aColor;
    \\uniform vec2 uScreen;
    \\out vec2 vUv;
    \\out vec4 vColor;
    \\void main() {
    \\  vUv = aUv;
    \\  vColor = aColor;
    \\  gl_Position = vec4(aPos.x / uScreen.x * 2.0 - 1.0, 1.0 - aPos.y / uScreen.y * 2.0, 0.0, 1.0);
    \\}
;

const ui_fs: [:0]const u8 =
    \\#version 330 core
    \\in vec2 vUv;
    \\in vec4 vColor;
    \\uniform sampler2D uAtlas;
    \\out vec4 outColor;
    \\void main() {
    \\  outColor = vec4(vColor.rgb, vColor.a * texture(uAtlas, vUv).a);
    \\}
;

/// Builds a frame's 2D overlay: rectangles and text in pixel coordinates
/// (origin top-left). Filled by a hook's `overlay`, drawn after the scene.
pub const Ui = struct {
    gpa: std.mem.Allocator,
    /// Per vertex: x, y, u, v, r, g, b, a.
    verts: std.ArrayList(f32) = .empty,
    /// Pixel size of the viewport.
    width: f32 = 1,
    height: f32 = 1,

    pub fn deinit(self: *Ui) void {
        self.verts.deinit(self.gpa);
    }

    fn quad(self: *Ui, x: f32, y: f32, w: f32, h: f32, ua: f32, va: f32, ub: f32, vb: f32, c: [4]f32) !void {
        const v = [_][8]f32{
            .{ x, y, ua, va, c[0], c[1], c[2], c[3] },
            .{ x + w, y, ub, va, c[0], c[1], c[2], c[3] },
            .{ x + w, y + h, ub, vb, c[0], c[1], c[2], c[3] },
            .{ x, y, ua, va, c[0], c[1], c[2], c[3] },
            .{ x + w, y + h, ub, vb, c[0], c[1], c[2], c[3] },
            .{ x, y + h, ua, vb, c[0], c[1], c[2], c[3] },
        };
        for (v) |vert| try self.verts.appendSlice(self.gpa, &vert);
    }

    pub fn rect(self: *Ui, x: f32, y: f32, w: f32, h: f32, color: [4]f32) !void {
        const sx: f32 = @floatFromInt((font.solid_cell % font.cols) * font.cell + font.cell / 2);
        const sy: f32 = @floatFromInt((font.solid_cell / font.cols) * font.cell + font.cell / 2);
        const u = sx / font.atlas_w;
        const v = sy / font.atlas_h;
        try self.quad(x, y, w, h, u, v, u, v, color);
    }

    pub fn textWidth(str: []const u8, scale: f32) f32 {
        return @as(f32, @floatFromInt(str.len)) * 6 * scale;
    }

    /// Draws `text` with its top-left at (x, y); returns the width drawn.
    pub fn text(self: *Ui, x: f32, y: f32, scale: f32, str: []const u8, color: [4]f32) !f32 {
        var cx = x;
        for (str) |ch| {
            if (ch != ' ') {
                const ci = font.cellFor(ch);
                const gx: f32 = @floatFromInt((ci % font.cols) * font.cell);
                const gy: f32 = @floatFromInt((ci / font.cols) * font.cell);
                try self.quad(cx, y, 5 * scale, 7 * scale, gx / font.atlas_w, gy / font.atlas_h, (gx + 5) / font.atlas_w, (gy + 7) / font.atlas_h, color);
            }
            cx += 6 * scale;
        }
        return cx - x;
    }

    /// Text on a translucent background.
    pub fn label(self: *Ui, x: f32, y: f32, scale: f32, str: []const u8, color: [4]f32) !void {
        const pad = 2 * scale;
        try self.rect(x - pad, y - pad, textWidth(str, scale) + pad * 2 - scale, 7 * scale + pad * 2, .{ 0, 0, 0, 0.55 });
        _ = try self.text(x, y, scale, str, color);
    }
};

// ------------------------------------------------------------------ scene

const max_bones = 96;
/// Floats per vertex: position 3, normal 3, uv 2, bone indices 4, bone weights 4, second uv 2.
const vf = 18;

pub const FencePieces = struct {
    post: ?[]const Draw = null,
    segment: ?[]const Draw = null,
};

const Skin = struct {
    /// NIF block index of each bone node.
    bones: []const u32,
    /// Geometry space -> bone space, per bone.
    offsets: []const Mat4,
};

fn dist_far_for(cam: Camera) f32 {
    return cam.dist + cam.radius * 10;
}

/// Plain lighting for scenes without an environment.
pub fn defaultLighting() environment.Sample {
    return .{
        .ambient = .{ .{ 0.4, 0.4, 0.4 }, .{ 0.4, 0.4, 0.4 } },
        .dir = .{
            .{ .{ -0.4, 0.5, -0.8 }, .{ 0, 0, -1 }, .{ 0, 0, -1 } },
            .{ .{ -0.4, 0.5, -0.8 }, .{ 0, 0, -1 }, .{ 0, 0, -1 } },
        },
        .color = .{
            .{ .{ 0.6, 0.6, 0.6 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } },
            .{ .{ 0.6, 0.6, 0.6 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } },
        },
        .fog_color = .{ 0.6, 0.7, 0.8 },
        .fog_start = 0,
        .fog_end = 1000,
    };
}

pub const Draw = struct {
    /// Which light set shades this draw: 0 terrain and ground decals, 1 objects.
    light_set: i32 = 1,
    /// Camera distances (near, far) between which this draw is shown, for
    /// models with levels of detail.
    lod_range: [2]f32 = .{ 0, std.math.inf(f32) },
    /// Bounding sphere (x, y, z, radius). In a cached model's draws it is in
    /// model space; `place` turns it into world space. A negative radius
    /// means "never cull".
    bound: [4]f32 = .{ 0, 0, 0, -1 },
    /// When set, the draw is carried by this node of its instance's skeleton:
    /// its model matrix is that node's world matrix times `world`.
    attach_node: ?u32 = null,
    /// Vertex and index buffers this draw owns (deleted when it is dropped);
    /// zero for draws that share a cached model's buffers.
    owned: [2]gl.Uint = .{ 0, 0 },
    /// Decal layer texture (0 = none) and which UV set it uses (1 or 2).
    decal: gl.Uint = 0,
    decal_mode: i32 = 0,
    /// Names used to match per-entity texture swaps (owned by the scene arena).
    mat_name: []const u8 = "",
    base_name: []const u8 = "",
    decal_name: []const u8 = "",
    /// Index into `Scene.instances` whose world matrices this draw uses.
    inst: ?u32 = null,
    /// Decals blend over what is behind them without writing depth.
    depth_write: bool = true,
    /// Further biome ground textures for terrain, bound to units 3 to 5.
    flat_extra: [3]gl.Uint = .{ 0, 0, 0 },
    /// Second texture for terrain (steep slopes); 0 for ordinary draws.
    texture2: gl.Uint = 0,
    /// Pose-driven draws read `Scene.world[block]` each frame; others use `world`.
    dynamic: bool,
    index_type: gl.Enum,
    block: u32,
    skin: ?Skin,
    vao: gl.Uint,
    index_count: gl.Sizei,
    world: Mat4,
    texture: gl.Uint,
    tint: [4]f32,
    blend: bool,
    alpha_cut: f32,
};

/// A person's head model and how it is turned relative to the neck node.
pub const ActorHead = struct {
    model: []const u8,
    yaw: f32 = 0,
    swaps: []const map_mod.Swap = &.{},
};

pub fn rotationZ(yaw: f32) Mat4 {
    return fromTransform(.{ .translation = .{ 0, 0, 0 }, .rotation = .{ @cos(yaw), -@sin(yaw), 0, @sin(yaw), @cos(yaw), 0, 0, 0, 1 }, .scale = 1 });
}

/// A sky dome whose vertex colours are blended between time-of-day models.
pub const SkyDome = struct {
    vao: gl.Uint,
    col_vbo: gl.Uint,
    index_count: gl.Sizei,
    /// `keys[k]` holds the 3 floats of colour per vertex for keyframe k.
    keys: [][]f32,
    times: []f32,
    scratch: []f32,

    fn deinit(self: *SkyDome, gpa: std.mem.Allocator) void {
        for (self.keys) |k| gpa.free(k);
        gpa.free(self.keys);
        gpa.free(self.times);
        gpa.free(self.scratch);
    }

    /// Blends the keyframes for `tod` and uploads the colours.
    fn update(self: *SkyDome, g: *const Gl, tod: f32) void {
        const b = environment.skyBlend(self.times, tod);
        const a = self.keys[@min(b.i, self.keys.len - 1)];
        const c = self.keys[@min(b.j, self.keys.len - 1)];
        for (self.scratch, a, c) |*out, x, y| out.* = x + (y - x) * b.f;
        g.bindBuffer(gl.ARRAY_BUFFER, self.col_vbo);
        g.bufferSubData(gl.ARRAY_BUFFER, 0, @intCast(self.scratch.len * 4), self.scratch.ptr);
    }
};

/// An animated figure: its own copy of the node transforms.
pub const Instance = struct {
    nf: *const nif.Nif,
    world: []Mat4,
    root: Mat4,
    anim: ?*const bf.Animation,
    /// Seconds added to the clock so figures are not in lockstep.
    phase: f32,
    /// When driven by the simulation, `time` is the animation clock.
    driven: bool = false,
    time: f32 = 0,
    /// The template's manifest, for looking animations up by name.
    manifest: ?*const model.Manifest = null,
};

const ActorTemplate = struct {
    /// Index of the `Link_Head` node, where a person's head attaches.
    head_node: ?u32 = null,
    nf: *nif.Nif,
    draws: []const Draw,
    manifest: ?model.Manifest,
};

pub const Scene = struct {
    gpa: std.mem.Allocator,
    g: *const Gl,
    vfs: *vfs_mod.Vfs,
    draws: std.ArrayList(Draw) = .empty,
    /// lowercase basename -> VFS path of a .dds file
    dds_index: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// lowercase basename -> GL texture
    textures: std.StringHashMapUnmanaged(gl.Uint) = .empty,
    white: gl.Uint = 0,
    min: nif.Vec3 = .{ 1e30, 1e30, 1e30 },
    max: nif.Vec3 = .{ -1e30, -1e30, -1e30 },
    missing_textures: u32 = 0,
    /// World matrix of every node/geometry block, refreshed by `pose`.
    world: []Mat4 = &.{},
    arena: std.heap.ArenaAllocator,
    /// Single-model viewing: poses and skinning follow the animation, and the
    /// camera frames the model's bounds. Map mode turns all of these off.
    interactive: bool = true,
    /// Build skin tables / pose-driven draws (single-model viewing and actors).
    want_skin: bool = true,
    dynamic_draws: bool = true,
    /// Animated figures placed in a map, each with its own skeleton pose.
    instances: std.ArrayList(Instance) = .empty,
    /// Terrain mesh, drawn first and rebuilt when heights change.
    terrain: ?Draw = null,
    /// Draws of animated figures (each refers to an entry of `instances`).
    actor_draws: std.ArrayList(Draw) = .empty,
    /// Translucent extras drawn last: previews, highlights.
    overlay: std.ArrayList(Draw) = .empty,
    /// Per model path: horizontal radius and height from its vertices.
    model_bounds: std.StringHashMapUnmanaged([2]f32) = .empty,
    build_r: f32 = 0,
    build_h: f32 = 0,
    /// While building placed models: keep every LOD level, tagged by range.
    lod_all: bool = false,
    /// Light, fog and sky for the current time of day.
    lighting: ?environment.Sample = null,
    sky: ?SkyDome = null,
    /// Time of day, 0..1, used for the sky colours.
    tod: f32 = 0.42,
    fog_scale: f32 = 800.0,
    cur_lod: [2]f32 = .{ 0, std.math.inf(f32) },
    /// Multiplies LOD distances: the data's ranges are tuned for the
    /// original game's closer camera.
    lod_bias: f32 = 3.0,
    actor_models: std.StringHashMapUnmanaged(?*ActorTemplate) = .empty,
    anim_cache: std.StringHashMapUnmanaged(?*bf.Animation) = .empty,
    /// Loaded models by lowercase path, as draws relative to the model origin.
    models: std.StringHashMapUnmanaged(?[]const Draw) = .empty,
    fence_cache: std.StringHashMapUnmanaged(FencePieces) = .empty,

    const Index = struct {
        scene: *Scene,
        fn add(self: Index, path: []const u8) anyerror!void {
            if (!std.mem.endsWith(u8, path, ".dds")) return;
            const base = std.fs.path.basename(path);
            const s = self.scene;
            const gop = try s.dds_index.getOrPut(s.gpa, base);
            // Prefer full-resolution textures over those under a `low/` dir.
            if (gop.found_existing) {
                const old_low = std.mem.indexOf(u8, gop.value_ptr.*, "/low/") != null;
                const new_low = std.mem.indexOf(u8, path, "/low/") != null;
                if (!old_low or new_low) return;
            }
            gop.key_ptr.* = base;
            gop.value_ptr.* = path;
        }
    };

    pub fn init(gpa: std.mem.Allocator, g: *const Gl, vfs: *vfs_mod.Vfs) !Scene {
        var s: Scene = .{ .gpa = gpa, .g = g, .vfs = vfs, .arena = .init(gpa) };
        try vfs.forEach(Index{ .scene = &s }, Index.add);
        // 1x1 white fallback texture.
        const px = [4]u8{ 255, 255, 255, 255 };
        g.genTextures(1, @ptrCast(&s.white));
        g.bindTexture(gl.TEXTURE_2D, s.white);
        g.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
        g.texImage2D(gl.TEXTURE_2D, 0, @intCast(gl.RGBA8), 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, &px);
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, @intCast(gl.LINEAR));
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, @intCast(gl.LINEAR));
        return s;
    }

    pub fn deinit(self: *Scene) void {
        self.draws.deinit(self.gpa);
        self.gpa.free(self.world);
        if (self.sky) |*sk| sk.deinit(self.gpa);
        self.actor_draws.deinit(self.gpa);
        self.overlay.deinit(self.gpa);
        var bit = self.model_bounds.keyIterator();
        while (bit.next()) |k| self.gpa.free(k.*);
        self.model_bounds.deinit(self.gpa);
        for (self.instances.items) |i| self.gpa.free(i.world);
        self.instances.deinit(self.gpa);
        var ait = self.actor_models.iterator();
        while (ait.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |t| {
                self.gpa.free(t.draws);
                if (t.manifest) |*m| m.deinit();
                t.nf.deinit();
                self.gpa.destroy(t.nf);
                self.gpa.destroy(t);
            }
        }
        self.actor_models.deinit(self.gpa);
        var nit = self.anim_cache.iterator();
        while (nit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |an| {
                an.deinit();
                self.gpa.destroy(an);
            }
        }
        self.anim_cache.deinit(self.gpa);
        self.arena.deinit();
        var mit = self.models.iterator();
        while (mit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |d| self.gpa.free(d);
        }
        self.models.deinit(self.gpa);
        var fit = self.fence_cache.keyIterator();
        while (fit.next()) |k| self.gpa.free(k.*);
        self.fence_cache.deinit(self.gpa);
        var it = self.textures.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.textures.deinit(self.gpa);
        self.dds_index.deinit(self.gpa);
    }

    fn loadTexture(self: *Scene, file_name: []const u8) gl.Uint {
        var lower_buf: [256]u8 = undefined;
        var name = file_name;
        if (std.mem.lastIndexOfAny(u8, name, "/\\")) |i| name = name[i + 1 ..];
        if (name.len == 0 or name.len > lower_buf.len) return self.white;
        const lower = std.ascii.lowerString(&lower_buf, name);
        if (self.textures.get(lower)) |t| return t;

        const tex = self.loadTextureUncached(lower) orelse blk: {
            self.missing_textures += 1;
            break :blk self.white;
        };
        const key = self.gpa.dupe(u8, lower) catch return tex;
        self.textures.put(self.gpa, key, tex) catch self.gpa.free(key);
        return tex;
    }

    fn loadTextureUncached(self: *Scene, lower: []const u8) ?gl.Uint {
        const path = self.dds_index.get(lower) orelse return null;
        const bytes = self.vfs.read(self.gpa, path) catch return null;
        defer self.gpa.free(bytes);
        var img = dds.parse(self.gpa, bytes) catch return null;
        defer img.deinit();
        return upload(self.g, &img);
    }

    fn upload(g: *const Gl, img: *const dds.Image) gl.Uint {
        var id: gl.Uint = 0;
        g.genTextures(1, @ptrCast(&id));
        g.bindTexture(gl.TEXTURE_2D, id);
        g.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
        for (0..img.mip_count) |m| {
            const lvl = img.level(0, @intCast(m));
            const data = img.levelData(0, @intCast(m));
            const w: gl.Sizei = @intCast(lvl.width);
            const h: gl.Sizei = @intCast(lvl.height);
            switch (img.format) {
                .dxt1 => g.compressedTexImage2D(gl.TEXTURE_2D, @intCast(m), gl.COMPRESSED_RGBA_S3TC_DXT1_EXT, w, h, 0, @intCast(data.len), data.ptr),
                .dxt3 => g.compressedTexImage2D(gl.TEXTURE_2D, @intCast(m), gl.COMPRESSED_RGBA_S3TC_DXT3_EXT, w, h, 0, @intCast(data.len), data.ptr),
                .dxt5 => g.compressedTexImage2D(gl.TEXTURE_2D, @intCast(m), gl.COMPRESSED_RGBA_S3TC_DXT5_EXT, w, h, 0, @intCast(data.len), data.ptr),
                .rgba8 => g.texImage2D(gl.TEXTURE_2D, @intCast(m), @intCast(gl.RGBA8), w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, data.ptr),
            }
        }
        // Only use mips when the chain reaches 1x1; otherwise the texture
        // would be incomplete (some game textures ship truncated chains).
        const last = img.level(0, img.mip_count - 1);
        const complete = img.mip_count > 1 and last.width <= 1 and last.height <= 1;
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAX_LEVEL, if (complete) @intCast(img.mip_count - 1) else 0);
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, @intCast(if (complete) gl.LINEAR_MIPMAP_LINEAR else gl.LINEAR));
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, @intCast(gl.LINEAR));
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, @intCast(gl.REPEAT));
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, @intCast(gl.REPEAT));
        return id;
    }

    /// Walks the scene graph from every root, adding a draw per geometry.
    pub fn addNif(self: *Scene, nf: *const nif.Nif) !void {
        self.world = try self.gpa.alloc(Mat4, nf.blocks.len);
        @memset(self.world, identity);
        self.pose(nf, null, 0);
        for (nf.roots) |r| try self.walk(nf, r);
    }

    /// Recomputes every node's world matrix, with bone transforms taken from
    /// `anim` at time `t` where it has tracks for them.
    pub fn pose(self: *Scene, nf: *const nif.Nif, anim: ?*const bf.Animation, t: f32) void {
        poseWorld(self.world, nf, identity, anim, t);
    }

    /// Advances every instance's animation to the clock `secs`.
    pub fn poseInstances(self: *Scene, secs: f32) void {
        for (self.instances.items) |inst| {
            var t: f32 = 0;
            if (inst.anim) |an| if (an.duration > 0) {
                t = @mod((if (inst.driven) inst.time else secs + inst.phase), an.duration);
            };
            poseWorld(inst.world, inst.nf, inst.root, inst.anim, t);
        }
    }

    fn walk(self: *Scene, nf: *const nif.Nif, ref: nif.Ref) !void {
        return self.walkLod(nf, ref, .{ 0, std.math.inf(f32) });
    }

    /// Visits the scene graph. With `lod_all` (placed models) every level of
    /// detail is built and tagged with the distances it is shown at;
    /// otherwise only the most detailed child of a LOD node is used.
    fn walkLod(self: *Scene, nf: *const nif.Nif, ref: nif.Ref, lod: [2]f32) !void {
        if (ref < 0) return;
        switch (nf.blocks[@intCast(ref)]) {
            .node => |n| {
                if (n.av.flags & 1 != 0) return; // hidden
                if (n.kind == .lod) {
                    if (self.lod_all and n.lod_ranges.len > 0) {
                        for (n.children, 0..) |c, i| {
                            const r = n.lod_ranges[@min(i, n.lod_ranges.len - 1)];
                            try self.walkLod(nf, c, .{ @max(lod[0], r[0]), @min(lod[1], r[1]) });
                        }
                    } else if (n.children.len > 0) try self.walkLod(nf, n.children[0], lod);
                    return;
                }
                for (n.children) |c| try self.walkLod(nf, c, lod);
            },
            .geometry => |geo| {
                if (geo.av.flags & 1 != 0) return;
                self.cur_lod = lod;
                try self.addGeometry(nf, geo, @intCast(ref));
            },
            else => {},
        }
    }

    fn addGeometry(self: *Scene, nf: *const nif.Nif, geo: nif.Geometry, block: u32) !void {
        const world = self.world[block];
        if (geo.data < 0) return;
        const md = switch (nf.blocks[@intCast(geo.data)]) {
            .mesh_data => |m| m,
            else => return,
        };
        if (md.indices.len == 0 or md.vertices.len == 0) return;

        var tex = self.white;
        var tint = [4]f32{ 1, 1, 1, 1 };
        var blend = false;
        var alpha_cut: f32 = 0;
        var decal: gl.Uint = 0;
        var decal_mode: i32 = 0;
        var mat_name: []const u8 = "";
        var base_name: []const u8 = "";
        var decal_name: []const u8 = "";
        const sa = self.arena.allocator();
        for (geo.av.properties) |pr| {
            if (pr < 0) continue;
            switch (nf.blocks[@intCast(pr)]) {
                .texturing => |t| {
                    if (t.base) |bt| if (bt.source >= 0) switch (nf.blocks[@intCast(bt.source)]) {
                        .source_texture => |st| if (st.file_name) |fnm| {
                            tex = self.loadTexture(fnm);
                            base_name = try sa.dupe(u8, fnm);
                        },
                        else => {},
                    };
                    if (t.decals[0]) |dt| if (dt.source >= 0) switch (nf.blocks[@intCast(dt.source)]) {
                        .source_texture => |st| if (st.file_name) |fnm| {
                            decal = self.loadTexture(fnm);
                            decal_mode = if (dt.uv_set == 0) 1 else 2;
                            decal_name = try sa.dupe(u8, fnm);
                        },
                        else => {},
                    };
                },
                .material => |m| {
                    tint = .{ m.diffuse[0], m.diffuse[1], m.diffuse[2], m.alpha };
                    mat_name = try sa.dupe(u8, m.net.name);
                },
                .alpha => |a| {
                    if (a.flags & 1 != 0) blend = true;
                    if (a.flags & 0x200 != 0) alpha_cut = @as(f32, @floatFromInt(a.threshold)) / 255.0;
                },
                else => {},
            }
        }

        // Interleave position, normal, uv.
        const n = md.vertices.len;
        const buf = try self.gpa.alloc(f32, n * vf);
        @memset(buf, 0);
        defer self.gpa.free(buf);
        const have_n = md.normals.len == n;
        const have_uv = md.uv_sets.len > 0 and md.uv_sets[0].len == n;
        const have_uv2 = md.uv_sets.len > 1 and md.uv_sets[1].len == n;
        var gmin = [3]f32{ 1e30, 1e30, 1e30 };
        var gmax = [3]f32{ -1e30, -1e30, -1e30 };
        for (0..n) |i| {
            const v = md.vertices[i];
            for (0..3) |k| {
                gmin[k] = @min(gmin[k], v[k]);
                gmax[k] = @max(gmax[k], v[k]);
            }
            buf[i * vf + 0] = v[0];
            buf[i * vf + 1] = v[1];
            buf[i * vf + 2] = v[2];
            const nr: nif.Vec3 = if (have_n) md.normals[i] else .{ 0, 0, 0 };
            buf[i * vf + 3] = nr[0];
            buf[i * vf + 4] = nr[1];
            buf[i * vf + 5] = nr[2];
            const uv: [2]f32 = if (have_uv) md.uv_sets[0][i] else .{ 0, 0 };
            buf[i * vf + 6] = uv[0];
            buf[i * vf + 7] = uv[1];
            const uv2: [2]f32 = if (have_uv2) md.uv_sets[1][i] else uv;
            buf[i * vf + 16] = uv2[0];
            buf[i * vf + 17] = uv2[1];
            const wp = transformPoint(world, v);
            if (self.interactive) {
                for (0..3) |k| {
                    self.min[k] = @min(self.min[k], wp[k]);
                    self.max[k] = @max(self.max[k], wp[k]);
                }
            }
            self.build_r = @max(self.build_r, @sqrt(wp[0] * wp[0] + wp[1] * wp[1]));
            self.build_h = @max(self.build_h, wp[2]);
        }

        const skin = if (self.want_skin) try self.buildSkin(nf, geo, buf, n) else null;

        const vao = self.uploadMesh(buf, md.indices.ptr, md.indices.len * 2);

        try self.draws.append(self.gpa, .{
            .dynamic = self.dynamic_draws,
            .index_type = gl.UNSIGNED_SHORT,
            .block = block,
            .skin = skin,
            .vao = vao,
            .index_count = @intCast(md.indices.len),
            .world = world,
            .bound = blk: {
                // Sphere around the box, in the draw's own (world) space.
                const c = [3]f32{ (gmin[0] + gmax[0]) / 2, (gmin[1] + gmax[1]) / 2, (gmin[2] + gmax[2]) / 2 };
                const half = [3]f32{ (gmax[0] - gmin[0]) / 2, (gmax[1] - gmin[1]) / 2, (gmax[2] - gmin[2]) / 2 };
                const wc = transformPoint(world, c);
                const sc = @sqrt(world[0] * world[0] + world[1] * world[1] + world[2] * world[2]);
                // Skinned meshes move with their bones; never cull them.
                const r: f32 = if (skin != null) -1 else @sqrt(half[0] * half[0] + half[1] * half[1] + half[2] * half[2]) * sc;
                break :blk .{ wc[0], wc[1], wc[2], r };
            },
            .lod_range = self.cur_lod,
            .texture = tex,
            .decal = decal,
            .decal_mode = decal_mode,
            .mat_name = mat_name,
            .base_name = base_name,
            .decal_name = decal_name,
            .tint = tint,
            .blend = blend,
            .alpha_cut = alpha_cut,
        });
    }

    /// The texture name without directory, extension or its last `_` part:
    /// `guest_adult_m_pants_02.dds` -> `guest_adult_m_pants`.
    fn textureFamily(name: []const u8) []const u8 {
        var base = name;
        if (std.mem.lastIndexOfAny(u8, base, "/\\")) |i| base = base[i + 1 ..];
        if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| base = base[0..i];
        if (std.mem.lastIndexOfScalar(u8, base, '_')) |i| base = base[0..i];
        return base;
    }

    /// Applies saved per-entity texture swaps: a swap replaces the layer's
    /// texture on meshes whose current texture is in the same family.
    fn applySwaps(self: *Scene, d: *Draw, swaps: []const map_mod.Swap) void {
        for (swaps) |sw| {
            const is_decal = std.mem.startsWith(u8, sw.layer, "decal");
            const current = if (is_decal) d.decal_name else d.base_name;
            if (current.len == 0) continue;
            if (!std.ascii.eqlIgnoreCase(textureFamily(current), textureFamily(sw.image))) continue;
            const tex = self.loadTexture(sw.image);
            if (is_decal) d.decal = tex else d.texture = tex;
            return;
        }
    }

    /// Uploads interleaved vertices (16 floats each: position, normal, uv,
    /// bone indices, bone weights) and an index buffer; returns the vertex array.
    fn uploadMesh(self: *Scene, buf: []const f32, indices: *const anyopaque, index_bytes: usize) gl.Uint {
        return self.uploadMeshOwned(buf, indices, index_bytes).vao;
    }

    fn uploadMeshOwned(self: *Scene, buf: []const f32, indices: *const anyopaque, index_bytes: usize) struct { vao: gl.Uint, bufs: [2]gl.Uint } {
        const g = self.g;
        var vao: gl.Uint = 0;
        var bufs: [2]gl.Uint = undefined;
        g.genVertexArrays(1, @ptrCast(&vao));
        g.bindVertexArray(vao);
        g.genBuffers(2, &bufs);
        g.bindBuffer(gl.ARRAY_BUFFER, bufs[0]);
        g.bufferData(gl.ARRAY_BUFFER, @intCast(buf.len * 4), buf.ptr, gl.STATIC_DRAW);
        const stride: gl.Sizei = vf * 4;
        g.enableVertexAttribArray(0);
        g.vertexAttribPointer(0, 3, gl.FLOAT, 0, stride, @ptrFromInt(0));
        g.enableVertexAttribArray(1);
        g.vertexAttribPointer(1, 3, gl.FLOAT, 0, stride, @ptrFromInt(12));
        g.enableVertexAttribArray(2);
        g.vertexAttribPointer(2, 2, gl.FLOAT, 0, stride, @ptrFromInt(24));
        g.enableVertexAttribArray(3);
        g.vertexAttribPointer(3, 4, gl.FLOAT, 0, stride, @ptrFromInt(32));
        g.enableVertexAttribArray(4);
        g.vertexAttribPointer(4, 4, gl.FLOAT, 0, stride, @ptrFromInt(48));
        g.enableVertexAttribArray(5);
        g.vertexAttribPointer(5, 2, gl.FLOAT, 0, stride, @ptrFromInt(64));
        g.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, bufs[1]);
        g.bufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(index_bytes), indices, gl.STATIC_DRAW);
        g.bindVertexArray(0);
        return .{ .vao = vao, .bufs = bufs };
    }

    fn freeDraw(self: *Scene, d: Draw) void {
        if (d.owned[0] == 0) return;
        self.g.deleteBuffers(2, &d.owned);
        self.g.deleteVertexArrays(1, @ptrCast(&d.vao));
    }

    /// Loads the sky dome from the generic time-of-day models. `times` are
    /// the keyframe times from the environment (seven expected; defaults are
    /// used otherwise). Missing files leave the scene without a sky.
    pub fn loadSky(self: *Scene, times: []const f32) !void {
        const names = [_][]const u8{ "night", "sunrise", "midmorning", "noon", "afternoon", "sunset", "night" };
        const default_times = [_]f32{ 0, 0.07, 0.13, 0.42, 0.7, 0.9, 1.0 };
        const use_times: []const f32 = if (times.len == names.len) times else &default_times;
        var keys: std.ArrayList([]f32) = .empty;
        errdefer {
            for (keys.items) |k| self.gpa.free(k);
            keys.deinit(self.gpa);
        }
        var positions: ?[]f32 = null;
        defer if (positions) |p| self.gpa.free(p);
        var indices: ?[]u16 = null;
        defer if (indices) |p| self.gpa.free(p);
        var n_verts: usize = 0;
        for (names) |nm| {
            var path_buf: [128]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "world/environments/sky/blueinterp/skysphere_{s}.nif", .{nm}) catch return;
            const bytes = self.vfs.read(self.gpa, path) catch return;
            defer self.gpa.free(bytes);
            var nf = nif.parse(self.gpa, bytes) catch return;
            defer nf.deinit();
            var md: ?nif.MeshData = null;
            for (nf.blocks) |blk| switch (blk) {
                .mesh_data => |m| if (md == null) {
                    md = m;
                },
                else => {},
            };
            const m = md orelse return;
            if (m.colors.len != m.vertices.len or m.vertices.len == 0) return;
            if (positions == null) {
                n_verts = m.vertices.len;
                const p = try self.gpa.alloc(f32, n_verts * 3);
                for (m.vertices, 0..) |v, i| {
                    p[i * 3] = v[0];
                    p[i * 3 + 1] = v[1];
                    p[i * 3 + 2] = v[2];
                }
                positions = p;
                indices = try self.gpa.dupe(u16, m.indices);
            } else if (m.vertices.len != n_verts) return;
            const col = try self.gpa.alloc(f32, n_verts * 3);
            for (m.colors, 0..) |c, i| {
                col[i * 3] = c[0];
                col[i * 3 + 1] = c[1];
                col[i * 3 + 2] = c[2];
            }
            try keys.append(self.gpa, col);
        }
        const g = self.g;
        var vao: gl.Uint = 0;
        var bufs: [3]gl.Uint = undefined;
        g.genVertexArrays(1, @ptrCast(&vao));
        g.bindVertexArray(vao);
        g.genBuffers(3, &bufs);
        g.bindBuffer(gl.ARRAY_BUFFER, bufs[0]);
        g.bufferData(gl.ARRAY_BUFFER, @intCast(positions.?.len * 4), positions.?.ptr, gl.STATIC_DRAW);
        g.enableVertexAttribArray(0);
        g.vertexAttribPointer(0, 3, gl.FLOAT, 0, 12, @ptrFromInt(0));
        g.bindBuffer(gl.ARRAY_BUFFER, bufs[1]);
        g.bufferData(gl.ARRAY_BUFFER, @intCast(n_verts * 12), keys.items[0].ptr, gl.DYNAMIC_DRAW);
        g.enableVertexAttribArray(1);
        g.vertexAttribPointer(1, 3, gl.FLOAT, 0, 12, @ptrFromInt(0));
        g.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, bufs[2]);
        g.bufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(indices.?.len * 2), indices.?.ptr, gl.STATIC_DRAW);
        g.bindVertexArray(0);
        self.sky = .{
            .vao = vao,
            .col_vbo = bufs[1],
            .index_count = @intCast(indices.?.len),
            .keys = try keys.toOwnedSlice(self.gpa),
            .times = try self.gpa.dupe(f32, use_times),
            .scratch = try self.gpa.alloc(f32, n_verts * 3),
        };
    }

    /// Drops every static draw (props, fences, paths), keeping the terrain,
    /// the animated figures and all cached models.
    pub fn clearStatic(self: *Scene) void {
        for (self.draws.items) |d| self.freeDraw(d);
        self.draws.clearRetainingCapacity();
    }

    /// Drops every animated figure.
    pub fn clearActors(self: *Scene) void {
        for (self.instances.items) |i| self.gpa.free(i.world);
        self.instances.clearRetainingCapacity();
        self.actor_draws.clearRetainingCapacity();
    }

    /// Copies a model's draws into the overlay, moved by `m` and tinted
    /// (used for placement previews and selection highlights).
    pub fn addOverlay(self: *Scene, draws: []const Draw, m: Mat4, tint: [4]f32) !void {
        for (draws) |d| {
            if (d.lod_range[0] > 0) continue; // previews use the detailed level only
            var c = d;
            c.lod_range = .{ 0, std.math.inf(f32) };
            c.world = mul(m, d.world);
            c.dynamic = false;
            c.skin = null;
            c.tint = .{ d.tint[0] * tint[0], d.tint[1] * tint[1], d.tint[2] * tint[2], tint[3] };
            c.blend = true;
            c.depth_write = false;
            c.bound[3] = -1;
            try self.overlay.append(self.gpa, c);
        }
    }

    /// Adds a terrain mesh: one vertex per grid point, shaded by normals.
    pub fn addTerrain(self: *Scene, t: *const terrain_mod.Terrain, tint: [4]f32, flat_tex: [4]gl.Uint, steep_tex: gl.Uint, slot_of: []const u8) !void {
        const w = t.width;
        const h = t.height;
        const sx = t.spacingX();
        const sy = t.spacingY();
        const buf = try self.gpa.alloc(f32, @as(usize, w) * h * vf);
        defer self.gpa.free(buf);
        @memset(buf, 0);
        for (0..h) |j| for (0..w) |i| {
            const o = (j * w + i) * vf;
            const z = t.z[j * w + i];
            const zl = t.z[j * w + (if (i > 0) i - 1 else i)];
            const zr = t.z[j * w + (if (i + 1 < w) i + 1 else i)];
            const zd = t.z[(if (j > 0) j - 1 else j) * w + i];
            const zu = t.z[(if (j + 1 < h) j + 1 else j) * w + i];
            const dx = (zr - zl) / (sx * @as(f32, if (i > 0 and i + 1 < w) 2 else 1));
            const dy = (zu - zd) / (sy * @as(f32, if (j > 0 and j + 1 < h) 2 else 1));
            const n = normalize3(.{ -dx, -dy, 1 });
            buf[o + 0] = @as(f32, @floatFromInt(i)) * sx;
            buf[o + 1] = @as(f32, @floatFromInt(j)) * sy;
            buf[o + 2] = z;
            buf[o + 3] = n[0];
            buf[o + 4] = n[1];
            buf[o + 5] = n[2];
            buf[o + 6] = @as(f32, @floatFromInt(i)) / 4.0;
            buf[o + 7] = @as(f32, @floatFromInt(j)) / 4.0;
            buf[o + 16] = buf[o + 6];
            buf[o + 17] = buf[o + 7];
            buf[o + 12 + @min(slot_of[j * w + i], 3)] = 1; // biome slot weight
        };
        const idx = try self.gpa.alloc(u32, @as(usize, w - 1) * (h - 1) * 6);
        defer self.gpa.free(idx);
        var k: usize = 0;
        for (0..h - 1) |j| for (0..w - 1) |i| {
            const a: u32 = @intCast(j * w + i);
            const b = a + 1;
            const c: u32 = @intCast((j + 1) * w + i);
            const d = c + 1;
            idx[k..][0..6].* = .{ a, b, d, a, d, c };
            k += 6;
        };
        const up = self.uploadMeshOwned(buf, idx.ptr, idx.len * 4);
        if (self.terrain) |old| self.freeDraw(old);
        self.terrain = .{
            .light_set = 0,
            .owned = up.bufs,
            .dynamic = false,
            .index_type = gl.UNSIGNED_INT,
            .block = 0,
            .skin = null,
            .vao = up.vao,
            .index_count = @intCast(idx.len),
            .world = identity,
            .texture = flat_tex[0],
            .flat_extra = .{ flat_tex[1], flat_tex[2], flat_tex[3] },
            .texture2 = steep_tex,
            .tint = tint,
            .blend = false,
            .alpha_cut = 0,
        };
    }

    /// Drapes path tiles over the terrain: one blended mesh per texture.
    pub fn addPaths(self: *Scene, t: *const terrain_mod.Terrain, paths: []const map_mod.PathDecal) !void {
        var done = try self.gpa.alloc(bool, paths.len);
        defer self.gpa.free(done);
        @memset(done, false);
        const subdiv = 6; // quads per decal side
        for (paths, 0..) |first, fi| {
            if (done[fi]) continue;
            var verts: std.ArrayList(f32) = .empty;
            defer verts.deinit(self.gpa);
            var idx: std.ArrayList(u32) = .empty;
            defer idx.deinit(self.gpa);
            for (paths[fi..], fi..) |p, pi| {
                if (done[pi] or !std.ascii.eqlIgnoreCase(p.texture, first.texture)) continue;
                done[pi] = true;
                const base: u32 = @intCast(verts.items.len / vf);
                for (0..subdiv + 1) |j| for (0..subdiv + 1) |i| {
                    const u = @as(f32, @floatFromInt(i)) / subdiv;
                    const v = @as(f32, @floatFromInt(j)) / subdiv;
                    const x = p.position[0] + (u - 0.5) * p.width;
                    const y = p.position[1] + (v - 0.5) * p.height;
                    var vert: [vf]f32 = @splat(0);
                    vert[0] = x;
                    vert[1] = y;
                    vert[2] = t.zAt(x, y) + 0.04;
                    vert[5] = 1; // normal up
                    vert[6] = u;
                    vert[7] = 1 - v;
                    vert[16] = vert[6];
                    vert[17] = vert[7];
                    try verts.appendSlice(self.gpa, &vert);
                };
                for (0..subdiv) |j| for (0..subdiv) |i| {
                    const a: u32 = base + @as(u32, @intCast(j * (subdiv + 1) + i));
                    const b = a + 1;
                    const c = a + subdiv + 1;
                    const d = c + 1;
                    try idx.appendSlice(self.gpa, &.{ a, b, d, a, d, c });
                };
            }
            const tex = self.loadTexturePath(first.texture);
            const up = self.uploadMeshOwned(verts.items, idx.items.ptr, idx.items.len * 4);
            const vao = up.vao;
            try self.draws.append(self.gpa, .{
                .light_set = 0,
                .owned = up.bufs,
                .depth_write = false,
                .dynamic = false,
                .index_type = gl.UNSIGNED_INT,
                .block = 0,
                .skin = null,
                .vao = vao,
                .index_count = @intCast(idx.items.len),
                .world = identity,
                .texture = tex,
                .tint = .{ 1, 1, 1, 1 },
                .blend = true,
                .alpha_cut = 10.0 / 255.0,
            });
        }
    }

    /// Loads a texture by its exact VFS path; the white texture if missing.
    pub fn loadTexturePath(self: *Scene, path: []const u8) gl.Uint {
        const bytes = self.vfs.read(self.gpa, path) catch return self.white;
        defer self.gpa.free(bytes);
        var img = dds.parse(self.gpa, bytes) catch return self.white;
        defer img.deinit();
        return upload(self.g, &img);
    }

    /// Loads a model by VFS path (`.bfm`, `.nif`, or either extension left
    /// off) and returns its draws relative to the model origin. Results,
    /// including failures, are cached.
    pub fn loadModel(self: *Scene, path: []const u8) !?[]const Draw {
        var key_buf: [512]u8 = undefined;
        if (path.len == 0 or path.len > key_buf.len) return null;
        for (path, 0..) |ch, i| key_buf[i] = if (ch == '\\') '/' else std.ascii.toLower(ch);
        const key = key_buf[0..path.len];
        if (self.models.get(key)) |cached| return cached;

        const owned_key = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned_key);
        self.build_r = 0;
        self.build_h = 0;
        const result = try self.buildModel(key);
        try self.models.put(self.gpa, owned_key, result);
        if (result != null) {
            const bkey = try self.gpa.dupe(u8, key);
            errdefer self.gpa.free(bkey);
            try self.model_bounds.put(self.gpa, bkey, .{ self.build_r, self.build_h });
        }
        return result;
    }

    /// Horizontal radius and height of a loaded model.
    pub fn modelBounds(self: *Scene, path: []const u8) ?[2]f32 {
        var key_buf: [512]u8 = undefined;
        if (path.len == 0 or path.len > key_buf.len) return null;
        for (path, 0..) |ch, i| key_buf[i] = if (ch == '\\') '/' else std.ascii.toLower(ch);
        return self.model_bounds.get(key_buf[0..path.len]);
    }

    fn buildModel(self: *Scene, key: []const u8) !?[]const Draw {
        const gpa = self.gpa;
        var nif_path_buf: [512]u8 = undefined;
        var nif_path: []const u8 = key;
        var mf: ?model.Manifest = null;
        defer if (mf) |*m| m.deinit();
        if (std.mem.endsWith(u8, key, ".bfm") or (!std.mem.endsWith(u8, key, ".nif") and self.tryManifest(key, &nif_path_buf, &mf))) {
            if (mf == null) {
                const data = self.vfs.read(gpa, key) catch return null;
                defer gpa.free(data);
                mf = model.parseManifest(gpa, data) catch return null;
            }
            nif_path = mf.?.model_name;
        } else if (!std.mem.endsWith(u8, key, ".nif")) {
            const with_ext = std.fmt.bufPrint(&nif_path_buf, "{s}.nif", .{key}) catch return null;
            nif_path = with_ext;
        }
        const bytes = self.vfs.read(gpa, nif_path) catch return null;
        defer gpa.free(bytes);
        var nf = nif.parse(gpa, bytes) catch return null;
        defer nf.deinit();

        const tmp = try gpa.alloc(Mat4, nf.blocks.len);
        defer gpa.free(tmp);
        @memset(tmp, identity);
        const saved = self.world;
        self.world = tmp;
        defer self.world = saved;
        const start = self.draws.items.len;
        poseWorldAllLods(self.world, &nf, identity);
        const saved_lod = self.lod_all;
        self.lod_all = true;
        defer self.lod_all = saved_lod;
        for (nf.roots) |r| try self.walk(&nf, r);
        const out = try gpa.dupe(Draw, self.draws.items[start..]);
        self.draws.shrinkRetainingCapacity(start);
        return out;
    }

    /// True (and fills `mf`) when `<key>.bfm` exists and parses.
    fn tryManifest(self: *Scene, key: []const u8, buf: []u8, mf: *?model.Manifest) bool {
        const p = std.fmt.bufPrint(buf, "{s}.bfm", .{key}) catch return false;
        if (!self.vfs.exists(p)) return false;
        const data = self.vfs.read(self.gpa, p) catch return false;
        defer self.gpa.free(data);
        mf.* = model.parseManifest(self.gpa, data) catch return false;
        return true;
    }

    /// Loads an animation file once; null if it cannot be read.
    fn loadAnim(self: *Scene, path: []const u8) ?*const bf.Animation {
        var key_buf: [512]u8 = undefined;
        if (path.len == 0 or path.len > key_buf.len) return null;
        for (path, 0..) |ch, i| key_buf[i] = if (ch == '\\') '/' else std.ascii.toLower(ch);
        const key = key_buf[0..path.len];
        if (self.anim_cache.get(key)) |c| return c;
        const owned = self.gpa.dupe(u8, key) catch return null;
        var result: ?*bf.Animation = null;
        if (self.vfs.read(self.gpa, key)) |bytes| {
            defer self.gpa.free(bytes);
            if (bf.parse(self.gpa, bytes)) |an| {
                if (self.gpa.create(bf.Animation)) |p| {
                    p.* = an;
                    result = p;
                } else |_| {
                    var tmp = an;
                    tmp.deinit();
                }
            } else |_| {}
        } else |_| {}
        self.anim_cache.put(self.gpa, owned, result) catch self.gpa.free(owned);
        return result;
    }

    /// Builds (once per model) the skinned, pose-driven draws for an actor.
    fn actorTemplate(self: *Scene, file: []const u8) !?*ActorTemplate {
        var key_buf: [512]u8 = undefined;
        if (file.len == 0 or file.len > key_buf.len) return null;
        for (file, 0..) |ch, i| key_buf[i] = if (ch == '\\') '/' else std.ascii.toLower(ch);
        const key = key_buf[0..file.len];
        if (self.actor_models.get(key)) |c| return c;
        const owned = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned);
        const tmpl = try self.buildActor(key);
        try self.actor_models.put(self.gpa, owned, tmpl);
        return tmpl;
    }

    fn buildActor(self: *Scene, key: []const u8) !?*ActorTemplate {
        const gpa = self.gpa;
        if (!std.mem.endsWith(u8, key, ".bfm")) return null;
        const mdata = self.vfs.read(gpa, key) catch return null;
        defer gpa.free(mdata);
        var mf = model.parseManifest(gpa, mdata) catch return null;
        errdefer mf.deinit();
        const bytes = self.vfs.read(gpa, mf.model_name) catch return null;
        defer gpa.free(bytes);
        const nfp = try gpa.create(nif.Nif);
        errdefer gpa.destroy(nfp);
        nfp.* = nif.parse(gpa, bytes) catch return null;
        errdefer nfp.deinit();

        const tmp = try gpa.alloc(Mat4, nfp.blocks.len);
        defer gpa.free(tmp);
        @memset(tmp, identity);
        const saved = .{ self.world, self.want_skin, self.dynamic_draws };
        self.world = tmp;
        self.want_skin = true;
        self.dynamic_draws = true;
        defer {
            self.world = saved[0];
            self.want_skin = saved[1];
            self.dynamic_draws = saved[2];
        }
        const start = self.draws.items.len;
        self.pose(nfp, null, 0);
        for (nfp.roots) |r| try self.walk(nfp, r);
        const draws = try gpa.dupe(Draw, self.draws.items[start..]);
        self.draws.shrinkRetainingCapacity(start);
        const t = try gpa.create(ActorTemplate);
        var head_node: ?u32 = null;
        for (nfp.blocks, 0..) |blk, bi| switch (blk) {
            .node => |n| if (std.ascii.eqlIgnoreCase(n.av.net.name, "Link_Head")) {
                head_node = @intCast(bi);
            },
            else => {},
        };
        t.* = .{ .nf = nfp, .draws = draws, .manifest = mf, .head_node = head_node };
        return t;
    }

    /// Adds an animated figure from a `.bfm` actor file, looping an idle
    /// animation. Returns false if the model cannot be built.
    pub fn addActor(self: *Scene, file: []const u8, root: Mat4, phase: f32, swaps: []const map_mod.Swap, head: ?ActorHead) !bool {
        const tmpl = (try self.actorTemplate(file)) orelse return false;
        const world = try self.gpa.alloc(Mat4, tmpl.nf.blocks.len);
        @memset(world, identity);

        var anim: ?*const bf.Animation = null;
        if (tmpl.manifest) |*mf| {
            var chosen: ?*const model.Animation = mf.animation("Stand_Idle");
            if (chosen == null) for (mf.animations) |*a| {
                if (containsIgnoreCase(a.name, "idle") and !a.explicit_use_only) {
                    chosen = a;
                    break;
                }
            };
            if (chosen) |c| anim = self.loadAnim(c.path);
        }
        const idx: u32 = @intCast(self.instances.items.len);
        try self.instances.append(self.gpa, .{
            .nf = tmpl.nf,
            .world = world,
            .root = root,
            .anim = anim,
            .phase = phase,
            .manifest = if (tmpl.manifest) |*m| m else null,
        });
        poseWorld(world, tmpl.nf, root, anim, 0);
        for (tmpl.draws) |d| {
            var c = d;
            c.inst = idx;
            c.bound[3] = -1;
            self.applySwaps(&c, swaps);
            try self.actor_draws.append(self.gpa, c);
        }
        if (head) |h| if (tmpl.head_node) |node| {
            if (try self.loadModel(h.model)) |hdraws| for (hdraws) |d| {
                if (d.lod_range[0] > 0) continue; // heads use the detailed level
                var c = d;
                c.lod_range = .{ 0, std.math.inf(f32) };
                c.inst = idx;
                c.attach_node = node;
                c.dynamic = false;
                c.skin = null;
                c.bound[3] = -1;
                c.world = mul(rotationZ(h.yaw), d.world);
                self.applySwaps(&c, h.swaps);
                try self.actor_draws.append(self.gpa, c);
            };
        };
        return true;
    }

    /// Length in seconds of an animation of an instance's model, if it has one.
    pub fn animDuration(self: *Scene, idx: usize, name: []const u8) ?f32 {
        if (idx >= self.instances.items.len) return null;
        const mf = self.instances.items[idx].manifest orelse return null;
        const entry = mf.animation(name) orelse return null;
        const an = self.loadAnim(entry.path) orelse return null;
        return if (an.duration > 0) an.duration else null;
    }

    /// Ground speed (model units per second) of an instance's walk
    /// animation, from how far its root bone travels over one cycle.
    pub fn walkSpeed(self: *Scene, idx: usize) ?f32 {
        const inst = &self.instances.items[idx];
        const mf = inst.manifest orelse return null;
        const entry = mf.animation("Walk_Ahead") orelse mf.animation("Walk") orelse return null;
        const an = self.loadAnim(entry.path) orelse return null;
        if (an.duration <= 0) return null;
        var best: f32 = 0;
        for ([_][]const u8{ "Bip01", "Bip01 NonAccum" }) |name| {
            const bone = an.bone(name) orelse continue;
            if (bone.pos.len < 2) continue;
            const a = bone.pos[0].p;
            const b = bone.pos[bone.pos.len - 1].p;
            const d = @sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]));
            best = @max(best, d / an.duration);
        }
        return if (best > 0.05) best else null;
    }

    /// Drives an animated figure from the simulation: where it stands and
    /// which animation (by manifest name, trying `names` in order) at what time.
    pub fn driveInstance(self: *Scene, idx: usize, root: Mat4, names: []const []const u8, time: f32) void {
        const inst = &self.instances.items[idx];
        inst.root = root;
        inst.driven = true;
        inst.time = time;
        const mf = inst.manifest orelse return;
        for (names) |n| {
            const a = mf.animation(n) orelse continue;
            if (self.loadAnim(a.path)) |loaded| {
                inst.anim = loaded;
                return;
            }
        }
    }

    /// Model pieces for a fence type: its post and its straight segment.
    /// Looked up in the type's entity file under `fences/ai` or `paths/ai`.
    pub fn fenceModels(self: *Scene, kind: []const u8) !FencePieces {
        var key_buf: [128]u8 = undefined;
        if (kind.len == 0 or kind.len > key_buf.len) return .{};
        const key = std.ascii.lowerString(&key_buf, kind);
        if (self.fence_cache.get(key)) |c| return c;
        const owned = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(owned);
        const pieces = try self.buildFence(key);
        try self.fence_cache.put(self.gpa, owned, pieces);
        return pieces;
    }

    fn buildFence(self: *Scene, kind: []const u8) !FencePieces {
        const dirs = [_][]const u8{ "entities/objects/fences/ai", "entities/objects/paths/ai" };
        for (dirs) |dir| {
            var path_buf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.xml", .{ dir, kind }) catch continue;
            const bytes = self.vfs.read(self.gpa, path) catch continue;
            defer self.gpa.free(bytes);
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            const root = @import("xml.zig").parse(arena.allocator(), bytes, null) catch continue;
            const binder = root.child("binder") orelse continue;
            var out: FencePieces = .{};
            for (binder.children) |nb| {
                const bname = nb.attr("binderName") orelse continue;
                const inst = nb.child("instance") orelse continue;
                const phys = inst.child("BFPhysObj") orelse continue;
                const comp = phys.child("BFSceneGraphComponent") orelse phys.child("BFSimpleLODComponent") orelse continue;
                const mf = comp.attr("modelfile") orelse continue;
                if (std.ascii.eqlIgnoreCase(bname, "start_post")) out.post = try self.loadModel(mf);
                if (std.ascii.eqlIgnoreCase(bname, "fence90")) out.segment = try self.loadModel(mf);
            }
            return out;
        }
        return .{};
    }

    /// Adds fixed copies of a model's draws, moved by `m`.
    pub fn place(self: *Scene, draws: []const Draw, m: Mat4, swaps: []const map_mod.Swap) !void {
        for (draws) |d| {
            var c = d;
            c.world = mul(m, d.world);
            c.dynamic = false;
            if (d.bound[3] >= 0 and d.skin == null) {
                // `d.bound` is relative to the model root, so only `m` applies.
                const wc = transformPoint(m, .{ d.bound[0], d.bound[1], d.bound[2] });
                const sc = @sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]);
                c.bound = .{ wc[0], wc[1], wc[2], d.bound[3] * sc };
            } else c.bound[3] = -1;
            const lsc = @sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]) * self.lod_bias;
            c.lod_range = .{ d.lod_range[0] * lsc, d.lod_range[1] * lsc };
            self.applySwaps(&c, swaps);
            try self.draws.append(self.gpa, c);
        }
    }

    /// Fills the bone index/weight attributes (floats 8..15 of each vertex)
    /// and returns the bone table, or null for unskinned geometry.
    fn buildSkin(self: *Scene, nf: *const nif.Nif, geo: nif.Geometry, buf: []f32, n: usize) !?Skin {
        if (geo.skin < 0) return null;
        const inst = switch (nf.blocks[@intCast(geo.skin)]) {
            .skin_instance => |i| i,
            else => return null,
        };
        if (inst.data < 0) return null;
        const sd = switch (nf.blocks[@intCast(inst.data)]) {
            .skin_data => |d| d,
            else => return null,
        };
        if (sd.bones.len == 0 or sd.bones.len > max_bones or sd.bones.len != inst.bones.len) return null;

        // Keep the four strongest influences per vertex.
        const Infl = struct { bone: u32 = 0, w: f32 = 0 };
        const infl = try self.gpa.alloc([4]Infl, n);
        defer self.gpa.free(infl);
        @memset(infl, .{ .{}, .{}, .{}, .{} });
        for (sd.bones, 0..) |b, bi| for (b.weights) |wt| {
            if (wt.vertex >= n or wt.weight <= 0) continue;
            const slot = &infl[wt.vertex];
            var min_i: usize = 0;
            for (1..4) |k| if (slot[k].w < slot[min_i].w) {
                min_i = k;
            };
            if (wt.weight > slot[min_i].w) slot[min_i] = .{ .bone = @intCast(bi), .w = wt.weight };
        };
        for (0..n) |v| {
            var sum: f32 = 0;
            for (infl[v]) |e| sum += e.w;
            for (0..4) |k| {
                buf[v * vf + 8 + k] = @floatFromInt(infl[v][k].bone);
                buf[v * vf + 12 + k] = if (sum > 0) infl[v][k].w / sum else if (k == 0) 1 else 0;
            }
        }

        const a = self.arena.allocator();
        const bones = try a.alloc(u32, sd.bones.len);
        const offsets = try a.alloc(Mat4, sd.bones.len);
        for (sd.bones, 0..) |b, i| {
            if (inst.bones[i] < 0) return null;
            bones[i] = @intCast(inst.bones[i]);
            offsets[i] = fromTransform(b.transform);
        }
        return .{ .bones = bones, .offsets = offsets };
    }
};

// ----------------------------------------------------------------- viewer

pub const Options = struct {
    /// When set, render a few frames, write the framebuffer as a binary PPM
    /// to this writer, and return (no interactive loop).
    screenshot: ?*std.Io.Writer = null,
    /// Animation to play: a `.bf` path, or a name from the `.bfm` manifest.
    anim: ?[]const u8 = null,
    /// Fixed pose time in seconds (otherwise the animation loops in real time).
    time: ?f32 = null,
    /// Initial camera yaw and pitch in radians, if given.
    yaw: ?f32 = null,
    pitch: ?f32 = null,
    /// Frames rendered before the screenshot is taken (a hook can also
    /// request it earlier or later through `FrameCtx.shot_request`).
    shot_frames: u32 = 3,
    /// Mouse button that orbits the camera (1 left, 3 right).
    orbit_button: u8 = 1,
    /// Map position to look at (x, y), instead of the map centre.
    focus: ?[2]f32 = null,
    /// Camera distance as a multiple of the default.
    zoom: f32 = 1.0,
    width: u32 = 1280,
    height: u32 = 720,
};

// SDL scancodes (USB HID usage ids) for the camera keys.
const key_a: u32 = 4;
const key_d: u32 = 7;
const key_s: u32 = 22;
const key_w: u32 = 26;

/// Window, GL context and loaded entry points. Lives in place because the
/// scene keeps a pointer to `g`.
pub const Gfx = struct {
    plat: platform.Platform,
    win: platform.Window,
    ctx: platform.GlContext,
    g: Gl,
    prog: gl.Uint,
    u_model: gl.Int,
    u_vp: gl.Int,
    u_tex: gl.Int,
    u_tint: gl.Int,
    u_cut: gl.Int,
    u_skinned: gl.Int,
    u_bones: gl.Int,
    u_tex2: gl.Int,
    u_terrain: gl.Int,
    u_decal: gl.Int,
    u_decal_mode: gl.Int,
    u_flat: [3]gl.Int,
    u_lightset: gl.Int,
    u_amb: gl.Int,
    u_ldir: gl.Int,
    u_lcol: gl.Int,
    u_fogcol: gl.Int,
    u_fogrange: gl.Int,
    u_eye: gl.Int,
    // sky dome
    sky_prog: gl.Uint,
    sky_vp: gl.Int,
    sky_eye: gl.Int,
    sky_scale: gl.Int,
    sky_sun: gl.Int,
    sky_suncol: gl.Int,
    // 2D overlay
    ui_prog: gl.Uint,
    ui_screen: gl.Int,
    ui_atlas_loc: gl.Int,
    ui_vao: gl.Uint,
    ui_vbo: gl.Uint,
    ui_tex: gl.Uint,

    pub fn open(self: *Gfx, opts: Options) !void {
        self.plat = platform.Platform.init() catch {
            std.debug.print("SDL init failed: {s}\n", .{platform.lastError()});
            return error.PlatformInit;
        };
        errdefer self.plat.deinit();
        self.win = platform.Window.createGl("zootycon2 viewer", opts.width, opts.height) catch {
            std.debug.print("window creation failed: {s}\n", .{platform.lastError()});
            return error.PlatformWindow;
        };
        errdefer self.win.destroy();
        self.ctx = self.win.glCreateContext() catch {
            std.debug.print("OpenGL 3.3 context failed: {s}\n", .{platform.lastError()});
            return error.GlContext;
        };
        errdefer self.ctx.destroy();
        self.g = .{};
        if (self.g.load(platform.glGetProcAddress)) |missing| {
            std.debug.print("missing OpenGL function: {s}\n", .{missing});
            return error.GlMissing;
        }
        if (opts.screenshot == null) {
            if (self.g.getString(gl.RENDERER)) |r| std.debug.print("renderer: {s}\n", .{r});
        }
        self.prog = try makeProgram(&self.g);
        const g = &self.g;
        self.u_model = g.getUniformLocation(self.prog, "uModel");
        self.u_vp = g.getUniformLocation(self.prog, "uViewProj");
        self.u_tex = g.getUniformLocation(self.prog, "uTex");
        self.u_tint = g.getUniformLocation(self.prog, "uTint");
        self.u_cut = g.getUniformLocation(self.prog, "uAlphaCut");
        self.u_skinned = g.getUniformLocation(self.prog, "uSkinned");
        self.u_bones = g.getUniformLocation(self.prog, "uBones");
        self.u_tex2 = g.getUniformLocation(self.prog, "uTex2");
        self.u_terrain = g.getUniformLocation(self.prog, "uTerrain");
        self.u_decal = g.getUniformLocation(self.prog, "uDecal");
        self.u_decal_mode = g.getUniformLocation(self.prog, "uDecalMode");
        self.u_flat = .{
            g.getUniformLocation(self.prog, "uFlat1"),
            g.getUniformLocation(self.prog, "uFlat2"),
            g.getUniformLocation(self.prog, "uFlat3"),
        };
        self.u_lightset = g.getUniformLocation(self.prog, "uLightSet");
        self.u_amb = g.getUniformLocation(self.prog, "uAmb");
        self.u_ldir = g.getUniformLocation(self.prog, "uLdir");
        self.u_lcol = g.getUniformLocation(self.prog, "uLcol");
        self.u_fogcol = g.getUniformLocation(self.prog, "uFogColor");
        self.u_fogrange = g.getUniformLocation(self.prog, "uFogRange");
        self.u_eye = g.getUniformLocation(self.prog, "uEye");
        self.sky_prog = try makeProgramFrom(g, sky_vs, sky_fs);
        self.sky_vp = g.getUniformLocation(self.sky_prog, "uVP");
        self.sky_eye = g.getUniformLocation(self.sky_prog, "uEye");
        self.sky_scale = g.getUniformLocation(self.sky_prog, "uScale");
        self.sky_sun = g.getUniformLocation(self.sky_prog, "uSunDir");
        self.sky_suncol = g.getUniformLocation(self.sky_prog, "uSunCol");
        try self.initUi();
    }

    fn initUi(self: *Gfx) !void {
        const g = &self.g;
        self.ui_prog = try makeProgramFrom(g, ui_vs, ui_fs);
        self.ui_screen = g.getUniformLocation(self.ui_prog, "uScreen");
        self.ui_atlas_loc = g.getUniformLocation(self.ui_prog, "uAtlas");
        var atlas: [font.atlas_w * font.atlas_h * 4]u8 = undefined;
        font.buildAtlas(&atlas);
        g.genTextures(1, @ptrCast(&self.ui_tex));
        g.bindTexture(gl.TEXTURE_2D, self.ui_tex);
        g.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
        g.texImage2D(gl.TEXTURE_2D, 0, @intCast(gl.RGBA8), font.atlas_w, font.atlas_h, 0, gl.RGBA, gl.UNSIGNED_BYTE, &atlas);
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, @intCast(gl.NEAREST));
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, @intCast(gl.NEAREST));
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, @intCast(gl.CLAMP_TO_EDGE));
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, @intCast(gl.CLAMP_TO_EDGE));
        g.genVertexArrays(1, @ptrCast(&self.ui_vao));
        g.genBuffers(1, @ptrCast(&self.ui_vbo));
        g.bindVertexArray(self.ui_vao);
        g.bindBuffer(gl.ARRAY_BUFFER, self.ui_vbo);
        const stride: gl.Sizei = 8 * 4;
        g.enableVertexAttribArray(0);
        g.vertexAttribPointer(0, 2, gl.FLOAT, 0, stride, @ptrFromInt(0));
        g.enableVertexAttribArray(1);
        g.vertexAttribPointer(1, 2, gl.FLOAT, 0, stride, @ptrFromInt(8));
        g.enableVertexAttribArray(2);
        g.vertexAttribPointer(2, 4, gl.FLOAT, 0, stride, @ptrFromInt(16));
        g.bindVertexArray(0);
    }

    /// Draws the overlay built in `ui` over the finished scene.
    fn drawUi(self: *Gfx, ui: *const Ui) void {
        if (ui.verts.items.len == 0) return;
        const g = &self.g;
        g.disable(gl.DEPTH_TEST);
        g.enable(gl.BLEND);
        g.depthMask(0);
        g.useProgram(self.ui_prog);
        g.uniform2f(self.ui_screen, ui.width, ui.height);
        g.uniform1i(self.ui_atlas_loc, 0);
        g.activeTexture(gl.TEXTURE0);
        g.bindTexture(gl.TEXTURE_2D, self.ui_tex);
        g.bindVertexArray(self.ui_vao);
        g.bindBuffer(gl.ARRAY_BUFFER, self.ui_vbo);
        g.bufferData(gl.ARRAY_BUFFER, @intCast(ui.verts.items.len * 4), ui.verts.items.ptr, gl.DYNAMIC_DRAW);
        g.drawArrays(gl.TRIANGLES, 0, @intCast(ui.verts.items.len / 8));
        g.bindVertexArray(0);
        g.depthMask(1);
        g.enable(gl.DEPTH_TEST);
    }

    pub fn close(self: *Gfx) void {
        self.ctx.destroy();
        self.win.destroy();
        self.plat.deinit();
    }
};

const Playback = struct {
    nf: *const nif.Nif,
    anim: *const bf.Animation,
};

pub const Camera = struct {
    center: [3]f32,
    radius: f32,
    yaw: f32 = -0.8,
    pitch: f32 = 0.45,
    dist: f32,

    pub const fov_y: f32 = 0.8;

    pub fn eye(self: Camera) [3]f32 {
        return .{
            self.center[0] + self.dist * @cos(self.pitch) * @cos(self.yaw),
            self.center[1] + self.dist * @cos(self.pitch) * @sin(self.yaw),
            self.center[2] + self.dist * @sin(self.pitch),
        };
    }

    /// Window position of a world point, or null if it is behind the camera.
    pub fn project(self: Camera, p: [3]f32, width: f32, height: f32) ?[2]f32 {
        const e = self.eye();
        const f = normalize3(.{ self.center[0] - e[0], self.center[1] - e[1], self.center[2] - e[2] });
        const right = normalize3(cross(f, .{ 0, 0, 1 }));
        const up = cross(right, f);
        const v = [3]f32{ p[0] - e[0], p[1] - e[1], p[2] - e[2] };
        const depth = v[0] * f[0] + v[1] * f[1] + v[2] * f[2];
        if (depth <= 0.001) return null;
        const t = @tan(fov_y / 2);
        const x = (v[0] * right[0] + v[1] * right[1] + v[2] * right[2]) / (depth * t * (width / height));
        const y = (v[0] * up[0] + v[1] * up[1] + v[2] * up[2]) / (depth * t);
        return .{ (x + 1) / 2 * width, (1 - y) / 2 * height };
    }

    /// World-space ray through window position (mx, my) in a viewport of
    /// the given size.
    pub fn ray(self: Camera, mx: f32, my: f32, width: f32, height: f32) struct { origin: [3]f32, dir: [3]f32 } {
        const e = self.eye();
        const f = normalize3(.{ self.center[0] - e[0], self.center[1] - e[1], self.center[2] - e[2] });
        const right = normalize3(cross(f, .{ 0, 0, 1 }));
        const up = cross(right, f);
        const t = @tan(fov_y / 2);
        const nx = (2 * mx / width - 1) * t * (width / height);
        const ny = (1 - 2 * my / height) * t;
        return .{
            .origin = e,
            .dir = normalize3(.{
                f[0] + right[0] * nx + up[0] * ny,
                f[1] + right[1] * nx + up[1] * ny,
                f[2] + right[2] * nx + up[2] * ny,
            }),
        };
    }
};

/// What hooks see each frame and on each event.
pub const FrameCtx = struct {
    cam: *Camera,
    win: platform.Window,
    width: u32,
    height: u32,
    /// Seconds since the loop started, and since the previous frame.
    secs: f32 = 0,
    dt: f32 = 0,
    /// Last known mouse position in window coordinates.
    mouse: [2]f32 = .{ 0, 0 },
    /// Set by a hook to end the loop.
    quit: bool = false,
    /// Window size in mouse coordinates (differs from `width`/`height`,
    /// which are pixels, on HiDPI displays).
    win_width: u32 = 1,
    win_height: u32 = 1,
    /// Set by a hook to say it handled the current event.
    consumed: bool = false,
    /// Set by a hook to capture the screenshot on this frame.
    shot_request: bool = false,
    /// For synthetic input.
    plat: platform.Platform,
};

const NoHooks = struct {
    pub fn event(_: *NoHooks, _: platform.Event, _: *FrameCtx) void {}
    pub fn frame(_: *NoHooks, _: *FrameCtx) !void {}
};

/// View frustum for culling bounding spheres.
const Frustum = struct {
    planes: [6][4]f32,
    eye: [3]f32,

    fn init(m: Mat4, eye: [3]f32) Frustum {
        // Gribb-Hartmann: planes are sums and differences of matrix rows.
        var rows: [4][4]f32 = undefined;
        for (0..4) |i| rows[i] = .{ m[i], m[4 + i], m[8 + i], m[12 + i] };
        var planes: [6][4]f32 = undefined;
        const combos = [6]struct { s: f32, i: usize }{ .{ .s = 1, .i = 0 }, .{ .s = -1, .i = 0 }, .{ .s = 1, .i = 1 }, .{ .s = -1, .i = 1 }, .{ .s = 1, .i = 2 }, .{ .s = -1, .i = 2 } };
        for (combos, 0..) |c, k| {
            var p: [4]f32 = undefined;
            for (0..4) |j| p[j] = rows[3][j] + c.s * rows[c.i][j];
            const len = @sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]);
            for (&p) |*x| x.* /= len;
            planes[k] = p;
        }
        return .{ .planes = planes, .eye = eye };
    }

    /// False if the sphere is outside the frustum or too small to see.
    fn sees(self: Frustum, b: [4]f32) bool {
        if (b[3] < 0) return true;
        for (self.planes) |p| {
            if (p[0] * b[0] + p[1] * b[1] + p[2] * b[2] + p[3] < -b[3]) return false;
        }
        const dx = b[0] - self.eye[0];
        const dy = b[1] - self.eye[1];
        const dz = b[2] - self.eye[2];
        const dist = @sqrt(dx * dx + dy * dy + dz * dz);
        return b[3] > dist * 0.0015; // under about a pixel at 720p
    }
};

fn drawItem(gfx: *Gfx, scene: *Scene, d: Draw, fr: *const Frustum) void {
    if (!fr.sees(d.bound)) return;
    if (d.bound[3] >= 0 and (d.lod_range[0] > 0 or d.lod_range[1] < std.math.inf(f32))) {
        const dx = d.bound[0] - fr.eye[0];
        const dy = d.bound[1] - fr.eye[1];
        const dz = d.bound[2] - fr.eye[2];
        const dist = @sqrt(dx * dx + dy * dy + dz * dz);
        if (dist < d.lod_range[0] or dist >= d.lod_range[1]) return;
    }
    const g = &gfx.g;
    g.activeTexture(gl.TEXTURE0 + 1);
    g.bindTexture(gl.TEXTURE_2D, d.texture2);
    g.uniform1i(gfx.u_terrain, if (d.texture2 != 0) 1 else 0);
    g.uniform1i(gfx.u_lightset, d.light_set);
    if (d.texture2 != 0) for (d.flat_extra, 0..) |tx, i| {
        g.activeTexture(gl.TEXTURE0 + 3 + @as(gl.Enum, @intCast(i)));
        g.bindTexture(gl.TEXTURE_2D, tx);
    };
    g.activeTexture(gl.TEXTURE0 + 2);
    g.bindTexture(gl.TEXTURE_2D, d.decal);
    g.uniform1i(gfx.u_decal_mode, if (d.decal != 0) d.decal_mode else 0);
    g.activeTexture(gl.TEXTURE0);
    const wl: []const Mat4 = if (d.inst) |i| scene.instances.items[i].world else scene.world;
    if (d.skin) |sk| {
        var mats: [max_bones]Mat4 = undefined;
        for (sk.bones, sk.offsets, 0..) |bn, off, i| mats[i] = mul(wl[bn], off);
        g.uniform1i(gfx.u_skinned, 1);
        g.uniformMatrix4fv(gfx.u_bones, @intCast(sk.bones.len), 0, @ptrCast(&mats));
    } else {
        g.uniform1i(gfx.u_skinned, 0);
        if (d.attach_node) |n| {
            const m = mul(wl[n], d.world);
            g.uniformMatrix4fv(gfx.u_model, 1, 0, &m);
        } else {
            g.uniformMatrix4fv(gfx.u_model, 1, 0, if (d.dynamic) &wl[d.block] else &d.world);
        }
    }
    g.uniform4f(gfx.u_tint, d.tint[0], d.tint[1], d.tint[2], d.tint[3]);
    g.uniform1f(gfx.u_cut, d.alpha_cut);
    g.bindTexture(gl.TEXTURE_2D, d.texture);
    if (d.blend) g.enable(gl.BLEND) else g.disable(gl.BLEND);
    g.depthMask(if (d.depth_write) 1 else 0);
    g.bindVertexArray(d.vao);
    g.drawElements(gl.TRIANGLES, d.index_count, d.index_type, null);
}

fn loop(gpa: std.mem.Allocator, gfx: *Gfx, scene: *Scene, cam_init: Camera, play: ?Playback, opts: Options) !void {
    var hooks: NoHooks = .{};
    return loopWith(gpa, gfx, scene, cam_init, play, opts, &hooks);
}

pub fn loopWith(gpa: std.mem.Allocator, gfx: *Gfx, scene: *Scene, cam_init: Camera, play: ?Playback, opts: Options, hooks: anytype) !void {
    const g = &gfx.g;
    const plat = gfx.plat;
    var cam = cam_init;
    if (opts.yaw) |y| cam.yaw = y;
    if (opts.pitch) |p| cam.pitch = p;
    cam.dist *= opts.zoom;
    var dragging = false;
    var last_x: f32 = 0;
    var last_y: f32 = 0;
    var size = gfx.win.pixelSize();
    var held = [4]bool{ false, false, false, false }; // w a s d
    var ui: Ui = .{ .gpa = gpa };
    defer ui.deinit();
    var ctx: FrameCtx = .{ .cam = &cam, .win = gfx.win, .width = size.width, .height = size.height, .plat = plat };

    g.enable(gl.DEPTH_TEST);
    g.depthFunc(gl.LEQUAL);
    g.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var frame: u32 = 0;
    const start_ms = plat.ticksMs();
    var prev_ms = start_ms;
    main: while (true) {
        while (plat.pollEvent()) |ev| {
            ctx.width = size.width;
            ctx.height = size.height;
            hooks.event(ev, &ctx);
            if (ctx.quit) break :main;
            // A hook that used the event (a click on a button) keeps the
            // camera from reacting to it too.
            if (ctx.consumed) {
                ctx.consumed = false;
                switch (ev) {
                    .mouse_move => |m| ctx.mouse = .{ m.x, m.y },
                    else => {},
                }
                continue;
            }
            switch (ev) {
            .quit => break :main,
            .key_down => |k| switch (k.scancode) {
                platform.scancode_escape => break :main,
                key_w => held[0] = true,
                key_a => held[1] = true,
                key_s => held[2] = true,
                key_d => held[3] = true,
                else => {},
            },
            .key_up => |k| switch (k.scancode) {
                key_w => held[0] = false,
                key_a => held[1] = false,
                key_s => held[2] = false,
                key_d => held[3] = false,
                else => {},
            },
            .resized => |r| size = .{ .width = @max(r.width, 1), .height = @max(r.height, 1) },
            .mouse_button => |b| if (b.button == opts.orbit_button) {
                dragging = b.down;
                last_x = b.x;
                last_y = b.y;
            },
            .mouse_move => |m| {
                if (dragging) {
                    cam.yaw -= (m.x - last_x) * 0.01;
                    cam.pitch = std.math.clamp(cam.pitch + (m.y - last_y) * 0.01, -1.5, 1.5);
                }
                last_x = m.x;
                last_y = m.y;
                ctx.mouse = .{ m.x, m.y };
            },
            .mouse_wheel => |w| cam.dist = std.math.clamp(cam.dist * std.math.pow(f32, 0.9, w.dy), cam.radius * 0.05, cam.radius * 20),
            }
        }

        const now_ms = plat.ticksMs();
        const dt = @as(f32, @floatFromInt(now_ms - prev_ms)) / 1000.0;
        prev_ms = now_ms;
        ctx.dt = dt;
        ctx.secs = @as(f32, @floatFromInt(now_ms - start_ms)) / 1000.0;
        ctx.width = size.width;
        ctx.height = size.height;
        const logical = gfx.win.logicalSize();
        ctx.win_width = logical.width;
        ctx.win_height = logical.height;
        try hooks.frame(&ctx);
        if (ctx.quit) break :main;
        // WASD pans the look-at point across the ground plane.
        const fwd = [2]f32{ -@cos(cam.yaw), -@sin(cam.yaw) };
        const right = [2]f32{ fwd[1], -fwd[0] };
        var mv = [2]f32{ 0, 0 };
        if (held[0]) mv = .{ mv[0] + fwd[0], mv[1] + fwd[1] };
        if (held[2]) mv = .{ mv[0] - fwd[0], mv[1] - fwd[1] };
        if (held[3]) mv = .{ mv[0] + right[0], mv[1] + right[1] };
        if (held[1]) mv = .{ mv[0] - right[0], mv[1] - right[1] };
        cam.center[0] += mv[0] * cam.dist * dt * 0.8;
        cam.center[1] += mv[1] * cam.dist * dt * 0.8;

        g.viewport(0, 0, @intCast(size.width), @intCast(size.height));
        // Beyond the map edge shows the fog colour, like distant haze.
        if (scene.lighting) |lt| g.clearColor(lt.fog_color[0], lt.fog_color[1], lt.fog_color[2], 1) else g.clearColor(0.18, 0.2, 0.24, 1);
        g.depthMask(1); // decals turn depth writes off; clearing needs them on
        g.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

        const eye = [3]f32{
            cam.center[0] + cam.dist * @cos(cam.pitch) * @cos(cam.yaw),
            cam.center[1] + cam.dist * @cos(cam.pitch) * @sin(cam.yaw),
            cam.center[2] + cam.dist * @sin(cam.pitch),
        };
        const aspect = @as(f32, @floatFromInt(size.width)) / @as(f32, @floatFromInt(size.height));
        const vp = mul(perspective(0.8, aspect, cam.radius * 0.01, cam.dist + cam.radius * 10), lookAt(eye, cam.center, .{ 0, 0, 1 }));

        if (play) |pb| {
            const t: f32 = opts.time orelse blk: {
                const secs = @as(f32, @floatFromInt(now_ms - start_ms)) / 1000.0;
                break :blk if (pb.anim.duration > 0) @mod(secs, pb.anim.duration) else 0;
            };
            scene.pose(pb.nf, pb.anim, t);
        }

        if (scene.instances.items.len > 0) scene.poseInstances(@as(f32, @floatFromInt(now_ms - start_ms)) / 1000.0);

        // Sky first, without depth, centred on the eye.
        if (scene.sky) |*sk| {
            const tod_for_sky = scene.tod;
            sk.update(g, tod_for_sky);
            const sample = scene.lighting orelse defaultLighting();
            // The sun is where the main light comes from.
            const sd = sample.dir[1][0];
            g.disable(gl.DEPTH_TEST);
            g.depthMask(0);
            g.disable(gl.BLEND);
            g.useProgram(gfx.sky_prog);
            g.uniformMatrix4fv(gfx.sky_vp, 1, 0, &vp);
            g.uniform3f(gfx.sky_eye, eye[0], eye[1], eye[2]);
            g.uniform1f(gfx.sky_scale, (dist_far_for(cam)) * 0.45 / 3.0);
            g.uniform3f(gfx.sky_sun, -sd[0], -sd[1], -sd[2]);
            const sc = sample.color[1][0];
            g.uniform3f(gfx.sky_suncol, sc[0], sc[1], sc[2]);
            g.bindVertexArray(sk.vao);
            g.drawElements(gl.TRIANGLES, sk.index_count, gl.UNSIGNED_SHORT, null);
            g.bindVertexArray(0);
            g.enable(gl.DEPTH_TEST);
            g.depthMask(1);
        }

        g.useProgram(gfx.prog);
        g.uniformMatrix4fv(gfx.u_vp, 1, 0, &vp);
        {
            const s = scene.lighting orelse defaultLighting();
            var amb: [6]f32 = undefined;
            var dirs: [18]f32 = undefined;
            var cols: [18]f32 = undefined;
            for (0..2) |si| {
                for (0..3) |k| amb[si * 3 + k] = s.ambient[si][k];
                for (0..3) |li| for (0..3) |k| {
                    dirs[(si * 3 + li) * 3 + k] = s.dir[si][li][k];
                    cols[(si * 3 + li) * 3 + k] = s.color[si][li][k];
                };
            }
            g.uniform3fv(gfx.u_amb, 2, &amb);
            g.uniform3fv(gfx.u_ldir, 6, &dirs);
            g.uniform3fv(gfx.u_lcol, 6, &cols);
            g.uniform3f(gfx.u_fogcol, s.fog_color[0], s.fog_color[1], s.fog_color[2]);
            g.uniform2f(gfx.u_fogrange, s.fog_start * scene.fog_scale, s.fog_end * scene.fog_scale);
            g.uniform3f(gfx.u_eye, eye[0], eye[1], eye[2]);
        }
        g.uniform1i(gfx.u_tex, 0);
        g.uniform1i(gfx.u_tex2, 1);
        g.uniform1i(gfx.u_decal, 2);
        for (gfx.u_flat, 0..) |loc, i| g.uniform1i(loc, @intCast(3 + i));
        const frustum = Frustum.init(vp, eye);
        if (scene.terrain) |t| drawItem(gfx, scene, t, &frustum);
        for (scene.draws.items) |d| drawItem(gfx, scene, d, &frustum);
        for (scene.actor_draws.items) |d| drawItem(gfx, scene, d, &frustum);
        for (scene.overlay.items) |d| drawItem(gfx, scene, d, &frustum);
        const Hk = @typeInfo(@TypeOf(hooks)).pointer.child;
        if (comptime @hasDecl(Hk, "overlay")) {
            ui.verts.clearRetainingCapacity();
            ui.width = @floatFromInt(size.width);
            ui.height = @floatFromInt(size.height);
            try hooks.overlay(&ui, &ctx);
            gfx.drawUi(&ui);
        }

        frame += 1;
        if (opts.screenshot) |w| {
            if (frame < opts.shot_frames and !ctx.shot_request) {
                gfx.ctx.swap();
                continue;
            }
            const px = try gpa.alloc(u8, size.width * size.height * 4);
            defer gpa.free(px);
            g.pixelStorei(gl.PACK_ALIGNMENT, 1);
            g.readPixels(0, 0, @intCast(size.width), @intCast(size.height), gl.RGBA, gl.UNSIGNED_BYTE, px.ptr);
            try w.print("P6\n{d} {d}\n255\n", .{ size.width, size.height });
            var y: usize = size.height;
            while (y > 0) {
                y -= 1;
                for (0..size.width) |x| try w.writeAll(px[(y * size.width + x) * 4 ..][0..3]);
            }
            return;
        }
        gfx.ctx.swap();
    }
}

/// Views one model (`.nif` or `.bfm`), optionally playing an animation.
pub fn run(gpa: std.mem.Allocator, vfs: *vfs_mod.Vfs, path: []const u8, opts: Options) !void {
    // Accept a .bfm manifest as well as a .nif.
    var nif_path: []const u8 = path;
    var manifest: ?model.Manifest = null;
    defer if (manifest) |*m| m.deinit();
    if (std.ascii.endsWithIgnoreCase(path, ".bfm")) {
        const data = try vfs.read(gpa, path);
        defer gpa.free(data);
        manifest = try model.parseManifest(gpa, data);
        nif_path = manifest.?.model_name;
    }
    const nif_bytes = try vfs.read(gpa, nif_path);
    defer gpa.free(nif_bytes);
    var nf = try nif.parse(gpa, nif_bytes);
    defer nf.deinit();

    // Optional animation, by `.bf` path or by manifest name.
    var anim: ?bf.Animation = null;
    defer if (anim) |*a| a.deinit();
    if (opts.anim) |name| {
        const anim_path = if (std.ascii.endsWithIgnoreCase(name, ".bf"))
            name
        else if (manifest) |*m|
            (m.animation(name) orelse return error.UnknownAnimation).path
        else
            return error.UnknownAnimation;
        const abytes = try vfs.read(gpa, anim_path);
        defer gpa.free(abytes);
        anim = try bf.parse(gpa, abytes);
        std.debug.print("animation {s}: {d:.2}s, {d} bones\n", .{ anim_path, anim.?.duration, anim.?.bones.len });
    }

    var gfx: Gfx = undefined;
    try gfx.open(opts);
    defer gfx.close();

    var scene = try Scene.init(gpa, &gfx.g, vfs);
    defer scene.deinit();
    try scene.addNif(&nf);
    if (scene.draws.items.len == 0) return error.NothingToDraw;
    std.debug.print("{d} meshes, {d} textures missing\n", .{ scene.draws.items.len, scene.missing_textures });

    const ext = [3]f32{ scene.max[0] - scene.min[0], scene.max[1] - scene.min[1], scene.max[2] - scene.min[2] };
    const radius = @max(0.001, @sqrt(ext[0] * ext[0] + ext[1] * ext[1] + ext[2] * ext[2]) / 2);
    const cam: Camera = .{
        .center = .{
            (scene.min[0] + scene.max[0]) / 2,
            (scene.min[1] + scene.max[1]) / 2,
            (scene.min[2] + scene.max[2]) / 2,
        },
        .radius = radius,
        .dist = radius * 2.4,
    };
    const play: ?Playback = if (anim) |*a| .{ .nf = &nf, .anim = a } else null;
    try loop(gpa, &gfx, &scene, cam, play, opts);
}

pub const ActorModel = struct { file: []const u8, scale: f32 };

/// Finds the `BFActorComponent` for an entity: the most specific binder on
/// its type path that defines one wins.
pub fn actorModel(gpa: std.mem.Allocator, reg: *const entity.Registry, name: []const u8) ?ActorModel {
    const b = reg.get(name) orelse return null;
    const chain = reg.chain(gpa, b) catch return null;
    defer gpa.free(chain);
    var i = chain.len;
    while (i > 0) {
        i -= 1;
        if (findActor(chain[i].root)) |m| return m;
    }
    return null;
}

/// The model of a named sub-object (`mainObj`, `full`) of an entity.
pub fn binderModel(gpa: std.mem.Allocator, reg: *const entity.Registry, name: []const u8, which: []const u8) ?ActorModel {
    const b = reg.get(name) orelse return null;
    const chain = reg.chain(gpa, b) catch return null;
    defer gpa.free(chain);
    var i = chain.len;
    while (i > 0) {
        i -= 1;
        if (findNamed(chain[i].root, which)) |m| return m;
    }
    return null;
}

fn findModelComponent(e: *const @import("xml.zig").Element) ?ActorModel {
    if (e.attr("modelfile")) |m| if (m.len > 0) {
        const sc = if (e.attr("scale")) |v| std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch 1.0 else 1.0;
        return .{ .file = m, .scale = sc };
    };
    for (e.children) |c| if (findModelComponent(c)) |m| return m;
    return null;
}

fn findNamed(e: *const @import("xml.zig").Element, which: []const u8) ?ActorModel {
    if (std.ascii.eqlIgnoreCase(e.name, "BFNamedBinder")) {
        if (e.attr("binderName")) |n| if (std.ascii.eqlIgnoreCase(n, which)) {
            if (findModelComponent(e)) |m| return m;
        };
    }
    for (e.children) |c| if (findNamed(c, which)) |m| return m;
    return null;
}

/// The head model for a person's entity definition (a `headObj` binder).
pub fn actorHead(gpa: std.mem.Allocator, reg: *const entity.Registry, name: []const u8) ?[]const u8 {
    const b = reg.get(name) orelse return null;
    const chain = reg.chain(gpa, b) catch return null;
    defer gpa.free(chain);
    var i = chain.len;
    while (i > 0) {
        i -= 1;
        if (findHead(chain[i].root)) |m| return m;
    }
    return null;
}

fn findHead(e: *const @import("xml.zig").Element) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(e.name, "BFNamedBinder")) {
        if (e.attr("binderName")) |n| if (std.ascii.eqlIgnoreCase(n, "headObj")) {
            if (findModelFile(e)) |m| return m;
        };
    }
    for (e.children) |c| if (findHead(c)) |m| return m;
    return null;
}

fn findModelFile(e: *const @import("xml.zig").Element) ?[]const u8 {
    if (e.attr("modelfile")) |m| if (m.len > 0) return m;
    for (e.children) |c| if (findModelFile(c)) |m| return m;
    return null;
}

fn findActor(e: *const @import("xml.zig").Element) ?ActorModel {
    if (std.ascii.eqlIgnoreCase(e.name, "BFActorComponent")) {
        if (e.attr("actorfile")) |f| if (f.len > 0) {
            const sc = if (e.attr("scale")) |v| std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch 1.0 else 1.0;
            return .{ .file = f, .scale = sc };
        };
    }
    for (e.children) |c| if (findActor(c)) |m| return m;
    return null;
}

/// Ground textures for a terrain, from the biome definitions: the (up to
/// four) most painted biomes each get a slot, and every vertex blends
/// towards its own.
pub const TerrainLook = struct {
    flat: [4]gl.Uint,
    steep: gl.Uint,
    slot_of: []u8,

    pub fn deinit(self: *TerrainLook, gpa: std.mem.Allocator) void {
        gpa.free(self.slot_of);
    }
};

pub fn terrainLook(gpa: std.mem.Allocator, vfs: *vfs_mod.Vfs, scene: *Scene, terr: *const terrain_mod.Terrain) !TerrainLook {
    var flat_tex = [4]gl.Uint{ scene.white, scene.white, scene.white, scene.white };
    var steep_tex = scene.white;
    const slot_of = try gpa.alloc(u8, terr.paint.len);
    errdefer gpa.free(slot_of);
    var counts: [256]usize = @splat(0);
    for (terr.paint) |b| counts[b] += 1;
    var slots: [4]?u8 = .{ null, null, null, null };
    for (&slots) |*sl| {
        var best: ?u8 = null;
        for (terr.biomes, 0..) |_, bi| {
            if (counts[bi] == 0) continue;
            if (std.mem.indexOfScalar(?u8, &slots, @as(u8, @intCast(bi))) != null) continue;
            if (best == null or counts[bi] > counts[best.?]) best = @intCast(bi);
        }
        sl.* = best;
    }
    for (slots, 0..) |sl, si| {
        const bi = sl orelse continue;
        if (bi >= terr.biomes.len) continue;
        var path_buf: [128]u8 = undefined;
        const bpath = std.fmt.bufPrint(&path_buf, "biomes/{s}.xml", .{terr.biomes[bi]}) catch continue;
        const bytes = vfs.read(gpa, bpath) catch continue;
        defer gpa.free(bytes);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const root = @import("xml.zig").parse(arena.allocator(), bytes, null) catch continue;
        if (root.attr("groundCoverTexture")) |t| flat_tex[si] = scene.loadTexturePath(t);
        if (si == 0) if (root.attr("cliffHoriz")) |t| {
            steep_tex = scene.loadTexturePath(t);
        };
    }
    // Slots with no texture fall back to the main biome's.
    for (&flat_tex) |*t| if (t.* == scene.white) {
        t.* = flat_tex[0];
    };
    for (terr.paint, slot_of) |b, *out| {
        out.* = 0;
        for (slots, 0..) |sl, si| if (sl != null and sl.? == b) {
            out.* = @intCast(si);
        };
    }
    return .{ .flat = flat_tex, .steep = steep_tex, .slot_of = slot_of };
}
