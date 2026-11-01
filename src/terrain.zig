//! Terrain files (`.dat`, referenced by `terrFile` in a map's `.zt2`).
//! Layout as decoded from the game's maps:
//!
//!   u32 version (10 to 14 seen), f32 world_width, f32 world_height (world units),
//!   f32 tile_w, f32 tile_h (3.0), u32 5, u32 5, u32 grid_w, u32 grid_h
//!   (vertices; 4 per tile + 1), u32 9, u32 9, u32 name_count, then
//!   `name_count` strings (u32 length including NUL, bytes) naming the biomes
//!   that can be painted on the map.
//!   Then grid_w * grid_h vertex records, row-major with x varying fastest.
//!   Every record starts with the same 26 bytes:
//!     f32 height; f32 a (0..0.2, meaning unknown); u32 b (the biome painted
//!     here, an index into the name table); u32 c; u16 d;
//!     f32 base (6.0); f32 top (26.0)
//!   followed by 1 to 4 more bytes whose count depends on the file version
//!   (record sizes of 27, 28, 29 and 30 occur), so the stride is detected
//!   from the data (see `detectStride`).
//!   The world-space z of a vertex is `height + base`; objects placed on the
//!   ground in a `.zt2` sit at exactly that z.
//!   After the grid come per-tile flags (not decoded yet).

const std = @import("std");

pub const Terrain = struct {
    arena: std.heap.ArenaAllocator,
    /// Vertex counts.
    width: u32,
    height: u32,
    world_width: f32,
    world_height: f32,
    biomes: []const []const u8,
    /// World-space z for each vertex, row-major, x fastest. Editable;
    /// `encode` writes edits back into the original file layout.
    z: []f32,
    /// Biome painted on each vertex: an index into `biomes`.
    paint: []const u8,
    /// The file as read, so everything not understood survives a save.
    raw: []const u8,
    first_record: usize,
    stride: usize,

    pub fn deinit(self: *Terrain) void {
        self.arena.deinit();
    }

    pub fn spacingX(self: *const Terrain) f32 {
        return self.world_width / @as(f32, @floatFromInt(self.width - 1));
    }

    pub fn spacingY(self: *const Terrain) f32 {
        return self.world_height / @as(f32, @floatFromInt(self.height - 1));
    }

    /// The terrain file with the current heights written into it.
    pub fn encode(self: *const Terrain, gpa: std.mem.Allocator) ![]u8 {
        const out = try gpa.dupe(u8, self.raw);
        for (self.z, 0..) |z, i| {
            const rec = self.first_record + i * self.stride;
            const base = f32le(out, rec + 18);
            std.mem.writeInt(u32, out[rec..][0..4], @bitCast(z - base), .little);
        }
        return out;
    }

    /// Bilinearly interpolated ground height at a world position (clamped to the map).
    pub fn zAt(self: *const Terrain, x: f32, y: f32) f32 {
        const fx = std.math.clamp(x / self.spacingX(), 0, @as(f32, @floatFromInt(self.width - 1)));
        const fy = std.math.clamp(y / self.spacingY(), 0, @as(f32, @floatFromInt(self.height - 1)));
        const x0: u32 = @min(@as(u32, @intFromFloat(fx)), self.width - 2);
        const y0: u32 = @min(@as(u32, @intFromFloat(fy)), self.height - 2);
        const tx = fx - @as(f32, @floatFromInt(x0));
        const ty = fy - @as(f32, @floatFromInt(y0));
        const w = self.width;
        const a = self.z[y0 * w + x0];
        const b = self.z[y0 * w + x0 + 1];
        const c = self.z[(y0 + 1) * w + x0];
        const d = self.z[(y0 + 1) * w + x0 + 1];
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty;
    }
};

pub const Error = error{ BadTerrain, OutOfMemory };

/// Height of the water surface. Stock maps keep their flat ground at 13 and
/// every pool, river and sea floor lies below this level (lakes bottom out
/// around 3.5), so terrain under it is under water.
pub const water_level: f32 = 12.0;
/// Where the flat ground of a new map sits.
pub const ground_level: f32 = 13.0;

fn u32le(d: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, d[at..][0..4], .little);
}
fn f32le(d: []const u8, at: usize) f32 {
    return @bitCast(u32le(d, at));
}

const record_prefix = 26;
const max_stride = 40;

fn plausible(v: f32) bool {
    return std.math.isFinite(v) and @abs(v) < 1000;
}

/// Finds the record size: the smallest stride at which every sampled record
/// has a plausible `base` and the same `top` as the first record (`top` is
/// 26.0 in every map seen; `base` varies on some maps).
fn detectStride(data: []const u8, start: usize, count: usize) ?usize {
    if (start + record_prefix > data.len) return null;
    const top0 = f32le(data, start + 22);
    if (!plausible(top0)) return null;
    var stride: usize = record_prefix;
    while (stride <= max_stride) : (stride += 1) {
        if (count * stride > data.len - start) return null;
        var ok = true;
        const samples = @min(count, 256);
        for (0..samples) |k| {
            const i = if (k + 1 == samples) count - 1 else k;
            const rec = start + i * stride;
            if (!plausible(f32le(data, rec + 18)) or f32le(data, rec + 22) != top0 or !plausible(f32le(data, rec))) {
                ok = false;
                break;
            }
        }
        if (ok) return stride;
    }
    return null;
}

pub fn parse(gpa: std.mem.Allocator, data: []const u8) Error!Terrain {
    if (data.len < 0x30 or u32le(data, 0) < 10 or u32le(data, 0) > 16) return error.BadTerrain;
    const world_w = f32le(data, 4);
    const world_h = f32le(data, 8);
    const w = u32le(data, 28);
    const h = u32le(data, 32);
    if (w < 2 or h < 2 or w > 4096 or h > 4096 or !(world_w > 0) or !(world_h > 0)) return error.BadTerrain;
    const n_names = u32le(data, 44);
    if (n_names > 64) return error.BadTerrain;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const names = try a.alloc([]const u8, n_names);
    var pos: usize = 48;
    for (names) |*name| {
        if (pos + 4 > data.len) return error.BadTerrain;
        const len = u32le(data, pos);
        pos += 4;
        if (len > data.len - pos) return error.BadTerrain;
        const raw = data[pos..][0..len];
        name.* = try a.dupe(u8, std.mem.sliceTo(raw, 0));
        pos += len;
    }

    const count = @as(usize, w) * h;
    const stride = detectStride(data, pos, count) orelse return error.BadTerrain;
    const z = try a.alloc(f32, count);
    const paint = try a.alloc(u8, count);
    for (z, paint, 0..) |*out, *pt, i| {
        const rec = pos + i * stride;
        out.* = f32le(data, rec) + f32le(data, rec + 18);
        pt.* = @intCast(@min(u32le(data, rec + 8), 255));
    }
    // Allocate everything before copying the arena into the result.
    const raw = try a.dupe(u8, data);
    return .{
        .arena = arena,
        .width = w,
        .height = h,
        .world_width = world_w,
        .world_height = world_h,
        .biomes = names,
        .z = z,
        .paint = paint,
        .raw = raw,
        .first_record = pos,
        .stride = stride,
    };
}

/// Biomes a blank map can be painted with (the order of the stock maps).
pub const blank_biomes = [_][]const u8{
    "temperateforest", "borealforest", "alpine", "desert", "grassland", "gridland",
    "tropicalrainforest", "savannah", "scrub", "tundra", "wetlands", "zoodecoration",
};

/// A flat map of `tiles_x` by `tiles_y` tiles (3 world units each, 4 grid
/// vertices per tile) painted with one biome, built by writing a terrain file
/// and parsing it so it behaves like any other map.
pub fn blank(gpa: std.mem.Allocator, tiles_x: u32, tiles_y: u32, biome: u8) Error!Terrain {
    const gw = tiles_x * 4 + 1;
    const gh = tiles_y * 4 + 1;
    const rs = 28;
    var names_len: usize = 0;
    for (blank_biomes) |n| names_len += 4 + n.len + 1;
    const total = 48 + names_len + @as(usize, gw) * gh * rs;
    const buf = try gpa.alloc(u8, total);
    defer gpa.free(buf);
    @memset(buf, 0);
    const w = std.mem.writeInt;
    w(u32, buf[0..4], 11, .little);
    w(u32, buf[4..8], @bitCast(@as(f32, @floatFromInt(tiles_x)) * 3.0), .little);
    w(u32, buf[8..12], @bitCast(@as(f32, @floatFromInt(tiles_y)) * 3.0), .little);
    w(u32, buf[12..16], @bitCast(@as(f32, 3.0)), .little);
    w(u32, buf[16..20], @bitCast(@as(f32, 3.0)), .little);
    w(u32, buf[20..24], 5, .little);
    w(u32, buf[24..28], 5, .little);
    w(u32, buf[28..32], gw, .little);
    w(u32, buf[32..36], gh, .little);
    w(u32, buf[36..40], 9, .little);
    w(u32, buf[40..44], 9, .little);
    w(u32, buf[44..48], blank_biomes.len, .little);
    var pos: usize = 48;
    for (blank_biomes) |n| {
        w(u32, buf[pos..][0..4], @intCast(n.len + 1), .little);
        pos += 4;
        @memcpy(buf[pos..][0..n.len], n);
        pos += n.len + 1;
    }
    const count = @as(usize, gw) * gh;
    for (0..count) |i| {
        const rec = pos + i * rs;
        w(u32, buf[rec..][0..4], @bitCast(ground_level - 6.0), .little);
        w(u32, buf[rec + 8 ..][0..4], biome, .little);
        w(u32, buf[rec + 18 ..][0..4], @bitCast(@as(f32, 6.0)), .little);
        w(u32, buf[rec + 22 ..][0..4], @bitCast(@as(f32, 26.0)), .little);
    }
    return parse(gpa, buf);
}

test "blank terrain parses back flat with the chosen biome" {
    var t = try blank(std.testing.allocator, 4, 3, 7);
    defer t.deinit();
    try std.testing.expectEqual(@as(u32, 17), t.width);
    try std.testing.expectEqual(@as(u32, 13), t.height);
    try std.testing.expectEqual(@as(f32, 12.0), t.world_width);
    try std.testing.expectEqual(@as(f32, 9.0), t.world_height);
    try std.testing.expectApproxEqAbs(ground_level, t.z[100], 1e-6);
    try std.testing.expectEqual(@as(u8, 7), t.paint[50]);
    try std.testing.expectEqualStrings("savannah", t.biomes[t.paint[50]]);
}

test "synthetic 3x2 terrain" {
    const rs = 28;
    var buf: [48 + 4 + 4 + 6 * rs]u8 = undefined;
    @memset(&buf, 0);
    const w = std.mem.writeInt;
    w(u32, buf[0..4], 11, .little);
    w(u32, buf[4..8], @bitCast(@as(f32, 6.0)), .little);
    w(u32, buf[8..12], @bitCast(@as(f32, 3.0)), .little);
    w(u32, buf[28..32], 3, .little);
    w(u32, buf[32..36], 2, .little);
    w(u32, buf[44..48], 1, .little);
    w(u32, buf[48..52], 4, .little);
    @memcpy(buf[52..55], "abc");
    for (0..6) |i| {
        const rec = 56 + i * rs;
        w(u32, buf[rec..][0..4], @bitCast(@as(f32, @floatFromInt(i))), .little);
        w(u32, buf[rec + 18 ..][0..4], @bitCast(@as(f32, 6.0)), .little);
        w(u32, buf[rec + 22 ..][0..4], @bitCast(@as(f32, 26.0)), .little);
    }
    var t = try parse(std.testing.allocator, &buf);
    defer t.deinit();
    try std.testing.expectEqual(@as(u32, 3), t.width);
    try std.testing.expectEqualStrings("abc", t.biomes[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), t.z[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 11.0), t.z[5], 1e-6);
    // x spacing 3, y spacing 3: halfway along x on row 0 averages z[0], z[1]
    try std.testing.expectApproxEqAbs(@as(f32, 6.5), t.zAt(1.5, 0), 1e-5);
    // edits survive an encode/parse round trip
    t.z[4] = 20.0;
    const enc = try t.encode(std.testing.allocator);
    defer std.testing.allocator.free(enc);
    var t2 = try parse(std.testing.allocator, enc);
    defer t2.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), t2.z[4], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), t2.z[0], 1e-5);
}

test "rejects garbage" {
    try std.testing.expectError(error.BadTerrain, parse(std.testing.allocator, "short"));
}
