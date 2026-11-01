//! DirectDraw Surface (DDS) texture loader.
//!
//! Block-compressed formats (DXT1/3/5) are kept compressed so they can be
//! uploaded to the GPU as-is. Every uncompressed format found in the game
//! data (16-bit 565/4444/1555, 24-bit, 32-bit and 8-bit luminance) is
//! converted to RGBA8 at load time.

const std = @import("std");

pub const Format = enum {
    dxt1,
    dxt3,
    dxt5,
    /// 4 bytes per pixel: R, G, B, A.
    rgba8,

    pub fn blockBytes(self: Format) usize {
        return switch (self) {
            .dxt1 => 8,
            .dxt3, .dxt5 => 16,
            .rgba8 => 0,
        };
    }
};

pub const Level = struct {
    width: u32,
    height: u32,
    /// Byte offset into `Image.data` and length of this mip level.
    offset: usize,
    len: usize,
};

pub const Image = struct {
    arena: std.heap.ArenaAllocator,
    width: u32,
    height: u32,
    format: Format,
    /// 1 for ordinary textures, 6 for cube maps.
    faces: u32,
    mip_count: u32,
    /// `levels[face * mip_count + mip]`
    levels: []const Level,
    data: []const u8,

    pub fn deinit(self: *Image) void {
        self.arena.deinit();
    }

    pub fn level(self: *const Image, face: u32, mip: u32) Level {
        return self.levels[face * self.mip_count + mip];
    }

    pub fn levelData(self: *const Image, face: u32, mip: u32) []const u8 {
        const l = self.level(face, mip);
        return self.data[l.offset..][0..l.len];
    }
};

pub const Error = error{ NotDds, Unsupported, Truncated, OutOfMemory };

const header_size = 4 + 124;

fn rd(data: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, data[off..][0..4], .little);
}

fn levelSize(format: Format, w: u32, h: u32) usize {
    return switch (format) {
        .rgba8 => @as(usize, w) * h * 4,
        else => @as(usize, (w + 3) / 4) * ((h + 3) / 4) * format.blockBytes(),
    };
}

/// Channel layout of an uncompressed pixel format.
const Masks = struct { r: u32, g: u32, b: u32, a: u32, bytes: u32 };

fn extract(px: u32, mask: u32) u8 {
    if (mask == 0) return 255;
    const shift: u5 = @intCast(@ctz(mask));
    const max = mask >> shift;
    const v = (px & mask) >> shift;
    return @intCast((@as(u64, v) * 255 + max / 2) / max);
}

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (bytes.len < header_size or !std.mem.eql(u8, bytes[0..4], "DDS ")) return error.NotDds;
    const height = rd(bytes, 12);
    const width = rd(bytes, 16);
    var mips = rd(bytes, 28);
    if (mips == 0) mips = 1;
    if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.Unsupported;
    const pf_flags = rd(bytes, 80);
    const four_cc = bytes[84..88];
    const caps2 = rd(bytes, 112);

    var faces: u32 = 1;
    if (caps2 & 0x200 != 0) {
        faces = @popCount(caps2 & 0xFC00);
        if (faces == 0) faces = 6;
    }

    var format: Format = .rgba8;
    var masks: Masks = undefined;
    var luminance = false;
    if (pf_flags & 0x4 != 0) {
        if (std.mem.eql(u8, four_cc, "DXT1")) {
            format = .dxt1;
        } else if (std.mem.eql(u8, four_cc, "DXT3")) {
            format = .dxt3;
        } else if (std.mem.eql(u8, four_cc, "DXT5")) {
            format = .dxt5;
        } else return error.Unsupported;
    } else if (pf_flags & 0x20000 != 0) {
        luminance = true;
        masks = .{ .r = rd(bytes, 92), .g = 0, .b = 0, .a = 0, .bytes = rd(bytes, 88) / 8 };
    } else if (pf_flags & 0x40 != 0) {
        masks = .{ .r = rd(bytes, 92), .g = rd(bytes, 96), .b = rd(bytes, 100), .a = if (pf_flags & 0x1 != 0) rd(bytes, 104) else 0, .bytes = rd(bytes, 88) / 8 };
    } else return error.Unsupported;
    if (format == .rgba8 and (masks.bytes < 1 or masks.bytes > 4)) return error.Unsupported;

    var img: Image = .{
        .arena = .init(gpa),
        .width = width,
        .height = height,
        .format = format,
        .faces = faces,
        .mip_count = 0,
        .levels = &.{},
        .data = &.{},
    };
    errdefer img.arena.deinit();
    const a = img.arena.allocator();

    // Work out how many mip levels the file actually contains.
    const src_bytes_per_px: usize = if (format == .rgba8) masks.bytes else 0;
    var avail_mips: u32 = 0;
    {
        var w = width;
        var h = height;
        var m: u32 = 0;
        var need: usize = 0;
        while (m < mips) : (m += 1) {
            const sz = if (format == .rgba8) @as(usize, w) * h * src_bytes_per_px else levelSize(format, w, h);
            need += sz * faces;
            if (header_size + need > bytes.len) break;
            avail_mips = m + 1;
            w = @max(1, w / 2);
            h = @max(1, h / 2);
        }
    }
    if (avail_mips == 0) return error.Truncated;
    img.mip_count = avail_mips;

    // Convert (or copy) into one contiguous buffer, ordered face-major.
    const levels = try a.alloc(Level, @as(usize, faces) * avail_mips);
    var out_total: usize = 0;
    {
        var f: u32 = 0;
        while (f < faces) : (f += 1) {
            var w = width;
            var h = height;
            for (0..avail_mips) |m| {
                const sz = levelSize(format, w, h);
                levels[f * avail_mips + m] = .{ .width = w, .height = h, .offset = out_total, .len = sz };
                out_total += sz;
                w = @max(1, w / 2);
                h = @max(1, h / 2);
            }
        }
    }
    const out = try a.alloc(u8, out_total);
    var src_pos: usize = header_size;
    for (levels) |lv| {
        const dst = out[lv.offset..][0..lv.len];
        if (format != .rgba8) {
            @memcpy(dst, bytes[src_pos..][0..lv.len]);
            src_pos += lv.len;
        } else {
            const npx = @as(usize, lv.width) * lv.height;
            for (0..npx) |i| {
                var px: u32 = 0;
                for (0..masks.bytes) |b| px |= @as(u32, bytes[src_pos + i * masks.bytes + b]) << @intCast(8 * b);
                const o = dst[i * 4 ..][0..4];
                if (luminance) {
                    const l = extract(px, masks.r);
                    o.* = .{ l, l, l, 255 };
                } else {
                    o.* = .{ extract(px, masks.r), extract(px, masks.g), extract(px, masks.b), extract(px, masks.a) };
                }
            }
            src_pos += npx * masks.bytes;
        }
    }
    img.levels = levels;
    img.data = out;
    return img;
}

// ---- software decoding of block-compressed data (tests, tools) ----

fn rgb565(c: u16) [3]u8 {
    return .{
        @intCast((@as(u32, (c >> 11) & 31) * 255 + 15) / 31),
        @intCast((@as(u32, (c >> 5) & 63) * 255 + 31) / 63),
        @intCast((@as(u32, c & 31) * 255 + 15) / 31),
    };
}

/// Decodes one 8-byte DXT1 color block into 16 RGBA pixels. `punch` enables
/// the 1-bit-alpha mode used by DXT1 (colour0 <= colour1).
fn decodeColorBlock(block: []const u8, out: *[16][4]u8, dxt1: bool) void {
    const c0 = std.mem.readInt(u16, block[0..2], .little);
    const c1 = std.mem.readInt(u16, block[2..4], .little);
    const p0 = rgb565(c0);
    const p1 = rgb565(c1);
    var pal: [4][4]u8 = undefined;
    pal[0] = .{ p0[0], p0[1], p0[2], 255 };
    pal[1] = .{ p1[0], p1[1], p1[2], 255 };
    if (c0 > c1 or !dxt1) {
        for (0..3) |i| {
            pal[2][i] = @intCast((2 * @as(u32, p0[i]) + @as(u32, p1[i])) / 3);
            pal[3][i] = @intCast((@as(u32, p0[i]) + 2 * @as(u32, p1[i])) / 3);
        }
        pal[2][3] = 255;
        pal[3][3] = 255;
    } else {
        for (0..3) |i| pal[2][i] = @intCast((@as(u32, p0[i]) + p1[i]) / 2);
        pal[2][3] = 255;
        pal[3] = .{ 0, 0, 0, 0 };
    }
    const bits = std.mem.readInt(u32, block[4..8], .little);
    for (0..16) |i| out[i] = pal[(bits >> @intCast(2 * i)) & 3];
}

/// Decodes a compressed or RGBA8 level to tightly packed RGBA8.
/// Caller owns the result.
pub fn decodeLevel(gpa: std.mem.Allocator, img: *const Image, face: u32, mip: u32) Error![]u8 {
    const lv = img.level(face, mip);
    const src = img.levelData(face, mip);
    const out = try gpa.alloc(u8, @as(usize, lv.width) * lv.height * 4);
    errdefer gpa.free(out);
    if (img.format == .rgba8) {
        @memcpy(out, src);
        return out;
    }
    const bw = (lv.width + 3) / 4;
    const bh = (lv.height + 3) / 4;
    const bb = img.format.blockBytes();
    for (0..bh) |by| {
        for (0..bw) |bx| {
            const block = src[(by * bw + bx) * bb ..][0..bb];
            var px: [16][4]u8 = undefined;
            switch (img.format) {
                .dxt1 => decodeColorBlock(block, &px, true),
                .dxt3 => {
                    decodeColorBlock(block[8..16], &px, false);
                    for (0..16) |i| {
                        const nib = (block[i / 2] >> @intCast(4 * (i % 2))) & 15;
                        px[i][3] = nib * 17;
                    }
                },
                .dxt5 => {
                    decodeColorBlock(block[8..16], &px, false);
                    const a0: u32 = block[0];
                    const a1: u32 = block[1];
                    var tab: [8]u8 = undefined;
                    tab[0] = @intCast(a0);
                    tab[1] = @intCast(a1);
                    if (a0 > a1) {
                        for (1..7) |i| tab[i + 1] = @intCast(((7 - i) * a0 + i * a1) / 7);
                    } else {
                        for (1..5) |i| tab[i + 1] = @intCast(((5 - i) * a0 + i * a1) / 5);
                        tab[6] = 0;
                        tab[7] = 255;
                    }
                    var bits: u64 = 0;
                    for (0..6) |i| bits |= @as(u64, block[2 + i]) << @intCast(8 * i);
                    for (0..16) |i| px[i][3] = tab[@intCast((bits >> @intCast(3 * i)) & 7)];
                },
                .rgba8 => unreachable,
            }
            for (0..4) |y| {
                for (0..4) |x| {
                    const ox = bx * 4 + x;
                    const oy = by * 4 + y;
                    if (ox < lv.width and oy < lv.height) @memcpy(out[(oy * lv.width + ox) * 4 ..][0..4], &px[y * 4 + x]);
                }
            }
        }
    }
    return out;
}

// ---- tests ----

fn testHeader(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, w: u32, h: u32, mips: u32, pf_flags: u32, fourcc: []const u8, bpp: u32, masks: [4]u32) !void {
    var hdr: [header_size]u8 = @splat(0);
    @memcpy(hdr[0..4], "DDS ");
    std.mem.writeInt(u32, hdr[4..8], 124, .little);
    std.mem.writeInt(u32, hdr[12..16], h, .little);
    std.mem.writeInt(u32, hdr[16..20], w, .little);
    std.mem.writeInt(u32, hdr[28..32], mips, .little);
    std.mem.writeInt(u32, hdr[76..80], 32, .little);
    std.mem.writeInt(u32, hdr[80..84], pf_flags, .little);
    if (fourcc.len == 4) @memcpy(hdr[84..88], fourcc);
    std.mem.writeInt(u32, hdr[88..92], bpp, .little);
    for (masks, 0..) |m, i| std.mem.writeInt(u32, hdr[92 + 4 * i ..][0..4], m, .little);
    try buf.appendSlice(gpa, &hdr);
}

test "rejects garbage" {
    try std.testing.expectError(error.NotDds, parse(std.testing.allocator, "not a dds file at all"));
}

test "dxt1 block decodes to its colours" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try testHeader(&buf, gpa, 4, 4, 1, 0x4, "DXT1", 0, .{ 0, 0, 0, 0 });
    // colour0 = pure red (565: f800), colour1 = pure blue (001f), all indices 0.
    try buf.appendSlice(gpa, &.{ 0x00, 0xf8, 0x1f, 0x00, 0, 0, 0, 0 });
    var img = try parse(gpa, buf.items);
    defer img.deinit();
    try std.testing.expectEqual(Format.dxt1, img.format);
    const px = try decodeLevel(gpa, &img, 0, 0);
    defer gpa.free(px);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, px[0..4]);
}

test "rgb565 converts to rgba8 and extra mips are dropped when truncated" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    // Claims 3 mips but only holds the 2x2 top level.
    try testHeader(&buf, gpa, 2, 2, 3, 0x40, "", 16, .{ 0xf800, 0x07e0, 0x001f, 0 });
    try buf.appendSlice(gpa, &.{ 0x00, 0xf8, 0xe0, 0x07, 0x1f, 0x00, 0xff, 0xff });
    var img = try parse(gpa, buf.items);
    defer img.deinit();
    try std.testing.expectEqual(@as(u32, 1), img.mip_count);
    const d = img.levelData(0, 0);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, d[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, d[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, d[8..12]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255 }, d[12..16]);
}

test "8-bit luminance expands to grey" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try testHeader(&buf, gpa, 1, 1, 1, 0x20000, "", 8, .{ 0xff, 0, 0, 0 });
    try buf.append(gpa, 128);
    var img = try parse(gpa, buf.items);
    defer img.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 128, 128, 128, 255 }, img.levelData(0, 0));
}
