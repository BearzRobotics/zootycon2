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
const bf = @import("bf.zig");
const vfs_mod = @import("vfs.zig");
const platform = @import("platform.zig");

// ------------------------------------------------------------------ math

pub const Mat4 = [16]f32; // column-major

const identity: Mat4 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

fn mul(a: Mat4, b: Mat4) Mat4 {
    var r: Mat4 = undefined;
    for (0..4) |col| for (0..4) |row| {
        var s: f32 = 0;
        for (0..4) |k| s += a[k * 4 + row] * b[col * 4 + k];
        r[col * 4 + row] = s;
    };
    return r;
}

/// The NIF stores a row-major rotation R; a point maps to `scale * R * p + t`.
fn fromTransform(t: nif.Transform) Mat4 {
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
    \\  gl_Position = uViewProj * w;
    \\}
;

const fs_src: [:0]const u8 =
    \\#version 330 core
    \\in vec3 vN;
    \\in vec3 vP;
    \\in vec2 vUv;
    \\uniform sampler2D uTex;
    \\uniform vec4 uTint;
    \\uniform float uAlphaCut;
    \\out vec4 outColor;
    \\void main() {
    \\  vec4 c = texture(uTex, vUv) * uTint;
    \\  if (c.a < uAlphaCut) discard;
    \\  vec3 n = dot(vN, vN) > 1e-6 ? normalize(vN) : normalize(cross(dFdx(vP), dFdy(vP)));
    \\  vec3 l = normalize(vec3(0.4, -0.5, 0.8));
    \\  float d = abs(dot(n, l));
    \\  outColor = vec4(c.rgb * (0.4 + 0.6 * d), c.a);
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
    const vs = try compile(g, gl.VERTEX_SHADER, vs_src);
    const fs = try compile(g, gl.FRAGMENT_SHADER, fs_src);
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

// ------------------------------------------------------------------ scene

const max_bones = 96;

const Skin = struct {
    /// NIF block index of each bone node.
    bones: []const u32,
    /// Geometry space -> bone space, per bone.
    offsets: []const Mat4,
};

const Draw = struct {
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
    /// Loaded models by lowercase path, as draws relative to the model origin.
    models: std.StringHashMapUnmanaged(?[]const Draw) = .empty,

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
        self.arena.deinit();
        var mit = self.models.iterator();
        while (mit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |d| self.gpa.free(d);
        }
        self.models.deinit(self.gpa);
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
        for (nf.roots) |r| self.poseNode(nf, r, identity, anim, t);
    }

    fn poseNode(self: *Scene, nf: *const nif.Nif, ref: nif.Ref, parent: Mat4, anim: ?*const bf.Animation, t: f32) void {
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
                self.world[idx] = w;
                if (n.kind == .lod) {
                    // Child 0 is the most detailed level.
                    if (n.children.len > 0) self.poseNode(nf, n.children[0], w, anim, t);
                    return;
                }
                for (n.children) |c| self.poseNode(nf, c, w, anim, t);
            },
            .geometry => |geo| self.world[idx] = mul(parent, fromTransform(geo.av.transform)),
            else => {},
        }
    }

    fn walk(self: *Scene, nf: *const nif.Nif, ref: nif.Ref) !void {
        if (ref < 0) return;
        switch (nf.blocks[@intCast(ref)]) {
            .node => |n| {
                if (n.av.flags & 1 != 0) return; // hidden
                if (n.kind == .lod) {
                    if (n.children.len > 0) try self.walk(nf, n.children[0]);
                    return;
                }
                for (n.children) |c| try self.walk(nf, c);
            },
            .geometry => |geo| {
                if (geo.av.flags & 1 != 0) return;
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
        for (geo.av.properties) |pr| {
            if (pr < 0) continue;
            switch (nf.blocks[@intCast(pr)]) {
                .texturing => |t| if (t.base) |bt| if (bt.source >= 0) switch (nf.blocks[@intCast(bt.source)]) {
                    .source_texture => |st| if (st.file_name) |fnm| {
                        tex = self.loadTexture(fnm);
                    },
                    else => {},
                },
                .material => |m| {
                    tint = .{ m.diffuse[0], m.diffuse[1], m.diffuse[2], m.alpha };
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
        const buf = try self.gpa.alloc(f32, n * 16);
        @memset(buf, 0);
        defer self.gpa.free(buf);
        const have_n = md.normals.len == n;
        const have_uv = md.uv_sets.len > 0 and md.uv_sets[0].len == n;
        for (0..n) |i| {
            const v = md.vertices[i];
            buf[i * 16 + 0] = v[0];
            buf[i * 16 + 1] = v[1];
            buf[i * 16 + 2] = v[2];
            const nr: nif.Vec3 = if (have_n) md.normals[i] else .{ 0, 0, 0 };
            buf[i * 16 + 3] = nr[0];
            buf[i * 16 + 4] = nr[1];
            buf[i * 16 + 5] = nr[2];
            const uv: [2]f32 = if (have_uv) md.uv_sets[0][i] else .{ 0, 0 };
            buf[i * 16 + 6] = uv[0];
            buf[i * 16 + 7] = uv[1];
            if (self.interactive) {
                const wp = transformPoint(world, v);
                for (0..3) |k| {
                    self.min[k] = @min(self.min[k], wp[k]);
                    self.max[k] = @max(self.max[k], wp[k]);
                }
            }
        }

        const skin = if (self.interactive) try self.buildSkin(nf, geo, buf, n) else null;

        const vao = self.uploadMesh(buf, md.indices.ptr, md.indices.len * 2);

        try self.draws.append(self.gpa, .{
            .dynamic = self.interactive,
            .index_type = gl.UNSIGNED_SHORT,
            .block = block,
            .skin = skin,
            .vao = vao,
            .index_count = @intCast(md.indices.len),
            .world = world,
            .texture = tex,
            .tint = tint,
            .blend = blend,
            .alpha_cut = alpha_cut,
        });
    }

    /// Uploads interleaved vertices (16 floats each: position, normal, uv,
    /// bone indices, bone weights) and an index buffer; returns the vertex array.
    fn uploadMesh(self: *Scene, buf: []const f32, indices: *const anyopaque, index_bytes: usize) gl.Uint {
        const g = self.g;
        var vao: gl.Uint = 0;
        var bufs: [2]gl.Uint = undefined;
        g.genVertexArrays(1, @ptrCast(&vao));
        g.bindVertexArray(vao);
        g.genBuffers(2, &bufs);
        g.bindBuffer(gl.ARRAY_BUFFER, bufs[0]);
        g.bufferData(gl.ARRAY_BUFFER, @intCast(buf.len * 4), buf.ptr, gl.STATIC_DRAW);
        const stride: gl.Sizei = 64;
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
        g.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, bufs[1]);
        g.bufferData(gl.ELEMENT_ARRAY_BUFFER, @intCast(index_bytes), indices, gl.STATIC_DRAW);
        g.bindVertexArray(0);
        return vao;
    }

    /// Adds a terrain mesh: one vertex per grid point, shaded by normals.
    pub fn addTerrain(self: *Scene, t: *const terrain_mod.Terrain, tint: [4]f32) !void {
        const w = t.width;
        const h = t.height;
        const sx = t.spacingX();
        const sy = t.spacingY();
        const buf = try self.gpa.alloc(f32, @as(usize, w) * h * 16);
        defer self.gpa.free(buf);
        @memset(buf, 0);
        for (0..h) |j| for (0..w) |i| {
            const o = (j * w + i) * 16;
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
        const vao = self.uploadMesh(buf, idx.ptr, idx.len * 4);
        try self.draws.append(self.gpa, .{
            .dynamic = false,
            .index_type = gl.UNSIGNED_INT,
            .block = 0,
            .skin = null,
            .vao = vao,
            .index_count = @intCast(idx.len),
            .world = identity,
            .texture = self.white,
            .tint = tint,
            .blend = false,
            .alpha_cut = 0,
        });
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
        const result = try self.buildModel(key);
        try self.models.put(self.gpa, owned_key, result);
        return result;
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
        self.pose(&nf, null, 0);
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

    /// Adds fixed copies of a model's draws, moved by `m`.
    pub fn place(self: *Scene, draws: []const Draw, m: Mat4) !void {
        for (draws) |d| {
            var c = d;
            c.world = mul(m, d.world);
            c.dynamic = false;
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
                buf[v * 16 + 8 + k] = @floatFromInt(infl[v][k].bone);
                buf[v * 16 + 12 + k] = if (sum > 0) infl[v][k].w / sum else if (k == 0) 1 else 0;
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
const Gfx = struct {
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

    fn open(self: *Gfx, opts: Options) !void {
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
    }

    fn close(self: *Gfx) void {
        self.ctx.destroy();
        self.win.destroy();
        self.plat.deinit();
    }
};

const Playback = struct {
    nf: *const nif.Nif,
    anim: *const bf.Animation,
};

const Camera = struct {
    center: [3]f32,
    radius: f32,
    yaw: f32 = -0.8,
    pitch: f32 = 0.45,
    dist: f32,
};

fn loop(gpa: std.mem.Allocator, gfx: *Gfx, scene: *Scene, cam_init: Camera, play: ?Playback, opts: Options) !void {
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

    g.enable(gl.DEPTH_TEST);
    g.depthFunc(gl.LEQUAL);
    g.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    var frame: u32 = 0;
    const start_ms = plat.ticksMs();
    var prev_ms = start_ms;
    main: while (true) {
        while (plat.pollEvent()) |ev| switch (ev) {
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
            .mouse_button => |b| if (b.button == 1) {
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
            },
            .mouse_wheel => |w| cam.dist = std.math.clamp(cam.dist * std.math.pow(f32, 0.9, w.dy), cam.radius * 0.05, cam.radius * 20),
        };

        const now_ms = plat.ticksMs();
        const dt = @as(f32, @floatFromInt(now_ms - prev_ms)) / 1000.0;
        prev_ms = now_ms;
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
        g.clearColor(0.18, 0.2, 0.24, 1);
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

        g.useProgram(gfx.prog);
        g.uniformMatrix4fv(gfx.u_vp, 1, 0, &vp);
        g.uniform1i(gfx.u_tex, 0);
        g.activeTexture(gl.TEXTURE0);
        for (scene.draws.items) |d| {
            if (d.skin) |sk| {
                var mats: [max_bones]Mat4 = undefined;
                for (sk.bones, sk.offsets, 0..) |bn, off, i| mats[i] = mul(scene.world[bn], off);
                g.uniform1i(gfx.u_skinned, 1);
                g.uniformMatrix4fv(gfx.u_bones, @intCast(sk.bones.len), 0, @ptrCast(&mats));
            } else {
                g.uniform1i(gfx.u_skinned, 0);
                g.uniformMatrix4fv(gfx.u_model, 1, 0, if (d.dynamic) &scene.world[d.block] else &d.world);
            }
            g.uniform4f(gfx.u_tint, d.tint[0], d.tint[1], d.tint[2], d.tint[3]);
            g.uniform1f(gfx.u_cut, d.alpha_cut);
            g.bindTexture(gl.TEXTURE_2D, d.texture);
            if (d.blend) g.enable(gl.BLEND) else g.disable(gl.BLEND);
            g.bindVertexArray(d.vao);
            g.drawElements(gl.TRIANGLES, d.index_count, d.index_type, null);
        }

        frame += 1;
        if (opts.screenshot) |w| {
            if (frame < 3) {
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

/// Views a whole map: terrain plus every placed object that has a model.
pub fn runMap(gpa: std.mem.Allocator, vfs: *vfs_mod.Vfs, path: []const u8, opts: Options) !void {
    const map_bytes = try vfs.read(gpa, path);
    defer gpa.free(map_bytes);
    var mp = try map_mod.parse(gpa, map_bytes);
    defer mp.deinit();

    const dir = std.fs.path.dirname(path) orelse "";
    const terr_path = try std.fs.path.join(gpa, &.{ dir, mp.terrain_file });
    defer gpa.free(terr_path);
    const terr_bytes = try vfs.read(gpa, terr_path);
    defer gpa.free(terr_bytes);
    var terr = try terrain_mod.parse(gpa, terr_bytes);
    defer terr.deinit();

    var gfx: Gfx = undefined;
    try gfx.open(opts);
    defer gfx.close();

    var scene = try Scene.init(gpa, &gfx.g, vfs);
    defer scene.deinit();
    scene.interactive = false;
    try scene.addTerrain(&terr, .{ 0.42, 0.55, 0.32, 1 });

    var placed: usize = 0;
    var missing: usize = 0;
    for (mp.objects) |o| {
        const draws = (try scene.loadModel(o.model)) orelse {
            missing += 1;
            continue;
        };
        const m = fromTransform(.{ .translation = o.position, .rotation = o.rotation, .scale = o.scale });
        try scene.place(draws, m);
        placed += 1;
    }
    std.debug.print("{s}: {d}x{d} terrain, {d} objects placed, {d} without a model, {d} textures missing\n", .{
        path, terr.width, terr.height, placed, missing, scene.missing_textures,
    });

    const cx = terr.world_width / 2;
    const cy = terr.world_height / 2;
    const radius = @max(terr.world_width, terr.world_height) / 2;
    const cam: Camera = .{
        .center = .{ cx, cy, terr.zAt(cx, cy) },
        .radius = radius,
        .dist = radius * 1.3,
        .pitch = 0.8,
    };
    try loop(gpa, &gfx, &scene, cam, null, opts);
}
