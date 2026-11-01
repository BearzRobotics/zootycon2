//! Static model viewer: flattens a NIF scene graph into draw calls and
//! renders it with OpenGL 3.3 under an orbit camera. Skinning and animation
//! are not applied yet; skinned meshes are drawn in their bind pose.

const std = @import("std");
const Gl = @import("gl.zig").Gl;
const gl = @import("gl.zig");
const nif = @import("nif.zig");
const dds = @import("dds.zig");
const uiskin = @import("uiskin.zig");
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

fn ortho(half: f32, near: f32, far: f32) Mat4 {
    var m = std.mem.zeroes(Mat4);
    m[0] = 1.0 / half;
    m[5] = 1.0 / half;
    m[10] = -2.0 / (far - near);
    m[14] = -(far + near) / (far - near);
    m[15] = 1;
    return m;
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
    \\uniform int uModern;
    \\uniform float uExposure;
    \\uniform int uHdrOut;
    \\uniform int uShadowOn;
    \\uniform sampler2DShadow uShadow;
    \\uniform mat4 uLightVP;
    \\uniform float uShadowTexel;
    \\// Fraction of the sun that reaches this point (1 = fully lit).
    \\float sunVisibility(vec3 pos, float ndl) {
    \\  if (uShadowOn == 0) return 1.0;
    \\  vec4 sc = uLightVP * vec4(pos, 1.0);
    \\  vec3 p = sc.xyz * 0.5 + 0.5;
    \\  if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0 || p.z > 1.0) return 1.0;
    \\  float bias = max(0.0015 * (1.0 - ndl), 0.0004);
    \\  float v = 0.0;
    \\  for (int x = -1; x <= 1; x++) for (int y = -1; y <= 1; y++) {
    \\    v += texture(uShadow, vec3(p.xy + vec2(x, y) * uShadowTexel, p.z - bias));
    \\  }
    \\  return v / 9.0;
    \\}
    \\vec3 toLinear(vec3 c) { return pow(max(c, vec3(0.0)), vec3(2.2)); }
    \\vec3 filmic(vec3 x) {
    \\  // ACES approximation, then back to display gamma.
    \\  vec3 m = clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
    \\  return pow(m, vec3(1.0 / 2.2));
    \\}
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
    \\    // Only sample the textures that actually contribute here.
    \\    vec4 flat_c = c * vW.x;
    \\    if (vW.y > 0.002) flat_c += texture(uFlat1, vUv) * vW.y;
    \\    if (vW.z > 0.002) flat_c += texture(uFlat2, vUv) * vW.z;
    \\    if (vW.w > 0.002) flat_c += texture(uFlat3, vUv) * vW.w;
    \\    c = steep > 0.002 ? mix(flat_c, texture(uTex2, vUv * 0.5), steep) : flat_c;
    \\  }
    \\  if (c.a < uAlphaCut) discard;
    \\  // Two-sided lighting: flip the normal towards the viewer.
    \\  vec3 toEye = uEye - vP;
    \\  if (dot(n, toEye) < 0.0) n = -n;
    \\  // Only the first light (the sun) casts shadows.
    \\  float sunNdl = max(dot(n, -uLdir[uLightSet * 3]), 0.0);
    \\  float vis = sunVisibility(vP, sunNdl);
    \\  vec3 lit = uAmb[uLightSet];
    \\  for (int i = 0; i < 3; i++) {
    \\    float f = i == 0 ? vis : 1.0;
    \\    lit += uLcol[uLightSet * 3 + i] * max(dot(n, -uLdir[uLightSet * 3 + i]), 0.0) * f;
    \\  }
    \\  float fogF = clamp((length(toEye) - uFogRange.x) / max(uFogRange.y - uFogRange.x, 1.0), 0.0, 1.0);
    \\  if (uModern == 1) {
    \\    // Light in linear space: textures and light colours are stored in
    \\    // display gamma, so convert, light, then tone map back.
    \\    vec3 litL = toLinear(uAmb[uLightSet]);
    \\    for (int i = 0; i < 3; i++) {
    \\      float f = i == 0 ? vis : 1.0;
    \\      litL += toLinear(uLcol[uLightSet * 3 + i]) * max(dot(n, -uLdir[uLightSet * 3 + i]), 0.0) * f;
    \\    }
    \\    vec3 colL = mix(toLinear(c.rgb) * litL * uExposure, toLinear(uFogColor) * uExposure, fogF);
    \\    // With post-processing the tone mapping happens at the end.
    \\    outColor = uHdrOut == 1 ? vec4(colL, c.a) : vec4(filmic(colL), c.a);
    \\  } else {
    \\    outColor = vec4(mix(c.rgb * lit, uFogColor, fogF), c.a);
    \\  }
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

pub fn poseWorld(world: []Mat4, nf: *const nif.Nif, root: Mat4, anim: ?*const bf.Animation, t: f32) void {
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
    \\uniform int uModern;
    \\uniform float uExposure;
    \\uniform int uHdrOut;
    \\vec3 toLinear(vec3 c) { return pow(max(c, vec3(0.0)), vec3(2.2)); }
    \\vec3 filmic(vec3 x) {
    \\  vec3 m = clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
    \\  return pow(m, vec3(1.0 / 2.2));
    \\}
    \\out vec4 outColor;
    \\void main() {
    \\  vec3 d = normalize(vDir);
    \\  float s = dot(d, uSunDir);
    \\  float disc = smoothstep(0.9988, 0.9994, s);
    \\  float glow = pow(max(s, 0.0), 48.0) * 0.45;
    \\  vec3 col = vColor + uSunCol * (disc + glow);
    \\  if (uModern == 1) {
    \\    vec3 l = toLinear(col) * uExposure * 0.7;
    \\    col = uHdrOut == 1 ? l : filmic(l);
    \\  }
    \\  outColor = vec4(col, 1.0);
    \\}
;

const shadow_vs: [:0]const u8 =
    \\#version 330 core
    \\layout(location=0) in vec3 aPos;
    \\layout(location=2) in vec2 aUv;
    \\layout(location=3) in vec4 aIdx;
    \\layout(location=4) in vec4 aWeight;
    \\uniform mat4 uBones[96];
    \\uniform int uSkinned;
    \\uniform mat4 uModel;
    \\uniform mat4 uLightVP;
    \\out vec2 vUv;
    \\void main() {
    \\  mat4 m = uModel;
    \\  if (uSkinned == 1) {
    \\    m = aWeight.x * uBones[int(aIdx.x)] + aWeight.y * uBones[int(aIdx.y)]
    \\      + aWeight.z * uBones[int(aIdx.z)] + aWeight.w * uBones[int(aIdx.w)];
    \\  }
    \\  vUv = aUv;
    \\  gl_Position = uLightVP * (m * vec4(aPos, 1.0));
    \\}
;

const shadow_fs: [:0]const u8 =
    \\#version 330 core
    \\in vec2 vUv;
    \\uniform sampler2D uTex;
    \\uniform float uAlphaCut;
    \\void main() {
    \\  // Leaves and fences cast shadows only where they are solid.
    \\  if (texture(uTex, vUv).a < max(uAlphaCut, 0.4)) discard;
    \\}
;

const post_vs: [:0]const u8 =
    \\#version 330 core
    \\out vec2 vUv;
    \\void main() {
    \\  // One triangle covering the screen.
    \\  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    \\  vUv = p;
    \\  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

const ssao_fs: [:0]const u8 =
    \\#version 330 core
    \\in vec2 vUv;
    \\uniform sampler2D uDepth;
    \\uniform vec4 uProj;      // tan(fov/2) * aspect, tan(fov/2), near, far
    \\uniform float uRadius;   // world units
    \\out float ao;
    \\float linearZ(float d) {
    \\  float n = uProj.z, f = uProj.w;
    \\  return 2.0 * n * f / (f + n - (d * 2.0 - 1.0) * (f - n));
    \\}
    \\vec3 viewPos(vec2 uv, float z) {
    \\  vec2 ndc = uv * 2.0 - 1.0;
    \\  return vec3(ndc.x * uProj.x * z, ndc.y * uProj.y * z, -z);
    \\}
    \\float hash(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
    \\void main() {
    \\  float d = texture(uDepth, vUv).r;
    \\  if (d >= 0.99999) { ao = 1.0; return; }
    \\  float z = linearZ(d);
    \\  vec3 P = viewPos(vUv, z);
    \\  vec3 N = normalize(cross(dFdx(P), dFdy(P)));
    \\  if (dot(N, P) > 0.0) N = -N;
    \\  float ang = hash(gl_FragCoord.xy) * 6.2831853;
    \\  float reach = uRadius / (2.0 * uProj.y * z);   // radius as a fraction of screen height
    \\  float occ = 0.0;
    \\  const int taps = 12;
    \\  for (int i = 0; i < taps; i++) {
    \\    float a = ang + float(i) * 2.39996;
    \\    float r = (float(i) + 0.5) / float(taps);
    \\    vec2 off = vec2(cos(a) / (uProj.x / uProj.y), sin(a)) * r * reach;
    \\    vec2 suv = vUv + off;
    \\    float sz = linearZ(texture(uDepth, suv).r);
    \\    vec3 Q = viewPos(suv, sz);
    \\    vec3 V = Q - P;
    \\    float len = length(V);
    \\    float facing = max(dot(N, V) / max(len, 1e-4) - 0.12, 0.0);
    \\    occ += facing * (1.0 - smoothstep(0.0, uRadius * 1.5, len));
    \\  }
    \\  ao = clamp(1.0 - occ / float(taps) * 2.2, 0.0, 1.0);
    \\}
;

const aoblur_fs: [:0]const u8 =
    \\#version 330 core
    \\in vec2 vUv;
    \\uniform sampler2D uAo;
    \\uniform sampler2D uDepth;
    \\uniform vec2 uTexel;
    \\out float ao;
    \\void main() {
    \\  float center = texture(uDepth, vUv).r;
    \\  float sum = 0.0, w = 0.0;
    \\  for (int x = -2; x <= 1; x++) for (int y = -2; y <= 1; y++) {
    \\    vec2 uv = vUv + (vec2(x, y) + 0.5) * uTexel;
    \\    // Do not blur across depth edges (it would leave halos).
    \\    float wt = abs(texture(uDepth, uv).r - center) < 0.0006 ? 1.0 : 0.0;
    \\    sum += texture(uAo, uv).r * wt;
    \\    w += wt;
    \\  }
    \\  ao = w > 0.0 ? sum / w : texture(uAo, vUv).r;
    \\}
;

const bright_fs: [:0]const u8 =
    \\#version 330 core
    \\in vec2 vUv;
    \\uniform sampler2D uHdr;
    \\uniform vec2 uTexel;     // of the source
    \\uniform float uThreshold;
    \\out vec4 outColor;
    \\void main() {
    \\  vec3 c = vec3(0.0);
    \\  for (int x = 0; x < 2; x++) for (int y = 0; y < 2; y++) {
    \\    c += texture(uHdr, vUv + (vec2(x, y) * 2.0 - 1.0) * uTexel).rgb;
    \\  }
    \\  c *= 0.25;
    \\  float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
    \\  float k = max(l - uThreshold, 0.0) / max(l, 1e-3);
    \\  outColor = vec4(c * k, 1.0);
    \\}
;

const blur_fs: [:0]const u8 =
    \\#version 330 core
    \\in vec2 vUv;
    \\uniform sampler2D uTex;
    \\uniform vec2 uDir;       // one texel step along the blur direction
    \\out vec4 outColor;
    \\void main() {
    \\  float w[5] = float[5](0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216);
    \\  vec3 c = texture(uTex, vUv).rgb * w[0];
    \\  for (int i = 1; i < 5; i++) {
    \\    c += texture(uTex, vUv + uDir * float(i)).rgb * w[i];
    \\    c += texture(uTex, vUv - uDir * float(i)).rgb * w[i];
    \\  }
    \\  outColor = vec4(c, 1.0);
    \\}
;

const composite_fs: [:0]const u8 =
    \\#version 330 core
    \\in vec2 vUv;
    \\uniform sampler2D uHdr;
    \\uniform sampler2D uAo;
    \\uniform sampler2D uBloom;
    \\uniform int uUseAo;
    \\uniform int uUseBloom;
    \\uniform float uBloomStrength;
    \\out vec4 outColor;
    \\vec3 filmic(vec3 x) {
    \\  vec3 m = clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
    \\  return pow(m, vec3(1.0 / 2.2));
    \\}
    \\void main() {
    \\  vec3 c = texture(uHdr, vUv).rgb;
    \\  if (uUseAo == 1) c *= mix(1.0, texture(uAo, vUv).r, 0.9);
    \\  if (uUseBloom == 1) c += texture(uBloom, vUv).rgb * uBloomStrength;
    \\  outColor = vec4(filmic(c), 1.0);
    \\}
;

const fxaa_fs: [:0]const u8 =
    \\#version 330 core
    \\in vec2 vUv;
    \\uniform sampler2D uTex;
    \\uniform vec2 uTexel;
    \\out vec4 outColor;
    \\float luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }
    \\void main() {
    \\  vec3 rgbM = texture(uTex, vUv).rgb;
    \\  vec3 rgbNW = texture(uTex, vUv + vec2(-1.0, -1.0) * uTexel).rgb;
    \\  vec3 rgbNE = texture(uTex, vUv + vec2(1.0, -1.0) * uTexel).rgb;
    \\  vec3 rgbSW = texture(uTex, vUv + vec2(-1.0, 1.0) * uTexel).rgb;
    \\  vec3 rgbSE = texture(uTex, vUv + vec2(1.0, 1.0) * uTexel).rgb;
    \\  float lM = luma(rgbM), lNW = luma(rgbNW), lNE = luma(rgbNE), lSW = luma(rgbSW), lSE = luma(rgbSE);
    \\  float lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE)));
    \\  float lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));
    \\  if (lMax - lMin < max(0.03, lMax * 0.125)) { outColor = vec4(rgbM, 1.0); return; }
    \\  vec2 dir = vec2(-((lNW + lNE) - (lSW + lSE)), (lNW + lSW) - (lNE + lSE));
    \\  float reduce = max((lNW + lNE + lSW + lSE) * 0.25 * 0.125, 1.0 / 128.0);
    \\  float rcp = 1.0 / (min(abs(dir.x), abs(dir.y)) + reduce);
    \\  dir = clamp(dir * rcp, vec2(-8.0), vec2(8.0)) * uTexel;
    \\  vec3 a = 0.5 * (texture(uTex, vUv + dir * (1.0 / 3.0 - 0.5)).rgb + texture(uTex, vUv + dir * (2.0 / 3.0 - 0.5)).rgb);
    \\  vec3 b = a * 0.5 + 0.25 * (texture(uTex, vUv + dir * -0.5).rgb + texture(uTex, vUv + dir * 0.5).rgb);
    \\  float lB = luma(b);
    \\  outColor = vec4((lB < lMin || lB > lMax) ? a : b, 1.0);
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
    \\uniform int uSprite;
    \\out vec4 outColor;
    \\void main() {
    \\  vec4 t = texture(uAtlas, vUv);
    \\  outColor = uSprite == 1 ? t * vColor : vec4(vColor.rgb, vColor.a * t.a);
    \\}
;

/// Builds a frame's 2D overlay: rectangles and text in pixel coordinates
/// (origin top-left). Filled by a hook's `overlay`, drawn after the scene.
const UiCmd = struct { tex: gl.Uint, start: u32 };

/// A texture loaded for the overlay, with its size in texels.
pub const Sprite = struct { tex: gl.Uint, w: f32, h: f32 };

pub const Ui = struct {
    gpa: std.mem.Allocator,
    /// Per vertex: x, y, u, v, r, g, b, a.
    verts: std.ArrayList(f32) = .empty,
    /// Pixel size of the viewport.
    width: f32 = 1,
    height: f32 = 1,
    /// Runs of vertices drawn with one texture (0 = the built-in font atlas).
    cmds: std.ArrayList(UiCmd) = .empty,
    cur_tex: gl.Uint = 0,
    /// Where sprites and templates are loaded from.
    scene: ?*Scene = null,

    pub fn deinit(self: *Ui) void {
        self.verts.deinit(self.gpa);
        self.cmds.deinit(self.gpa);
    }

    /// Starts a new frame's overlay.
    pub fn reset(self: *Ui) void {
        self.verts.clearRetainingCapacity();
        self.cmds.clearRetainingCapacity();
        self.cur_tex = 0;
    }

    fn useTex(self: *Ui, tex: gl.Uint) !void {
        const start: u32 = @intCast(self.verts.items.len / 8);
        if (self.cmds.items.len == 0 or self.cur_tex != tex) {
            try self.cmds.append(self.gpa, .{ .tex = tex, .start = start });
            self.cur_tex = tex;
        }
    }

    /// A texture from the game data for use in the overlay.
    pub fn sprite(self: *Ui, path: []const u8) ?Sprite {
        const sc = self.scene orelse return null;
        return sc.sprite(path);
    }

    /// Draws part (sx, sy, sw, sh) of a sprite, in texels, into a rectangle.
    pub fn image(self: *Ui, spr: Sprite, x: f32, y: f32, w: f32, h: f32, src: [4]f32, tint: [4]f32) !void {
        try self.useTex(spr.tex);
        try self.quad(x, y, w, h, src[0] / spr.w, src[1] / spr.h, (src[0] + src[2]) / spr.w, (src[1] + src[3]) / spr.h, tint);
    }

    /// Draws one of the game's panel templates (`ui/template/backs/<name>.xml`)
    /// stretched over a box. `alpha` multiplies the template's own opacity.
    pub fn template(self: *Ui, name: []const u8, x: f32, y: f32, w: f32, h: f32, scale: f32, alpha: f32) void {
        const sc = self.scene orelse return;
        const t = sc.template(name) orelse return;
        for (t.pieces) |p| {
            const spr = sc.sprite(p.image) orelse continue;
            const d = uiskin.place(p, x, y, w, h, scale);
            if (d[2] <= 0 or d[3] <= 0) continue;
            self.image(spr, d[0], d[1], d[2], d[3], p.rect, .{ p.color[0], p.color[1], p.color[2], @min(1, p.color[3] * alpha) }) catch {};
        }
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
        try self.useTex(0);
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
        try self.useTex(0);
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

/// Near clip distance. It follows the zoom so that when the camera is close
/// to something (a guest's head, say) it is not cut off by the near plane.
fn nearFor(cam: Camera) f32 {
    return std.math.clamp(cam.dist * 0.04, 0.05, @max(0.05, cam.radius * 0.01));
}

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

/// Optional rendering features beyond the original game's look.
pub const Fx = struct {
    /// Linear-light shading with filmic tone mapping.
    modern: bool = false,
    exposure: f32 = 1.7,
    /// Sun shadows from a depth map fitted around the camera.
    shadows: bool = false,
    /// Post-processing (needs `modern`): screen-space ambient occlusion,
    /// bloom on bright areas, and edge anti-aliasing.
    ssao: bool = false,
    bloom: bool = false,
    fxaa: bool = false,

    pub fn post(self: Fx) bool {
        return self.modern and (self.ssao or self.bloom or self.fxaa);
    }
};

pub const Scene = struct {
    fx: Fx = .{},
    gpa: std.mem.Allocator,
    g: *const Gl,
    vfs: *vfs_mod.Vfs,
    draws: std.ArrayList(Draw) = .empty,
    /// lowercase basename -> VFS path of a .dds file
    dds_index: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// lowercase basename -> GL texture
    textures: std.StringHashMapUnmanaged(gl.Uint) = .empty,
    sprites: std.StringHashMapUnmanaged(?Sprite) = .empty,
    templates: std.StringHashMapUnmanaged(?uiskin.Template) = .empty,
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
        var sit = self.sprites.iterator();
        while (sit.next()) |e| self.gpa.free(e.key_ptr.*);
        self.sprites.deinit(self.gpa);
        var tit = self.templates.iterator();
        while (tit.next()) |e| {
            if (e.value_ptr.*) |*t| t.deinit();
            self.gpa.free(e.key_ptr.*);
        }
        self.templates.deinit(self.gpa);
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

    /// A UI texture by VFS path (cached, edge-clamped); null if missing.
    pub fn sprite(self: *Scene, path: []const u8) ?Sprite {
        var buf: [256]u8 = undefined;
        if (path.len == 0 or path.len > buf.len) return null;
        const key = std.ascii.lowerString(&buf, path);
        for (buf[0..path.len]) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        if (self.sprites.get(key)) |s| return s;
        var result: ?Sprite = null;
        if (self.vfs.read(self.gpa, key)) |bytes| {
            defer self.gpa.free(bytes);
            if (dds.parse(self.gpa, bytes)) |parsed| {
                var img = parsed;
                defer img.deinit();
                const id = upload(self.g, &img);
                self.g.bindTexture(gl.TEXTURE_2D, id);
                self.g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, @intCast(gl.CLAMP_TO_EDGE));
                self.g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, @intCast(gl.CLAMP_TO_EDGE));
                const l0 = img.level(0, 0);
                result = .{ .tex = id, .w = @floatFromInt(l0.width), .h = @floatFromInt(l0.height) };
            } else |_| {}
        } else |_| {}
        const owned = self.gpa.dupe(u8, key) catch return result;
        self.sprites.put(self.gpa, owned, result) catch self.gpa.free(owned);
        return result;
    }

    /// A panel template from `ui/template/backs/<name>.xml`; null if missing.
    pub fn template(self: *Scene, name: []const u8) ?*const uiskin.Template {
        if (self.templates.getPtr(name)) |t| return if (t.*) |*v| v else null;
        var parsed: ?uiskin.Template = null;
        var pbuf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&pbuf, "ui/template/backs/{s}.xml", .{name})) |path| {
            if (self.vfs.read(self.gpa, path)) |bytes| {
                defer self.gpa.free(bytes);
                parsed = uiskin.parse(self.gpa, bytes) catch null;
            } else |_| {}
        } else |_| {}
        const owned = self.gpa.dupe(u8, name) catch return null;
        self.templates.put(self.gpa, owned, parsed) catch {
            self.gpa.free(owned);
            return null;
        };
        const t = self.templates.getPtr(owned) orelse return null;
        return if (t.*) |*v| v else null;
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
    /// Multisample anti-aliasing samples (0 = off); falls back to none if
    /// the display cannot do it.
    msaa: u32 = 0,
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
const key_q: u32 = 20;
const key_e: u32 = 8;
const key_right: u32 = 79;
const key_left: u32 = 80;
const key_down: u32 = 81;
const key_up: u32 = 82;
const key_lshift: u32 = 225;
const key_rshift: u32 = 229;
const min_pitch: f32 = 0.12;
const max_pitch: f32 = 1.5;

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
    sky_modern: gl.Int,
    sky_exposure: gl.Int,
    post: PostState,
    u_hdr_out: gl.Int,
    sky_hdr_out: gl.Int,
    // shadows (created the first time they are switched on)
    shadow_prog: gl.Uint = 0,
    shadow_fbo: gl.Uint = 0,
    shadow_tex: gl.Uint = 0,
    shadow_size: gl.Sizei = 2048,
    sh_vp: gl.Int = -1,
    sh_model: gl.Int = -1,
    sh_bones: gl.Int = -1,
    sh_skinned: gl.Int = -1,
    sh_tex: gl.Int = -1,
    sh_cut: gl.Int = -1,
    u_shadow_on: gl.Int = -1,
    u_shadow: gl.Int = -1,
    u_light_vp: gl.Int = -1,
    u_shadow_texel: gl.Int = -1,
    u_modern: gl.Int,
    u_exposure: gl.Int,
    // 2D overlay
    ui_prog: gl.Uint,
    ui_screen: gl.Int,
    ui_atlas_loc: gl.Int,
    ui_sprite_loc: gl.Int,
    ui_vao: gl.Uint,
    ui_vbo: gl.Uint,
    ui_tex: gl.Uint,

    pub fn open(self: *Gfx, opts: Options) !void {
        self.plat = platform.Platform.init() catch {
            std.debug.print("SDL init failed: {s}\n", .{platform.lastError()});
            return error.PlatformInit;
        };
        errdefer self.plat.deinit();
        // Try with the requested anti-aliasing, then without it.
        var samples = opts.msaa;
        while (true) {
            self.win = platform.Window.createGl("zootycon2 viewer", opts.width, opts.height, samples) catch {
                if (samples > 0) {
                    samples = 0;
                    continue;
                }
                std.debug.print("window creation failed: {s}\n", .{platform.lastError()});
                return error.PlatformWindow;
            };
            self.ctx = self.win.glCreateContext() catch {
                self.win.destroy();
                if (samples > 0) {
                    samples = 0;
                    continue;
                }
                std.debug.print("OpenGL 3.3 context failed: {s}\n", .{platform.lastError()});
                return error.GlContext;
            };
            break;
        }
        errdefer self.win.destroy();
        errdefer self.ctx.destroy();
        if (opts.msaa > 0 and samples == 0) std.debug.print("anti-aliasing not available; continuing without it\n", .{});
        self.g = .{};
        if (self.g.load(platform.glGetProcAddress)) |missing| {
            std.debug.print("missing OpenGL function: {s}\n", .{missing});
            return error.GlMissing;
        }
        if (opts.screenshot == null) {
            if (self.g.getString(gl.RENDERER)) |r| std.debug.print("renderer: {s}\n", .{r});
        }
        // `Gfx` is created undefined, so its defaults do not apply: set these here.
        self.post = .{};
        self.shadow_prog = 0;
        self.shadow_fbo = 0;
        self.shadow_tex = 0;
        self.shadow_size = 2048;
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
        self.sky_modern = g.getUniformLocation(self.sky_prog, "uModern");
        self.sky_exposure = g.getUniformLocation(self.sky_prog, "uExposure");
        self.u_shadow_on = g.getUniformLocation(self.prog, "uShadowOn");
        self.u_shadow = g.getUniformLocation(self.prog, "uShadow");
        self.u_light_vp = g.getUniformLocation(self.prog, "uLightVP");
        self.u_shadow_texel = g.getUniformLocation(self.prog, "uShadowTexel");
        self.u_hdr_out = g.getUniformLocation(self.prog, "uHdrOut");
        self.sky_hdr_out = g.getUniformLocation(self.sky_prog, "uHdrOut");
        self.u_modern = g.getUniformLocation(self.prog, "uModern");
        self.u_exposure = g.getUniformLocation(self.prog, "uExposure");
        try self.initUi();
    }

    /// Creates the shadow program, depth texture and framebuffer on first use.
    fn ensureShadow(self: *Gfx) bool {
        if (self.shadow_fbo != 0) return true;
        const g = &self.g;
        self.shadow_prog = makeProgramFrom(g, shadow_vs, shadow_fs) catch return false;
        self.sh_vp = g.getUniformLocation(self.shadow_prog, "uLightVP");
        self.sh_model = g.getUniformLocation(self.shadow_prog, "uModel");
        self.sh_bones = g.getUniformLocation(self.shadow_prog, "uBones");
        self.sh_skinned = g.getUniformLocation(self.shadow_prog, "uSkinned");
        self.sh_tex = g.getUniformLocation(self.shadow_prog, "uTex");
        self.sh_cut = g.getUniformLocation(self.shadow_prog, "uAlphaCut");
        g.genTextures(1, @ptrCast(&self.shadow_tex));
        g.bindTexture(gl.TEXTURE_2D, self.shadow_tex);
        g.texImage2D(gl.TEXTURE_2D, 0, @intCast(gl.DEPTH_COMPONENT24), self.shadow_size, self.shadow_size, 0, gl.DEPTH_COMPONENT, gl.FLOAT, null);
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, @intCast(gl.LINEAR));
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, @intCast(gl.LINEAR));
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, @intCast(gl.CLAMP_TO_BORDER));
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, @intCast(gl.CLAMP_TO_BORDER));
        const border = [4]f32{ 1, 1, 1, 1 };
        g.texParameterfv(gl.TEXTURE_2D, gl.TEXTURE_BORDER_COLOR, &border);
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_COMPARE_MODE, @intCast(gl.COMPARE_REF_TO_TEXTURE));
        g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_COMPARE_FUNC, @intCast(gl.LEQUAL));
        g.genFramebuffers(1, @ptrCast(&self.shadow_fbo));
        g.bindFramebuffer(gl.FRAMEBUFFER, self.shadow_fbo);
        g.framebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, self.shadow_tex, 0);
        const none = [1]gl.Enum{gl.NONE};
        g.drawBuffers(1, &none);
        g.readBuffer(gl.NONE);
        const ok = g.checkFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE;
        g.bindFramebuffer(gl.FRAMEBUFFER, 0);
        if (!ok) {
            std.debug.print("shadow framebuffer is not complete; shadows disabled\n", .{});
            self.shadow_fbo = 0;
            return false;
        }
        return true;
    }

    fn initUi(self: *Gfx) !void {
        const g = &self.g;
        self.ui_prog = try makeProgramFrom(g, ui_vs, ui_fs);
        self.ui_screen = g.getUniformLocation(self.ui_prog, "uScreen");
        self.ui_atlas_loc = g.getUniformLocation(self.ui_prog, "uAtlas");
        self.ui_sprite_loc = g.getUniformLocation(self.ui_prog, "uSprite");
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
        g.bindVertexArray(self.ui_vao);
        g.bindBuffer(gl.ARRAY_BUFFER, self.ui_vbo);
        g.bufferData(gl.ARRAY_BUFFER, @intCast(ui.verts.items.len * 4), ui.verts.items.ptr, gl.DYNAMIC_DRAW);
        const total: u32 = @intCast(ui.verts.items.len / 8);
        for (ui.cmds.items, 0..) |c, i| {
            const end: u32 = if (i + 1 < ui.cmds.items.len) ui.cmds.items[i + 1].start else total;
            if (end <= c.start) continue;
            g.uniform1i(self.ui_sprite_loc, if (c.tex == 0) 0 else 1);
            g.bindTexture(gl.TEXTURE_2D, if (c.tex == 0) self.ui_tex else c.tex);
            g.drawArrays(gl.TRIANGLES, @intCast(c.start), @intCast(end - c.start));
        }
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
    /// Set by a hook after it moves the camera directly, so the smoothing
    /// does not drag it back to where it was heading.
    snap_camera: bool = false,
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

/// Offscreen targets and programs for post-processing; created on first use.
const PostState = struct {
    ready: bool = false,
    w: gl.Sizei = 0,
    h: gl.Sizei = 0,
    vao: gl.Uint = 0,
    scene_fbo: gl.Uint = 0,
    color: gl.Uint = 0,
    depth: gl.Uint = 0,
    ao_fbo: [2]gl.Uint = .{ 0, 0 },
    ao_tex: [2]gl.Uint = .{ 0, 0 },
    bloom_fbo: [2]gl.Uint = .{ 0, 0 },
    bloom_tex: [2]gl.Uint = .{ 0, 0 },
    bw: gl.Sizei = 0,
    bh: gl.Sizei = 0,
    ldr_fbo: gl.Uint = 0,
    ldr: gl.Uint = 0,
    ssao: gl.Uint = 0,
    aoblur: gl.Uint = 0,
    bright: gl.Uint = 0,
    blur: gl.Uint = 0,
    composite: gl.Uint = 0,
    fxaa: gl.Uint = 0,
    programs_ok: bool = false,
};

fn makeTarget(g: *const Gl, w: gl.Sizei, h: gl.Sizei, internal: gl.Enum, format: gl.Enum, typ: gl.Enum) gl.Uint {
    var t: gl.Uint = 0;
    g.genTextures(1, @ptrCast(&t));
    g.bindTexture(gl.TEXTURE_2D, t);
    g.texImage2D(gl.TEXTURE_2D, 0, @intCast(internal), w, h, 0, format, typ, null);
    g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, @intCast(gl.LINEAR));
    g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, @intCast(gl.LINEAR));
    g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, @intCast(gl.CLAMP_TO_EDGE));
    g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, @intCast(gl.CLAMP_TO_EDGE));
    return t;
}

fn makeFbo(g: *const Gl, color: gl.Uint, depth: gl.Uint) gl.Uint {
    var f: gl.Uint = 0;
    g.genFramebuffers(1, @ptrCast(&f));
    g.bindFramebuffer(gl.FRAMEBUFFER, f);
    if (color != 0) g.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, color, 0);
    if (depth != 0) g.framebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, depth, 0);
    const ok = g.checkFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE;
    g.bindFramebuffer(gl.FRAMEBUFFER, 0);
    return if (ok) f else 0;
}

/// Builds the programs once and the render targets for the window size.
fn ensurePost(gfx: *Gfx, w: u32, h: u32) bool {
    const g = &gfx.g;
    const p = &gfx.post;
    if (!p.programs_ok) {
        p.ssao = makeProgramFrom(g, post_vs, ssao_fs) catch return false;
        p.aoblur = makeProgramFrom(g, post_vs, aoblur_fs) catch return false;
        p.bright = makeProgramFrom(g, post_vs, bright_fs) catch return false;
        p.blur = makeProgramFrom(g, post_vs, blur_fs) catch return false;
        p.composite = makeProgramFrom(g, post_vs, composite_fs) catch return false;
        p.fxaa = makeProgramFrom(g, post_vs, fxaa_fs) catch return false;
        g.genVertexArrays(1, @ptrCast(&p.vao));
        p.programs_ok = true;
    }
    const iw: gl.Sizei = @intCast(w);
    const ih: gl.Sizei = @intCast(h);
    if (p.ready and p.w == iw and p.h == ih) return true;
    // (Re)create the targets; old ones are simply leaked on resize, which is rare.
    p.color = makeTarget(g, iw, ih, gl.RGBA16F, gl.RGBA, gl.FLOAT);
    p.depth = makeTarget(g, iw, ih, gl.DEPTH_COMPONENT24, gl.DEPTH_COMPONENT, gl.FLOAT);
    g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, @intCast(gl.NEAREST));
    g.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, @intCast(gl.NEAREST));
    p.scene_fbo = makeFbo(g, p.color, p.depth);
    for (0..2) |i| {
        p.ao_tex[i] = makeTarget(g, iw, ih, gl.R8, gl.RED, gl.UNSIGNED_BYTE);
        p.ao_fbo[i] = makeFbo(g, p.ao_tex[i], 0);
    }
    p.bw = @max(iw >> 2, 1);
    p.bh = @max(ih >> 2, 1);
    for (0..2) |i| {
        p.bloom_tex[i] = makeTarget(g, p.bw, p.bh, gl.RGBA16F, gl.RGBA, gl.FLOAT);
        p.bloom_fbo[i] = makeFbo(g, p.bloom_tex[i], 0);
    }
    p.ldr = makeTarget(g, iw, ih, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE);
    p.ldr_fbo = makeFbo(g, p.ldr, 0);
    p.w = iw;
    p.h = ih;
    p.ready = p.scene_fbo != 0 and p.ldr_fbo != 0 and p.ao_fbo[0] != 0 and p.bloom_fbo[0] != 0;
    if (!p.ready) std.debug.print("post-processing targets are not complete; post-processing disabled\n", .{});
    return p.ready;
}

fn bindTex(g: *const Gl, unit: gl.Enum, tex: gl.Uint) void {
    g.activeTexture(gl.TEXTURE0 + unit);
    g.bindTexture(gl.TEXTURE_2D, tex);
}

fn uloc(g: *const Gl, prog: gl.Uint, name: [*:0]const u8) gl.Int {
    return g.getUniformLocation(prog, name);
}

fn fullscreen(g: *const Gl, p: *const PostState) void {
    g.bindVertexArray(p.vao);
    g.drawArrays(gl.TRIANGLES, 0, 3);
}

/// Occlusion, bloom, tone mapping and anti-aliasing over the HDR scene,
/// ending in the default framebuffer.
fn runPost(gfx: *Gfx, fx: Fx, cam: Camera, aspect: f32, near: f32, far: f32, size: struct { width: u32, height: u32 }) void {
    const g = &gfx.g;
    const p = &gfx.post;
    g.disable(gl.DEPTH_TEST);
    g.disable(gl.BLEND);
    g.depthMask(0);
    const tan_y = @tan(Camera.fov_y / 2);

    if (fx.ssao) {
        g.bindFramebuffer(gl.FRAMEBUFFER, p.ao_fbo[0]);
        g.viewport(0, 0, p.w, p.h);
        g.useProgram(p.ssao);
        bindTex(g, 0, p.depth);
        g.uniform1i(uloc(g, p.ssao, "uDepth"), 0);
        g.uniform4f(uloc(g, p.ssao, "uProj"), tan_y * aspect, tan_y, near, far);
        g.uniform1f(uloc(g, p.ssao, "uRadius"), std.math.clamp(cam.dist * 0.04, 0.6, 3.5));
        fullscreen(g, p);
        g.bindFramebuffer(gl.FRAMEBUFFER, p.ao_fbo[1]);
        g.useProgram(p.aoblur);
        bindTex(g, 0, p.ao_tex[0]);
        bindTex(g, 1, p.depth);
        g.uniform1i(uloc(g, p.aoblur, "uAo"), 0);
        g.uniform1i(uloc(g, p.aoblur, "uDepth"), 1);
        g.uniform2f(uloc(g, p.aoblur, "uTexel"), 1.0 / @as(f32, @floatFromInt(p.w)), 1.0 / @as(f32, @floatFromInt(p.h)));
        fullscreen(g, p);
    }
    if (fx.bloom) {
        g.viewport(0, 0, p.bw, p.bh);
        g.bindFramebuffer(gl.FRAMEBUFFER, p.bloom_fbo[0]);
        g.useProgram(p.bright);
        bindTex(g, 0, p.color);
        g.uniform1i(uloc(g, p.bright, "uHdr"), 0);
        g.uniform2f(uloc(g, p.bright, "uTexel"), 1.0 / @as(f32, @floatFromInt(p.w)), 1.0 / @as(f32, @floatFromInt(p.h)));
        g.uniform1f(uloc(g, p.bright, "uThreshold"), 1.1);
        fullscreen(g, p);
        // Two blur rounds, horizontal then vertical each time.
        g.useProgram(p.blur);
        g.uniform1i(uloc(g, p.blur, "uTex"), 0);
        const dir_loc = uloc(g, p.blur, "uDir");
        const tx = 1.0 / @as(f32, @floatFromInt(p.bw));
        const ty = 1.0 / @as(f32, @floatFromInt(p.bh));
        for (0..2) |_| {
            g.bindFramebuffer(gl.FRAMEBUFFER, p.bloom_fbo[1]);
            bindTex(g, 0, p.bloom_tex[0]);
            g.uniform2f(dir_loc, tx, 0);
            fullscreen(g, p);
            g.bindFramebuffer(gl.FRAMEBUFFER, p.bloom_fbo[0]);
            bindTex(g, 0, p.bloom_tex[1]);
            g.uniform2f(dir_loc, 0, ty);
            fullscreen(g, p);
        }
    }

    // Composite (tone mapping), into the LDR target if anti-aliasing follows.
    g.viewport(0, 0, @intCast(size.width), @intCast(size.height));
    g.bindFramebuffer(gl.FRAMEBUFFER, if (fx.fxaa) p.ldr_fbo else 0);
    g.useProgram(p.composite);
    bindTex(g, 0, p.color);
    bindTex(g, 1, p.ao_tex[1]);
    bindTex(g, 2, p.bloom_tex[0]);
    g.uniform1i(uloc(g, p.composite, "uHdr"), 0);
    g.uniform1i(uloc(g, p.composite, "uAo"), 1);
    g.uniform1i(uloc(g, p.composite, "uBloom"), 2);
    g.uniform1i(uloc(g, p.composite, "uUseAo"), @intFromBool(fx.ssao));
    g.uniform1i(uloc(g, p.composite, "uUseBloom"), @intFromBool(fx.bloom));
    g.uniform1f(uloc(g, p.composite, "uBloomStrength"), 0.22);
    fullscreen(g, p);
    if (fx.fxaa) {
        g.bindFramebuffer(gl.FRAMEBUFFER, 0);
        g.useProgram(p.fxaa);
        bindTex(g, 0, p.ldr);
        g.uniform1i(uloc(g, p.fxaa, "uTex"), 0);
        g.uniform2f(uloc(g, p.fxaa, "uTexel"), 1.0 / @as(f32, @floatFromInt(p.w)), 1.0 / @as(f32, @floatFromInt(p.h)));
        fullscreen(g, p);
    }
    g.bindVertexArray(0);
    g.activeTexture(gl.TEXTURE0);
    g.enable(gl.DEPTH_TEST);
    g.depthMask(1);
}

/// Uploads the model matrix (or bone matrices) for a draw.
fn setModelUniforms(g: *const Gl, scene: *Scene, d: Draw, loc_model: gl.Int, loc_bones: gl.Int) void {
    const wl: []const Mat4 = if (d.inst) |i| scene.instances.items[i].world else scene.world;
    if (d.skin) |sk| {
        var mats: [max_bones]Mat4 = undefined;
        for (sk.bones, sk.offsets, 0..) |bn, off, i| mats[i] = mul(wl[bn], off);
        g.uniformMatrix4fv(loc_bones, @intCast(sk.bones.len), 0, @ptrCast(&mats));
    } else if (d.attach_node) |n| {
        const m = mul(wl[n], d.world);
        g.uniformMatrix4fv(loc_model, 1, 0, &m);
    } else {
        g.uniformMatrix4fv(loc_model, 1, 0, if (d.dynamic) &wl[d.block] else &d.world);
    }
}

/// Renders the sun's view of the scene into the shadow map and returns the
/// matrix that maps world positions into it, or null if there is no usable sun.
fn renderShadows(gfx: *Gfx, scene: *Scene, cam: Camera, sun_dir: [3]f32, size: struct { width: u32, height: u32 }) ?Mat4 {
    if (!gfx.ensureShadow()) return null;
    // A sun that is at or below the horizon casts no useful shadows.
    if (sun_dir[2] > -0.12) return null;
    const g = &gfx.g;
    const res: f32 = @floatFromInt(gfx.shadow_size);
    const half = std.math.clamp(cam.dist * 1.25, 30, 260);
    const dir = normalize3(sun_dir);
    const up: [3]f32 = if (@abs(dir[2]) > 0.95) .{ 0, 1, 0 } else .{ 0, 0, 1 };
    const eye = [3]f32{ cam.center[0] - dir[0] * half * 2.5, cam.center[1] - dir[1] * half * 2.5, cam.center[2] - dir[2] * half * 2.5 };
    var lvp = mul(ortho(half, 0.1, half * 5.5), lookAt(eye, cam.center, up));
    // Snap to whole texels so shadows do not shimmer as the camera moves.
    const cx = lvp[0] * cam.center[0] + lvp[4] * cam.center[1] + lvp[8] * cam.center[2] + lvp[12];
    const cy = lvp[1] * cam.center[0] + lvp[5] * cam.center[1] + lvp[9] * cam.center[2] + lvp[13];
    lvp[12] += (@round(cx * res / 2) - cx * res / 2) * 2 / res;
    lvp[13] += (@round(cy * res / 2) - cy * res / 2) * 2 / res;

    g.bindFramebuffer(gl.FRAMEBUFFER, gfx.shadow_fbo);
    g.viewport(0, 0, gfx.shadow_size, gfx.shadow_size);
    g.depthMask(1);
    g.enable(gl.DEPTH_TEST);
    g.disable(gl.BLEND);
    g.clear(gl.DEPTH_BUFFER_BIT);
    g.enable(gl.POLYGON_OFFSET_FILL);
    g.polygonOffset(2.0, 4.0);
    g.useProgram(gfx.shadow_prog);
    g.uniformMatrix4fv(gfx.sh_vp, 1, 0, &lvp);
    g.uniform1i(gfx.sh_tex, 0);
    g.activeTexture(gl.TEXTURE0);
    var last_tex: gl.Uint = std.math.maxInt(u32);
    var last_cut: f32 = -1;
    var last_skin: i32 = -1;
    var last_vao: gl.Uint = std.math.maxInt(u32);
    const lists = [_][]const Draw{ scene.draws.items, scene.actor_draws.items };
    const reach = half * 1.5;
    for (lists) |list| for (list) |d| {
        if (d.blend and !d.depth_write) continue; // ground decals
        if (d.bound[3] >= 0) {
            const dx = d.bound[0] - cam.center[0];
            const dy = d.bound[1] - cam.center[1];
            if (dx * dx + dy * dy > (reach + d.bound[3]) * (reach + d.bound[3])) continue;
            if (d.lod_range[0] > 0 or d.lod_range[1] < std.math.inf(f32)) {
                // Same level-of-detail choice as the camera sees.
                const eye_c = cam.eye();
                const ex = d.bound[0] - eye_c[0];
                const ey = d.bound[1] - eye_c[1];
                const ez = d.bound[2] - eye_c[2];
                const dist = @sqrt(ex * ex + ey * ey + ez * ez);
                if (dist < d.lod_range[0] or dist >= d.lod_range[1]) continue;
            }
        }
        const skinned: i32 = if (d.skin != null) 1 else 0;
        if (skinned != last_skin) {
            g.uniform1i(gfx.sh_skinned, skinned);
            last_skin = skinned;
        }
        setModelUniforms(g, scene, d, gfx.sh_model, gfx.sh_bones);
        if (d.alpha_cut != last_cut) {
            g.uniform1f(gfx.sh_cut, d.alpha_cut);
            last_cut = d.alpha_cut;
        }
        if (d.texture != last_tex) {
            g.bindTexture(gl.TEXTURE_2D, d.texture);
            last_tex = d.texture;
        }
        if (d.vao != last_vao) {
            g.bindVertexArray(d.vao);
            last_vao = d.vao;
        }
        g.drawElements(gl.TRIANGLES, d.index_count, d.index_type, null);
    };
    g.disable(gl.POLYGON_OFFSET_FILL);
    g.bindFramebuffer(gl.FRAMEBUFFER, 0);
    g.viewport(0, 0, @intCast(size.width), @intCast(size.height));
    return lvp;
}

/// What the GL state already holds, so draws only send what changed.
const DrawState = struct {
    tex0: gl.Uint = std.math.maxInt(u32),
    tex1: gl.Uint = std.math.maxInt(u32),
    decal: gl.Uint = std.math.maxInt(u32),
    flat: [3]gl.Uint = .{ std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32) },
    terrain: i32 = -1,
    decal_mode: i32 = -1,
    light_set: i32 = -1,
    skinned: i32 = -1,
    blend: i32 = -1,
    depth_write: i32 = -1,
    vao: gl.Uint = std.math.maxInt(u32),
    tint: [4]f32 = .{ -1, -1, -1, -1 },
    cut: f32 = -1,
};

fn drawItem(gfx: *Gfx, scene: *Scene, d: Draw, fr: *const Frustum, st: *DrawState) void {
    if (!fr.sees(d.bound)) return;
    if (d.bound[3] >= 0 and (d.lod_range[0] > 0 or d.lod_range[1] < std.math.inf(f32))) {
        const dx = d.bound[0] - fr.eye[0];
        const dy = d.bound[1] - fr.eye[1];
        const dz = d.bound[2] - fr.eye[2];
        const dist = @sqrt(dx * dx + dy * dy + dz * dz);
        if (dist < d.lod_range[0] or dist >= d.lod_range[1]) return;
    }
    const g = &gfx.g;
    const is_terrain: i32 = if (d.texture2 != 0) 1 else 0;
    if (is_terrain != st.terrain) {
        g.uniform1i(gfx.u_terrain, is_terrain);
        st.terrain = is_terrain;
    }
    if (is_terrain == 1) {
        if (d.texture2 != st.tex1) {
            g.activeTexture(gl.TEXTURE0 + 1);
            g.bindTexture(gl.TEXTURE_2D, d.texture2);
            st.tex1 = d.texture2;
        }
        for (d.flat_extra, 0..) |tx, i| if (tx != st.flat[i]) {
            g.activeTexture(gl.TEXTURE0 + 3 + @as(gl.Enum, @intCast(i)));
            g.bindTexture(gl.TEXTURE_2D, tx);
            st.flat[i] = tx;
        };
    }
    const mode: i32 = if (d.decal != 0) d.decal_mode else 0;
    if (mode != st.decal_mode) {
        g.uniform1i(gfx.u_decal_mode, mode);
        st.decal_mode = mode;
    }
    if (mode != 0 and d.decal != st.decal) {
        g.activeTexture(gl.TEXTURE0 + 2);
        g.bindTexture(gl.TEXTURE_2D, d.decal);
        st.decal = d.decal;
    }
    if (d.light_set != st.light_set) {
        g.uniform1i(gfx.u_lightset, d.light_set);
        st.light_set = d.light_set;
    }
    const skinned: i32 = if (d.skin != null) 1 else 0;
    if (skinned != st.skinned) {
        g.uniform1i(gfx.u_skinned, skinned);
        st.skinned = skinned;
    }
    setModelUniforms(g, scene, d, gfx.u_model, gfx.u_bones);
    if (!std.mem.eql(f32, &d.tint, &st.tint)) {
        g.uniform4f(gfx.u_tint, d.tint[0], d.tint[1], d.tint[2], d.tint[3]);
        st.tint = d.tint;
    }
    if (d.alpha_cut != st.cut) {
        g.uniform1f(gfx.u_cut, d.alpha_cut);
        st.cut = d.alpha_cut;
    }
    if (d.texture != st.tex0) {
        g.activeTexture(gl.TEXTURE0);
        g.bindTexture(gl.TEXTURE_2D, d.texture);
        st.tex0 = d.texture;
    }
    const blend: i32 = if (d.blend) 1 else 0;
    if (blend != st.blend) {
        if (d.blend) g.enable(gl.BLEND) else g.disable(gl.BLEND);
        st.blend = blend;
    }
    const dw: i32 = if (d.depth_write) 1 else 0;
    if (dw != st.depth_write) {
        g.depthMask(if (d.depth_write) 1 else 0);
        st.depth_write = dw;
    }
    if (d.vao != st.vao) {
        g.bindVertexArray(d.vao);
        st.vao = d.vao;
    }
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
    cam.pitch = std.math.clamp(cam.pitch, min_pitch, max_pitch);
    cam.dist *= opts.zoom;
    var dragging = false; // orbit
    var panning = false; // grab-pan with the middle button
    var last_x: f32 = 0;
    var last_y: f32 = 0;
    var size = gfx.win.pixelSize();
    // w a s d, arrows (left, right, up, down), q, e, shift
    var held = [4]bool{ false, false, false, false };
    var arrows = [4]bool{ false, false, false, false };
    var rot_q = false;
    var rot_e = false;
    var fast = false;
    // The camera eases towards where input has asked it to be.
    var goal = cam;
    const Hk = @typeInfo(@TypeOf(hooks)).pointer.child;
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
                key_left => arrows[0] = true,
                key_right => arrows[1] = true,
                key_up => arrows[2] = true,
                key_down => arrows[3] = true,
                key_q => rot_q = true,
                key_e => rot_e = true,
                key_lshift, key_rshift => fast = true,
                else => {},
            },
            .key_up => |k| switch (k.scancode) {
                key_w => held[0] = false,
                key_a => held[1] = false,
                key_s => held[2] = false,
                key_d => held[3] = false,
                key_left => arrows[0] = false,
                key_right => arrows[1] = false,
                key_up => arrows[2] = false,
                key_down => arrows[3] = false,
                key_q => rot_q = false,
                key_e => rot_e = false,
                key_lshift, key_rshift => fast = false,
                else => {},
            },
            .resized => |r| size = .{ .width = @max(r.width, 1), .height = @max(r.height, 1) },
            .mouse_button => |b| {
                if (b.button == opts.orbit_button) dragging = b.down;
                if (b.button == 2) panning = b.down;
                last_x = b.x;
                last_y = b.y;
            },
            .mouse_move => |m| {
                const dx = m.x - last_x;
                const dy = m.y - last_y;
                if (dragging) {
                    goal.yaw -= dx * 0.006;
                    goal.pitch = std.math.clamp(goal.pitch + dy * 0.006, min_pitch, max_pitch);
                }
                if (panning) {
                    // Grab the ground: it follows the pointer. World units per
                    // pixel at the look-at distance, stretched along the view
                    // direction by the camera's tilt.
                    const wpp = 2 * goal.dist * @tan(Camera.fov_y / 2) / @as(f32, @floatFromInt(@max(ctx.win_height, 1)));
                    const fwd = [2]f32{ -@cos(goal.yaw), -@sin(goal.yaw) };
                    const rgt = [2]f32{ fwd[1], -fwd[0] };
                    const stretch = 1.0 / @max(@sin(goal.pitch), 0.35);
                    goal.center[0] += (-dx * rgt[0] + dy * fwd[0] * stretch) * wpp;
                    goal.center[1] += (-dx * rgt[1] + dy * fwd[1] * stretch) * wpp;
                }
                last_x = m.x;
                last_y = m.y;
                ctx.mouse = .{ m.x, m.y };
            },
            .mouse_wheel => |w| {
                // Zoom towards what is under the pointer: the look-at point
                // moves part of the way to it as the camera comes closer.
                const old = goal.dist;
                const next = std.math.clamp(old * std.math.pow(f32, 0.88, w.dy), @max(3.0, goal.radius * 0.02), goal.radius * 2.6);
                if (next < old) {
                    const r = goal.ray(ctx.mouse[0], ctx.mouse[1], @floatFromInt(ctx.win_width), @floatFromInt(ctx.win_height));
                    if (r.dir[2] < -0.02) {
                        const t = (goal.center[2] - r.origin[2]) / r.dir[2];
                        const px = r.origin[0] + r.dir[0] * t;
                        const py = r.origin[1] + r.dir[1] * t;
                        const f = 1 - next / old;
                        goal.center[0] += (px - goal.center[0]) * f;
                        goal.center[1] += (py - goal.center[1]) * f;
                    }
                }
                goal.dist = next;
            },
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
        if (ctx.snap_camera) {
            goal = cam;
            ctx.snap_camera = false;
        }
        // Keys move the goal; the camera follows smoothly. Using a capped
        // step keeps one slow frame from throwing the camera across the map.
        const cdt = @min(dt, 0.05);
        const fwd = [2]f32{ -@cos(goal.yaw), -@sin(goal.yaw) };
        const right = [2]f32{ fwd[1], -fwd[0] };
        var mv = [2]f32{ 0, 0 };
        if (held[0] or arrows[2]) mv = .{ mv[0] + fwd[0], mv[1] + fwd[1] };
        if (held[2] or arrows[3]) mv = .{ mv[0] - fwd[0], mv[1] - fwd[1] };
        if (held[3] or arrows[1]) mv = .{ mv[0] + right[0], mv[1] + right[1] };
        if (held[1] or arrows[0]) mv = .{ mv[0] - right[0], mv[1] - right[1] };
        const pan_speed = goal.dist * @as(f32, if (fast) 2.2 else 0.9);
        goal.center[0] += mv[0] * pan_speed * cdt;
        goal.center[1] += mv[1] * pan_speed * cdt;
        if (rot_q) goal.yaw += 1.6 * cdt;
        if (rot_e) goal.yaw -= 1.6 * cdt;
        // Stay over the ground when the hook knows its height.
        if (comptime @hasDecl(Hk, "groundZ")) goal.center[2] = hooks.groundZ(goal.center[0], goal.center[1]);
        // Keep the view over the map.
        if (comptime @hasDecl(Hk, "clampCenter")) hooks.clampCenter(&goal.center);
        const ease = 1 - @exp(-16 * cdt);
        const ease_zoom = 1 - @exp(-11 * cdt);
        for (0..3) |i| cam.center[i] += (goal.center[i] - cam.center[i]) * ease;
        cam.yaw += (goal.yaw - cam.yaw) * ease;
        cam.pitch += (goal.pitch - cam.pitch) * ease;
        cam.dist += (goal.dist - cam.dist) * ease_zoom;
        // Never let the eye sink into the ground: tilt up until it clears it.
        if (comptime @hasDecl(Hk, "groundZ")) {
            var iter: usize = 0;
            while (iter < 4) : (iter += 1) {
                const ex = cam.center[0] + cam.dist * @cos(cam.pitch) * @cos(cam.yaw);
                const ey = cam.center[1] + cam.dist * @cos(cam.pitch) * @sin(cam.yaw);
                const need = hooks.groundZ(ex, ey) + 1.5 - cam.center[2];
                if (cam.dist * @sin(cam.pitch) >= need or cam.dist <= 0) break;
                const want = std.math.asin(std.math.clamp(need / cam.dist, -1, 1));
                cam.pitch = std.math.clamp(want + 0.01, cam.pitch, max_pitch);
                goal.pitch = @max(goal.pitch, cam.pitch);
            }
        }

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
        const vp = mul(perspective(0.8, aspect, nearFor(cam), cam.dist + cam.radius * 10), lookAt(eye, cam.center, .{ 0, 0, 1 }));

        if (play) |pb| {
            const t: f32 = opts.time orelse blk: {
                const secs = @as(f32, @floatFromInt(now_ms - start_ms)) / 1000.0;
                break :blk if (pb.anim.duration > 0) @mod(secs, pb.anim.duration) else 0;
            };
            scene.pose(pb.nf, pb.anim, t);
        }

        if (scene.instances.items.len > 0) scene.poseInstances(@as(f32, @floatFromInt(now_ms - start_ms)) / 1000.0);

        // Sun shadows (optional): a depth pass from the sun's point of view.
        var light_vp: ?Mat4 = null;
        if (scene.fx.shadows) {
            const sample = scene.lighting orelse defaultLighting();
            light_vp = renderShadows(gfx, scene, cam, sample.dir[1][0], .{ .width = size.width, .height = size.height });
        }

        // With post-processing the scene renders into an offscreen HDR target.
        const use_post = scene.fx.post() and ensurePost(gfx, size.width, size.height);
        if (use_post) {
            g.bindFramebuffer(gl.FRAMEBUFFER, gfx.post.scene_fbo);
            g.viewport(0, 0, @intCast(size.width), @intCast(size.height));
            if (scene.lighting) |lt| {
                const e = scene.fx.exposure;
                g.clearColor(std.math.pow(f32, lt.fog_color[0], 2.2) * e, std.math.pow(f32, lt.fog_color[1], 2.2) * e, std.math.pow(f32, lt.fog_color[2], 2.2) * e, 1);
            }
            g.depthMask(1);
            g.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
        }

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
            g.uniform1i(gfx.sky_modern, @intFromBool(scene.fx.modern));
            g.uniform1i(gfx.sky_hdr_out, @intFromBool(use_post));
            g.uniform1f(gfx.sky_exposure, scene.fx.exposure);
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
            g.uniform1i(gfx.u_modern, @intFromBool(scene.fx.modern));
            g.uniform1i(gfx.u_hdr_out, @intFromBool(use_post));
            g.uniform1f(gfx.u_exposure, scene.fx.exposure);
            g.uniform1i(gfx.u_shadow_on, if (light_vp != null) 1 else 0);
            if (light_vp) |lv| {
                g.uniformMatrix4fv(gfx.u_light_vp, 1, 0, &lv);
                g.uniform1f(gfx.u_shadow_texel, 1.0 / @as(f32, @floatFromInt(gfx.shadow_size)));
                g.uniform1i(gfx.u_shadow, 6);
                g.activeTexture(gl.TEXTURE6);
                g.bindTexture(gl.TEXTURE_2D, gfx.shadow_tex);
                g.activeTexture(gl.TEXTURE0);
            }
        }
        g.uniform1i(gfx.u_tex, 0);
        g.uniform1i(gfx.u_tex2, 1);
        g.uniform1i(gfx.u_decal, 2);
        for (gfx.u_flat, 0..) |loc, i| g.uniform1i(loc, @intCast(3 + i));
        const frustum = Frustum.init(vp, eye);
        var dstate: DrawState = .{};
        g.activeTexture(gl.TEXTURE0);
        if (scene.terrain) |t| drawItem(gfx, scene, t, &frustum, &dstate);
        for (scene.draws.items) |d| drawItem(gfx, scene, d, &frustum, &dstate);
        for (scene.actor_draws.items) |d| drawItem(gfx, scene, d, &frustum, &dstate);
        for (scene.overlay.items) |d| drawItem(gfx, scene, d, &frustum, &dstate);
        if (use_post) {
            const near = nearFor(cam);
            const far = cam.dist + cam.radius * 10;
            runPost(gfx, scene.fx, cam, aspect, near, far, .{ .width = size.width, .height = size.height });
        }
        if (comptime @hasDecl(Hk, "overlay")) {
            ui.reset();
            ui.scene = scene;
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
