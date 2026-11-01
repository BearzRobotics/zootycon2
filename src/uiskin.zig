//! The game's own UI templates (`ui/template/backs/*.xml`): a panel is a set
//! of `UIStatic` pieces, each a region (position and size with stretch rules)
//! and a source rectangle in a texture atlas. This reads them so panels can
//! be drawn at any size from the game's art, which stays in the player's
//! install.

const std = @import("std");
const xml = @import("xml.zig");

pub const Align = enum { min, max, mid, len };

pub const Piece = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    xa: Align,
    ya: Align,
    wa: Align,
    ha: Align,
    /// VFS path of the texture.
    image: []const u8,
    /// Source rectangle in the texture, in texels.
    rect: [4]f32,
    /// Tint (0..1), including the piece's own alpha.
    color: [4]f32,
};

pub const Template = struct {
    arena: std.heap.ArenaAllocator,
    pieces: []const Piece,

    pub fn deinit(self: *Template) void {
        self.arena.deinit();
    }
};

/// Where a piece lands inside a box of size (bw, bh) at (bx, by), with
/// offsets multiplied by `scale`.
pub fn place(p: Piece, bx: f32, by: f32, bw: f32, bh: f32, scale: f32) [4]f32 {
    const w = axisSize(p.w, p.x, p.wa, bw, scale);
    const h = axisSize(p.h, p.y, p.ha, bh, scale);
    return .{ bx + axisPos(p.x, w, p.xa, bw, scale), by + axisPos(p.y, h, p.ya, bh, scale), w, h };
}

fn axisSize(s: f32, pos: f32, salign: Align, total: f32, scale: f32) f32 {
    // `max`: the size is an offset from the far edge, so the piece stretches.
    if (salign == .max) return @max(0, total + s * scale - pos * scale);
    return s * scale;
}

fn axisPos(pos: f32, size: f32, palign: Align, total: f32, scale: f32) f32 {
    return switch (palign) {
        .min, .len => pos * scale,
        .max => total + pos * scale,
        .mid => (total - size) / 2 + pos * scale,
    };
}

fn parseAlign(v: ?[]const u8) Align {
    const s = v orelse return .min;
    if (std.ascii.eqlIgnoreCase(s, "max")) return .max;
    if (std.ascii.eqlIgnoreCase(s, "mid")) return .mid;
    if (std.ascii.eqlIgnoreCase(s, "len")) return .len;
    return .min;
}

fn num(e: *const xml.Element, name: []const u8) f32 {
    const v = e.attr(name) orelse return 0;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch 0;
}

fn collect(a: std.mem.Allocator, e: *const xml.Element, out: *std.ArrayList(Piece)) !void {
    if (std.ascii.eqlIgnoreCase(e.name, "UIStatic")) {
        const reg = e.child("UIRegion");
        const asp = e.child("UIAspect");
        const def = if (asp) |x| x.child("default") else null;
        if (reg != null and def != null) if (def.?.attr("image")) |img| {
            const rect = def.?.child("BFRect");
            const col = def.?.child("BFColor");
            try out.append(a, .{
                .x = num(reg.?, "x"),
                .y = num(reg.?, "y"),
                .w = num(reg.?, "w"),
                .h = num(reg.?, "h"),
                .xa = parseAlign(reg.?.attr("xalign")),
                .ya = parseAlign(reg.?.attr("yalign")),
                .wa = parseAlign(reg.?.attr("walign")),
                .ha = parseAlign(reg.?.attr("halign")),
                .image = try a.dupe(u8, img),
                .rect = if (rect) |r| .{ num(r, "x"), num(r, "y"), num(r, "w"), num(r, "h") } else .{ 0, 0, 0, 0 },
                .color = if (col) |c| .{ num(c, "r") / 255, num(c, "g") / 255, num(c, "b") / 255, num(c, "a") / 255 } else .{ 1, 1, 1, 1 },
            });
        };
    }
    for (e.children) |c| try collect(a, c, out);
}

pub fn parse(gpa: std.mem.Allocator, source: []const u8) !Template {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const root = try xml.parse(a, source, null);
    var list: std.ArrayList(Piece) = .empty;
    try collect(a, root, &list);
    const pieces = try list.toOwnedSlice(a);
    return .{ .arena = arena, .pieces = pieces };
}

test "template pieces stretch like the game's nine-slice panels" {
    const src =
        \\<UILayout templateName="t"><children>
        \\<UIStatic name="L"><UIRegion x="0" y="0" w="22" h="21" xalign="min" yalign="min" walign="len" halign="len"/>
        \\<UIAspect><default image="UI/a.dds"><BFRect x="0" y="0" w="22" h="21"/><BFColor r="255" g="255" b="255" a="175"/></default></UIAspect></UIStatic>
        \\<UIStatic name="M"><UIRegion x="22" y="0" w="-24" h="21" xalign="min" yalign="min" walign="max" halign="len"/>
        \\<UIAspect><default image="UI/a.dds"><BFRect x="22" y="0" w="18" h="21"/></default></UIAspect></UIStatic>
        \\<UIStatic name="R"><UIRegion x="-24" y="0" w="24" h="21" xalign="max" yalign="min" walign="len" halign="len"/>
        \\<UIAspect><default image="UI/a.dds"><BFRect x="40" y="0" w="24" h="21"/></default></UIAspect></UIStatic>
        \\</children></UILayout>
    ;
    var t = try parse(std.testing.allocator, src);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 3), t.pieces.len);
    try std.testing.expectApproxEqAbs(@as(f32, 175.0 / 255.0), t.pieces[0].color[3], 1e-4);
    const m = place(t.pieces[1], 10, 20, 200, 100, 1);
    try std.testing.expectEqual(@as(f32, 32), m[0]); // 10 + 22
    try std.testing.expectEqual(@as(f32, 154), m[2]); // 200 - 22 - 24
    const r = place(t.pieces[2], 10, 20, 200, 100, 1);
    try std.testing.expectEqual(@as(f32, 186), r[0]); // 10 + 200 - 24
}
