//! Small, forgiving XML parser for the game's data files. Builds an
//! arena-allocated tree of elements; text content, comments and processing
//! instructions are skipped except for element text, which is kept trimmed.
//! Names are compared case-insensitively by callers via `Element.attr`/`child`.

const std = @import("std");

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const Element = struct {
    name: []const u8,
    attributes: []const Attribute = &.{},
    children: []const *Element = &.{},
    /// Concatenated, trimmed character data directly inside this element.
    text: []const u8 = "",

    /// Case-insensitive attribute lookup.
    pub fn attr(self: *const Element, name: []const u8) ?[]const u8 {
        for (self.attributes) |a| {
            if (std.ascii.eqlIgnoreCase(a.name, name)) return a.value;
        }
        return null;
    }

    /// First child element with the given (case-insensitive) name.
    pub fn child(self: *const Element, name: []const u8) ?*const Element {
        for (self.children) |c| {
            if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
        }
        return null;
    }
};

pub const ParseError = error{
    UnexpectedEof,
    UnexpectedCharacter,
    MismatchedTag,
    NoRootElement,
    OutOfMemory,
};

pub const Diagnostic = struct {
    line: usize = 0,
    column: usize = 0,
};

/// Parses `source` into a tree allocated from `arena`. Strings in the result
/// are copies owned by the arena, so `source` may be freed afterwards.
pub fn parse(arena: std.mem.Allocator, source: []const u8, diag: ?*Diagnostic) ParseError!*Element {
    var p: Parser = .{ .arena = arena, .src = source, .pos = 0 };
    return p.document() catch |err| {
        if (diag) |d| {
            d.line = 1;
            d.column = 1;
            for (source[0..@min(p.pos, source.len)]) |c| {
                if (c == '\n') {
                    d.line += 1;
                    d.column = 1;
                } else d.column += 1;
            }
        }
        return err;
    };
}

const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize,

    fn eof(self: *const Parser) bool {
        return self.pos >= self.src.len;
    }

    fn peek(self: *const Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn startsWith(self: *const Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, self.src[self.pos..], s);
    }

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.src.len and std.ascii.isWhitespace(self.src[self.pos])) self.pos += 1;
    }

    /// Skips `<!-- -->`, `<? ?>` and `<!DOCTYPE ...>`; returns true if one was skipped.
    fn skipMisc(self: *Parser) ParseError!bool {
        if (self.startsWith("<!--")) {
            const end = std.mem.indexOfPos(u8, self.src, self.pos + 4, "-->") orelse return error.UnexpectedEof;
            self.pos = end + 3;
        } else if (self.startsWith("<?")) {
            const end = std.mem.indexOfPos(u8, self.src, self.pos + 2, "?>") orelse return error.UnexpectedEof;
            self.pos = end + 2;
        } else if (self.startsWith("<!") and !self.startsWith("<![CDATA[")) {
            // DOCTYPE; tolerate a nested internal subset in [ ].
            var depth: usize = 0;
            while (self.pos < self.src.len) : (self.pos += 1) {
                switch (self.src[self.pos]) {
                    '[' => depth += 1,
                    ']' => depth -|= 1,
                    '>' => if (depth == 0) {
                        self.pos += 1;
                        return true;
                    },
                    else => {},
                }
            }
            return error.UnexpectedEof;
        } else return false;
        return true;
    }

    fn document(self: *Parser) ParseError!*Element {
        if (self.startsWith("\xEF\xBB\xBF")) self.pos += 3;
        while (true) {
            self.skipSpace();
            if (self.eof()) return error.NoRootElement;
            if (try self.skipMisc()) continue;
            if (self.peek().? != '<') return error.UnexpectedCharacter;
            return self.element();
        }
    }

    fn isNameChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == ':' or c == '.' or c >= 0x80;
    }

    fn name(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        while (self.pos < self.src.len and isNameChar(self.src[self.pos])) self.pos += 1;
        if (self.pos == start) return error.UnexpectedCharacter;
        return self.arena.dupe(u8, self.src[start..self.pos]);
    }

    fn element(self: *Parser) ParseError!*Element {
        self.pos += 1; // '<'
        const el = try self.arena.create(Element);
        el.* = .{ .name = try self.name() };

        var attrs: std.ArrayList(Attribute) = .empty;
        while (true) {
            self.skipSpace();
            const c = self.peek() orelse return error.UnexpectedEof;
            if (c == '>') {
                self.pos += 1;
                break;
            }
            if (c == '/') {
                if (!self.startsWith("/>")) return error.UnexpectedCharacter;
                self.pos += 2;
                el.attributes = try attrs.toOwnedSlice(self.arena);
                return el;
            }
            const an = try self.name();
            self.skipSpace();
            if (self.peek() != '=') {
                // Valueless attribute; tolerate it.
                try attrs.append(self.arena, .{ .name = an, .value = "" });
                continue;
            }
            self.pos += 1;
            // Tolerate malformed `name=="value"`.
            while (self.peek() == '=') self.pos += 1;
            self.skipSpace();
            const q = self.peek() orelse return error.UnexpectedEof;
            const value = blk: {
                if (q == '"' or q == '\'') {
                    self.pos += 1;
                    const end = std.mem.indexOfScalarPos(u8, self.src, self.pos, q) orelse return error.UnexpectedEof;
                    const v = try self.decode(self.src[self.pos..end]);
                    self.pos = end + 1;
                    break :blk v;
                }
                // Tolerate unquoted values such as `level=0`.
                const start = self.pos;
                while (self.pos < self.src.len) : (self.pos += 1) {
                    const ch = self.src[self.pos];
                    if (std.ascii.isWhitespace(ch) or ch == '>' or self.startsWith("/>")) break;
                }
                if (self.pos == start) return error.UnexpectedCharacter;
                break :blk try self.decode(self.src[start..self.pos]);
            };
            try attrs.append(self.arena, .{ .name = an, .value = value });
        }
        el.attributes = try attrs.toOwnedSlice(self.arena);

        var kids: std.ArrayList(*Element) = .empty;
        var text: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.eof()) return error.UnexpectedEof;
            if (self.startsWith("</")) {
                self.pos += 2;
                const close = try self.name();
                self.skipSpace();
                if (self.peek() != '>') return error.UnexpectedCharacter;
                self.pos += 1;
                if (!std.ascii.eqlIgnoreCase(close, el.name)) return error.MismatchedTag;
                break;
            }
            if (self.startsWith("<![CDATA[")) {
                const end = std.mem.indexOfPos(u8, self.src, self.pos + 9, "]]>") orelse return error.UnexpectedEof;
                try text.appendSlice(self.arena, self.src[self.pos + 9 .. end]);
                self.pos = end + 3;
            } else if (try self.skipMisc()) {
                // skipped
            } else if (self.peek().? == '<') {
                try kids.append(self.arena, try self.element());
            } else {
                const end = std.mem.indexOfScalarPos(u8, self.src, self.pos, '<') orelse self.src.len;
                try text.appendSlice(self.arena, self.src[self.pos..end]);
                self.pos = end;
            }
        }
        el.children = try kids.toOwnedSlice(self.arena);
        const trimmed = std.mem.trim(u8, text.items, " \t\r\n");
        el.text = if (std.mem.indexOfScalar(u8, trimmed, '&') != null)
            try self.decode(trimmed)
        else
            try self.arena.dupe(u8, trimmed);
        return el;
    }

    /// Expands the predefined and numeric character references.
    fn decode(self: *Parser, raw: []const u8) ParseError![]const u8 {
        if (std.mem.indexOfScalar(u8, raw, '&') == null) return self.arena.dupe(u8, raw);
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] != '&') {
                try out.append(self.arena, raw[i]);
                i += 1;
                continue;
            }
            const semi = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse {
                try out.append(self.arena, '&'); // stray ampersand; keep it
                i += 1;
                continue;
            };
            const ent = raw[i + 1 .. semi];
            if (std.mem.eql(u8, ent, "amp")) {
                try out.append(self.arena, '&');
            } else if (std.mem.eql(u8, ent, "lt")) {
                try out.append(self.arena, '<');
            } else if (std.mem.eql(u8, ent, "gt")) {
                try out.append(self.arena, '>');
            } else if (std.mem.eql(u8, ent, "quot")) {
                try out.append(self.arena, '"');
            } else if (std.mem.eql(u8, ent, "apos")) {
                try out.append(self.arena, '\'');
            } else if (ent.len > 1 and ent[0] == '#') {
                const cp = (if (ent[1] == 'x' or ent[1] == 'X')
                    std.fmt.parseInt(u21, ent[2..], 16)
                else
                    std.fmt.parseInt(u21, ent[1..], 10)) catch {
                    try out.appendSlice(self.arena, raw[i .. semi + 1]);
                    i = semi + 1;
                    continue;
                };
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch {
                    try out.appendSlice(self.arena, raw[i .. semi + 1]);
                    i = semi + 1;
                    continue;
                };
                try out.appendSlice(self.arena, buf[0..n]);
            } else {
                try out.appendSlice(self.arena, raw[i .. semi + 1]); // unknown entity: keep verbatim
            }
            i = semi + 1;
        }
        return out.toOwnedSlice(self.arena);
    }
};

test "parses elements, attributes, text and entities" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\<?xml version="1.0"?>
        \\<!-- c -->
        \\<Root a="1" B='x &amp; y'>
        \\  <Kid Name="k"/>
        \\  <Kid2>hi &lt;there&gt;</Kid2>
        \\  <![CDATA[raw <b>]]>
        \\</Root>
    ;
    const root = try parse(arena.allocator(), src, null);
    try std.testing.expectEqualStrings("Root", root.name);
    try std.testing.expectEqualStrings("1", root.attr("A").?);
    try std.testing.expectEqualStrings("x & y", root.attr("b").?);
    try std.testing.expectEqual(@as(usize, 2), root.children.len);
    try std.testing.expectEqualStrings("k", root.child("kid").?.attr("name").?);
    try std.testing.expectEqualStrings("hi <there>", root.child("Kid2").?.text);
    try std.testing.expectEqualStrings("raw <b>", root.text);
}

test "tolerates unquoted values and doubled equals" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(), "<a level=0 s=\"x\" t==\"zz\"/>", null);
    try std.testing.expectEqualStrings("0", root.attr("level").?);
    try std.testing.expectEqualStrings("zz", root.attr("t").?);
}

test "reports mismatched tags with a position" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    try std.testing.expectError(error.MismatchedTag, parse(arena.allocator(), "<a>\n<b></c></a>", &d));
    try std.testing.expectEqual(@as(usize, 2), d.line);
}
