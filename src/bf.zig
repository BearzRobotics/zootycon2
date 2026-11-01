//! Reader for `.bf` skeletal animation files, decoded from the game data
//! (no public documentation exists). What is understood:
//!
//!   u32 version (1 or 2), f32 duration in seconds, u16 bone count, u16 flags
//!   per bone record:
//!     char name[32]; u16 track_count; u16 0xCCCC; u32 record_size (from the
//!     start of the name); u16 0; u16 0xCCCC; then `track_count` tracks
//!   per track (8-byte header): u16 type, u16 key_count, u16 track_size
//!     (header included), u16 unknown, then keys:
//!       type 0x0E  rotation, 10 bytes/key: u16 ms, i16 x,y,z,w (/10000)
//!       type 0x0C  rotation, 16 bytes/key: same 10 bytes + 6 unknown
//!       type 0x02  translation, 8 bytes/key: u16 ms, i16 x,y,z (/1000)
//!       type 0x01  translation, 20 bytes/key: as 0x02 + 12 unknown bytes
//!   Types 6, 7, 8 look like Euler angles X, Y, Z in radians * 1000 (a
//!   `Floor` node holds 1.570 and 3.141) but are not applied yet. Other
//!   track types (3, 4, 0x10, 0x11) are skipped by size.
//!   After the bones come text-key markers, which are ignored here.

const std = @import("std");

pub const RotKey = struct { time: f32, q: [4]f32 }; // x, y, z, w
pub const PosKey = struct { time: f32, p: [3]f32 };

pub const Bone = struct {
    name: []const u8,
    rot: []const RotKey,
    pos: []const PosKey,
};

pub const Animation = struct {
    arena: std.heap.ArenaAllocator,
    duration: f32,
    bones: []const Bone,
    /// Tracks of types this reader does not decode.
    skipped_tracks: u32,

    pub fn deinit(self: *Animation) void {
        self.arena.deinit();
    }

    pub fn bone(self: *const Animation, name: []const u8) ?*const Bone {
        for (self.bones) |*b| if (std.ascii.eqlIgnoreCase(b.name, name)) return b;
        return null;
    }
};

pub const Error = error{ BadAnimation, OutOfMemory };

const quat_scale: f32 = 10000.0;
const pos_scale: f32 = 1000.0;

fn u16le(d: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, d[at..][0..2], .little);
}
fn i16le(d: []const u8, at: usize) i16 {
    return std.mem.readInt(i16, d[at..][0..2], .little);
}
fn u32le(d: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, d[at..][0..4], .little);
}

pub fn parse(gpa: std.mem.Allocator, data: []const u8) Error!Animation {
    if (data.len < 12) return error.BadAnimation;
    const version = u32le(data, 0);
    if (version != 1 and version != 2) return error.BadAnimation;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const duration: f32 = @bitCast(u32le(data, 4));
    const n_bones = u16le(data, 8);
    const bones = try a.alloc(Bone, n_bones);
    var skipped: u32 = 0;

    var pos: usize = 12;
    for (bones) |*b| {
        if (pos + 0x2c > data.len) return error.BadAnimation;
        const size = u32le(data, pos + 0x24);
        if (size < 0x2c or size > data.len - pos) return error.BadAnimation;
        const end = pos + size;
        const raw_name = data[pos..][0..32];
        const name_len = std.mem.indexOfScalar(u8, raw_name, 0) orelse 32;
        const n_tracks = u16le(data, pos + 0x20);

        var rot: std.ArrayList(RotKey) = .empty;
        var tr: std.ArrayList(PosKey) = .empty;
        var p = pos + 0x2c;
        for (0..n_tracks) |_| {
            if (p + 8 > end) return error.BadAnimation;
            const typ = u16le(data, p);
            const count = u16le(data, p + 2);
            const tsize = u16le(data, p + 4);
            if (tsize < 8 or p + tsize > end) return error.BadAnimation;
            const keys = data[p + 8 .. p + tsize];
            switch (typ) {
                0x0e, 0x0c => {
                    const stride: usize = if (typ == 0x0e) 10 else 16;
                    if (keys.len != stride * count) return error.BadAnimation;
                    for (0..count) |k| {
                        const o = k * stride;
                        try rot.append(a, .{
                            .time = @as(f32, @floatFromInt(u16le(keys, o))) / 1000.0,
                            .q = .{
                                @as(f32, @floatFromInt(i16le(keys, o + 2))) / quat_scale,
                                @as(f32, @floatFromInt(i16le(keys, o + 4))) / quat_scale,
                                @as(f32, @floatFromInt(i16le(keys, o + 6))) / quat_scale,
                                @as(f32, @floatFromInt(i16le(keys, o + 8))) / quat_scale,
                            },
                        });
                    }
                },
                0x02, 0x01 => {
                    const stride: usize = if (typ == 0x02) 8 else 20;
                    if (keys.len != stride * count) return error.BadAnimation;
                    for (0..count) |k| {
                        const o = k * stride;
                        try tr.append(a, .{
                            .time = @as(f32, @floatFromInt(u16le(keys, o))) / 1000.0,
                            .p = .{
                                @as(f32, @floatFromInt(i16le(keys, o + 2))) / pos_scale,
                                @as(f32, @floatFromInt(i16le(keys, o + 4))) / pos_scale,
                                @as(f32, @floatFromInt(i16le(keys, o + 6))) / pos_scale,
                            },
                        });
                    }
                },
                else => skipped += 1,
            }
            p += tsize;
        }
        if (p != end) return error.BadAnimation;
        b.* = .{
            .name = try a.dupe(u8, raw_name[0..name_len]),
            .rot = try rot.toOwnedSlice(a),
            .pos = try tr.toOwnedSlice(a),
        };
        pos = end;
    }
    return .{ .arena = arena, .duration = duration, .bones = bones, .skipped_tracks = skipped };
}

// -------------------------------------------------------------- sampling

fn findSegment(times: anytype, t: f32) struct { i: usize, f: f32 } {
    // `times` is a slice of keys with a `.time` field, sorted ascending.
    const n = times.len;
    if (t <= times[0].time) return .{ .i = 0, .f = 0 };
    if (t >= times[n - 1].time) return .{ .i = n - 1, .f = 0 };
    var i: usize = 0;
    while (i + 1 < n and times[i + 1].time <= t) i += 1;
    const span = times[i + 1].time - times[i].time;
    return .{ .i = i, .f = if (span > 0) (t - times[i].time) / span else 0 };
}

/// Interpolated rotation (normalized lerp along the shortest arc), or null
/// if the bone has no rotation keys.
pub fn sampleRot(b: *const Bone, t: f32) ?[4]f32 {
    if (b.rot.len == 0) return null;
    const s = findSegment(b.rot, t);
    const a = b.rot[s.i].q;
    if (s.f == 0 or s.i + 1 >= b.rot.len) return a;
    var c = b.rot[s.i + 1].q;
    const dot = a[0] * c[0] + a[1] * c[1] + a[2] * c[2] + a[3] * c[3];
    if (dot < 0) for (&c) |*x| {
        x.* = -x.*;
    };
    var r: [4]f32 = undefined;
    for (0..4) |i| r[i] = a[i] + (c[i] - a[i]) * s.f;
    const len = @sqrt(r[0] * r[0] + r[1] * r[1] + r[2] * r[2] + r[3] * r[3]);
    if (len > 0) for (&r) |*x| {
        x.* /= len;
    };
    return r;
}

pub fn samplePos(b: *const Bone, t: f32) ?[3]f32 {
    if (b.pos.len == 0) return null;
    const s = findSegment(b.pos, t);
    const a = b.pos[s.i].p;
    if (s.f == 0 or s.i + 1 >= b.pos.len) return a;
    const c = b.pos[s.i + 1].p;
    return .{ a[0] + (c[0] - a[0]) * s.f, a[1] + (c[1] - a[1]) * s.f, a[2] + (c[2] - a[2]) * s.f };
}

test "synthetic one-bone animation" {
    var buf: [12 + 0x2c + 8 + 10 + 8 + 8 * 2]u8 = undefined;
    @memset(&buf, 0);
    const w = std.mem.writeInt;
    w(u32, buf[0..4], 2, .little);
    w(u32, buf[4..8], @bitCast(@as(f32, 1.0)), .little);
    w(u16, buf[8..10], 1, .little);
    const b = buf[12..];
    @memcpy(b[0..3], "Abc");
    w(u16, b[0x20..][0..2], 2, .little);
    w(u32, b[0x24..][0..4], 0x2c + 18 + 24, .little);
    // rotation track: identity at t=0
    var p: usize = 0x2c;
    w(u16, b[p..][0..2], 0x0e, .little);
    w(u16, b[p + 2 ..][0..2], 1, .little);
    w(u16, b[p + 4 ..][0..2], 18, .little);
    w(i16, b[p + 16 ..][0..2], 10000, .little); // w
    p += 18;
    // translation track: two keys
    w(u16, b[p..][0..2], 0x02, .little);
    w(u16, b[p + 2 ..][0..2], 2, .little);
    w(u16, b[p + 4 ..][0..2], 24, .little);
    w(u16, b[p + 8 ..][0..2], 0, .little);
    w(i16, b[p + 10 ..][0..2], 1000, .little);
    w(u16, b[p + 16 ..][0..2], 1000, .little);
    w(i16, b[p + 18 ..][0..2], 3000, .little);

    var anim = try parse(std.testing.allocator, &buf);
    defer anim.deinit();
    try std.testing.expectEqual(@as(usize, 1), anim.bones.len);
    const bone = anim.bone("abc").?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sampleRot(bone, 0.3).?[3], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), samplePos(bone, 0.5).?[0], 1e-5);
}

test "rejects garbage" {
    try std.testing.expectError(error.BadAnimation, parse(std.testing.allocator, "nope"));
}
