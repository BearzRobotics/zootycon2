//! The game's own screens (`ui/layout/*.xml`). A layout is a tree of nodes,
//! each with a region (position and size on a 1024x768 canvas, with rules for
//! anchoring and stretching), an image with source rectangles for its button
//! states, and children. This parses a layout and draws it from the game's
//! textures; the caller says what each named node shows and does.

const std = @import("std");
const xml = @import("xml.zig");
const uiskin = @import("uiskin.zig");
const viewer = @import("viewer.zig");

pub const canvas_w: f32 = 1024;
pub const canvas_h: f32 = 768;

pub const Kind = enum { layout, static, button, toggle, text, other };

pub const Rects = struct {
    normal: ?[4]f32 = null,
    highlighted: ?[4]f32 = null,
    activated: ?[4]f32 = null,
    disabled: ?[4]f32 = null,
};

pub const Node = struct {
    kind: Kind,
    name: []const u8,
    template: []const u8,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    xa: uiskin.Align,
    ya: uiskin.Align,
    wa: uiskin.Align,
    ha: uiskin.Align,
    /// `walign="% min"`: the width is a percentage of the parent's.
    w_percent: bool,
    h_percent: bool,
    hidden: bool,
    image: []const u8,
    /// The default source rectangle (w or h <= 0 means to the texture's edge).
    rect: [4]f32,
    color: [4]f32,
    standard: Rects,
    alternate: Rects,
    /// Text colour for `UIText`.
    text_color: [4]f32,
    centered: bool,
    children: []const Node,
};

pub const Layout = struct {
    arena: std.heap.ArenaAllocator,
    root: Node,

    pub fn deinit(self: *Layout) void {
        self.arena.deinit();
    }

    /// The first node with this name, anywhere in the tree.
    pub fn find(self: *const Layout, name: []const u8) ?*const Node {
        return findIn(&self.root, name);
    }
};

fn findIn(n: *const Node, name: []const u8) ?*const Node {
    if (std.ascii.eqlIgnoreCase(n.name, name)) return n;
    for (n.children) |*c| if (findIn(c, name)) |f| return f;
    return null;
}

fn num(e: *const xml.Element, name: []const u8, default: f32) f32 {
    const v = e.attr(name) orelse return default;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch default;
}

fn parseAlign(v: ?[]const u8) struct { a: uiskin.Align, pct: bool } {
    var s = v orelse return .{ .a = .min, .pct = false };
    var pct = false;
    if (std.mem.startsWith(u8, s, "%")) {
        pct = true;
        s = std.mem.trim(u8, s[1..], " ");
    }
    const a: uiskin.Align = if (std.ascii.eqlIgnoreCase(s, "max")) .max else if (std.ascii.eqlIgnoreCase(s, "mid")) .mid else if (std.ascii.eqlIgnoreCase(s, "len")) .len else .min;
    return .{ .a = a, .pct = pct };
}

fn rectOf(e: ?*const xml.Element) ?[4]f32 {
    const r = (e orelse return null).child("BFRect") orelse return null;
    return .{ num(r, "x", 0), num(r, "y", 0), num(r, "w", 0), num(r, "h", 0) };
}

fn rectsOf(e: ?*const xml.Element) Rects {
    const s = e orelse return .{};
    return .{
        .normal = rectOf(s.child("normal")),
        .highlighted = rectOf(s.child("highlighted")),
        .activated = rectOf(s.child("activated")),
        .disabled = rectOf(s.child("disabled")),
    };
}

fn kindOf(tag: []const u8) Kind {
    if (std.ascii.eqlIgnoreCase(tag, "UILayout")) return .layout;
    if (std.ascii.eqlIgnoreCase(tag, "UIStatic")) return .static;
    if (std.ascii.eqlIgnoreCase(tag, "UIText") or std.ascii.eqlIgnoreCase(tag, "ZTMoneyText")) return .text;
    if (std.ascii.eqlIgnoreCase(tag, "UIToggleButton")) return .toggle;
    if (std.ascii.eqlIgnoreCase(tag, "UIButton") or std.ascii.eqlIgnoreCase(tag, "UIPushButton")) return .button;
    return .other;
}

fn build(a: std.mem.Allocator, e: *const xml.Element) !Node {
    const reg = e.child("UIRegion");
    const st = e.child("UIState");
    const asp = e.child("UIAspect");
    const def = if (asp) |x| x.child("default") else null;
    const col = if (def) |d| d.child("BFColor") else null;
    const font = if (def) |d| d.child("BFFont") else null;
    const fcol = if (font) |f| f.child("BFColor") else null;
    const ax = parseAlign(if (reg) |r| r.attr("xalign") else null);
    const ay = parseAlign(if (reg) |r| r.attr("yalign") else null);
    const aw = parseAlign(if (reg) |r| r.attr("walign") else null);
    const ah = parseAlign(if (reg) |r| r.attr("halign") else null);
    var kids: std.ArrayList(Node) = .empty;
    if (e.child("children")) |ch| for (ch.children) |c| {
        if (c.child("UIRegion") == null and kindOf(c.name) == .other) continue;
        try kids.append(a, try build(a, c));
    };
    return .{
        .kind = kindOf(e.name),
        .name = try a.dupe(u8, e.attr("name") orelse ""),
        .template = try a.dupe(u8, e.attr("template") orelse ""),
        .x = if (reg) |r| num(r, "x", 0) else 0,
        .y = if (reg) |r| num(r, "y", 0) else 0,
        .w = if (reg) |r| num(r, "w", 0) else 0,
        .h = if (reg) |r| num(r, "h", 0) else 0,
        .xa = ax.a,
        .ya = ay.a,
        .wa = aw.a,
        .ha = ah.a,
        .w_percent = aw.pct,
        .h_percent = ah.pct,
        .hidden = if (st) |s| if (s.attr("visible")) |v| std.ascii.eqlIgnoreCase(v, "hidden") else false else false,
        .image = if (def) |d| try a.dupe(u8, d.attr("image") orelse "") else "",
        .rect = rectOf(def) orelse .{ 0, 0, 0, 0 },
        .color = if (col) |c| .{ num(c, "r", 255) / 255, num(c, "g", 255) / 255, num(c, "b", 255) / 255, num(c, "a", 255) / 255 } else .{ 1, 1, 1, 1 },
        .standard = rectsOf(if (asp) |x| x.child("standard") else null),
        .alternate = rectsOf(if (asp) |x| x.child("alternate") else null),
        .text_color = if (fcol) |c| .{ num(c, "r", 255) / 255, num(c, "g", 255) / 255, num(c, "b", 255) / 255, 1 } else .{ 1, 1, 1, 1 },
        .centered = if (font) |f| if (f.attr("align")) |v| std.ascii.eqlIgnoreCase(v, "center") else false else false,
        .children = try kids.toOwnedSlice(a),
    };
}

pub fn parse(gpa: std.mem.Allocator, source: []const u8) !Layout {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    // Some files start with a byte-order mark.
    const src = if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) source[3..] else source;
    const root = try xml.parse(a, src, null);
    const node = try build(a, root);
    return .{ .arena = arena, .root = node };
}

/// What the caller says about a node when it is drawn.
pub const Info = struct {
    /// Overrides the file's own visibility when set.
    visible: ?bool = null,
    /// A toggle that is on uses the alternate rectangles.
    on: bool = false,
    enabled: bool = true,
    /// Text for `UIText` nodes.
    text: []const u8 = "",
    /// For percent-width nodes (star bars): the fill, 0..100.
    percent: ?f32 = null,
};

pub const Hooks = struct {
    ctx: *anyopaque,
    info: *const fn (ctx: *anyopaque, n: *const Node) Info,
    /// A button was drawn at this pixel rectangle.
    button: *const fn (ctx: *anyopaque, n: *const Node, rect: [4]f32) void,
};

/// Where the 1024x768 canvas sits on screen: scaled to fit and anchored to
/// the corner a node is nearer to (so bottom panels hug the bottom).
pub const Canvas = struct {
    scale: f32,
    /// Extra offset for nodes anchored right/bottom.
    off_x: f32,
    off_y: f32,

    pub fn fit(width: f32, height: f32) Canvas {
        const s = @min(width / canvas_w, height / canvas_h);
        return .{ .scale = s, .off_x = width - canvas_w * s, .off_y = height - canvas_h * s };
    }
};

pub const Draw = struct {
    ui: *viewer.Ui,
    canvas: Canvas,
    hooks: Hooks,
    mouse: [2]f32,
    pressed: bool,
};

fn axis(pos: f32, size: f32, pa: uiskin.Align, sa: uiskin.Align, pct: bool, total: f32, scale: f32) struct { p: f32, s: f32 } {
    var s: f32 = undefined;
    if (pct) {
        s = total * size / 100.0;
    } else if (sa == .max) {
        s = @max(0, total + size * scale - pos * scale);
    } else s = size * scale;
    const p: f32 = switch (pa) {
        .min, .len => pos * scale,
        .max => total + pos * scale,
        .mid => (total - s) / 2 + pos * scale,
    };
    return .{ .p = p, .s = s };
}

/// Draws a top-level node of a layout (e.g. "Primary Game Button Panel").
pub fn drawTop(d: *Draw, n: *const Node) void {
    const c = d.canvas;
    const cx = n.x + n.w / 2;
    const cy = n.y + n.h / 2;
    const ox: f32 = if (cx > canvas_w / 2) c.off_x else 0;
    const oy: f32 = if (cy > canvas_h / 2) c.off_y else 0;
    drawNode(d, n, .{ ox + n.x * c.scale, oy + n.y * c.scale, n.w * c.scale, n.h * c.scale });
}

/// Draws a node into an explicit pixel box (for pieces of a larger layout).
pub fn drawAt(d: *Draw, n: *const Node, box: [4]f32) void {
    drawNode(d, n, box);
}

fn drawNode(d: *Draw, n: *const Node, box: [4]f32) void {
    const info = d.hooks.info(d.hooks.ctx, n);
    const hidden = if (info.visible) |v| !v else n.hidden;
    if (hidden) return;
    const ui = d.ui;
    const s = d.canvas.scale;

    if (n.template.len > 0) ui.template(n.template, box[0], box[1], box[2], box[3], s, 1.5);

    if (n.kind == .text) {
        if (info.text.len > 0) {
            const ts = @max(1, @round(s * 2));
            const tw = viewer.Ui.textWidth(info.text, ts);
            const tx = if (n.centered) box[0] + (box[2] - tw) / 2 else box[0];
            const ty = box[1] + (box[3] - 7 * ts) / 2;
            _ = ui.text(tx, ty, ts, info.text, n.text_color) catch {};
        }
    } else if (n.image.len > 0) {
        if (ui.sprite(n.image)) |spr| {
            const over = d.mouse[0] >= box[0] and d.mouse[0] < box[0] + box[2] and d.mouse[1] >= box[1] and d.mouse[1] < box[1] + box[3];
            const set = if (n.kind == .toggle and info.on) n.alternate else n.standard;
            var rect = n.rect;
            if (n.kind == .button or n.kind == .toggle) {
                const pick: ?[4]f32 = if (!info.enabled) set.disabled else if (over and d.pressed) set.activated else if (over) set.highlighted else set.normal;
                if (pick) |p| rect = p else if (set.normal) |p| rect = p;
            }
            if (rect[2] <= 0) rect[2] = spr.w - rect[0];
            if (rect[3] <= 0) rect[3] = spr.h - rect[1];
            var dest = box;
            if (info.percent) |pc| {
                const f = std.math.clamp(pc / 100.0, 0, 1);
                dest[2] = box[2] * f;
                rect[2] *= f;
            }
            if (dest[2] > 0 and dest[3] > 0) ui.image(spr, dest[0], dest[1], dest[2], dest[3], rect, n.color) catch {};
        }
    }
    if ((n.kind == .button or n.kind == .toggle) and info.enabled) d.hooks.button(d.hooks.ctx, n, box);

    for (n.children) |*c| {
        const px = axis(c.x, c.w, c.xa, c.wa, c.w_percent, box[2], s);
        const py = axis(c.y, c.h, c.ya, c.ha, c.h_percent, box[3], s);
        drawNode(d, c, .{ box[0] + px.p, box[1] + py.p, px.s, py.s });
    }
}

test "layout nodes parse with regions, rects and states" {
    const src =
        \\<UILayout name="root"><UIRegion x="0" y="540" w="327" h="228" xalign="min" yalign="min" walign="len" halign="len"/>
        \\<UIState active="normal" visible="normal"/><children>
        \\<UIToggleButton name="construction"><UIRegion x="50" y="7" w="64" h="64" xalign="min" yalign="min" walign="len" halign="len"/>
        \\<UIAspect><default image="ui/maingame/buttons.dds"><BFRect x="0" y="0" w="-1" h="-1"/></default>
        \\<standard><normal><BFRect x="0" y="0" w="64" h="64"/></normal><activated><BFRect x="64" y="0" w="64" h="64"/></activated></standard></UIAspect></UIToggleButton>
        \\<UIStatic name="stars"><UIRegion x="0" y="0" w="100" h="32" walign="% min"/><UIState visible="hidden"/></UIStatic>
        \\</children></UILayout>
    ;
    var l = try parse(std.testing.allocator, src);
    defer l.deinit();
    const b = l.find("construction").?;
    try std.testing.expectEqual(Kind.toggle, b.kind);
    try std.testing.expectEqual(@as(f32, 64), b.standard.activated.?[0]);
    const st = l.find("stars").?;
    try std.testing.expect(st.w_percent and st.hidden);
}
