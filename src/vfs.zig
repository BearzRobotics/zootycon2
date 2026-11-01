//! Virtual filesystem over a Zoo Tycoon 2 install. Layers archives so a path
//! resolves to the highest-priority file that provides it, then falls back to
//! loose files on disk.
//!
//! Priority (lowest to highest): loose files in the install directory, then
//! archives in the order they were added. `addInstall` adds the base archives
//! sorted by name, then downloadable-content archives sorted by path, so
//! expansions and DLC override the base game.

const std = @import("std");
const Io = std.Io;
const Archive = @import("archive.zig").Archive;

pub const Vfs = struct {
    gpa: std.mem.Allocator,
    io: Io,
    archives: std.ArrayList(*Archive) = .empty,
    /// Normalized path -> archive that currently wins for it.
    winners: std.StringHashMapUnmanaged(*Archive) = .empty,
    /// Normalized path -> real path on disk (owned by `strings`).
    loose: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Mod/override files: normalized path -> absolute real path. These win
    /// over everything else (texture packs, replacement data).
    over: std.StringHashMapUnmanaged([]const u8) = .empty,
    strings: std.heap.ArenaAllocator,
    root: ?Io.Dir = null,

    pub fn init(gpa: std.mem.Allocator, io: Io) Vfs {
        return .{ .gpa = gpa, .io = io, .strings = .init(gpa) };
    }

    pub fn deinit(self: *Vfs) void {
        for (self.archives.items) |a| a.close();
        self.archives.deinit(self.gpa);
        self.winners.deinit(self.gpa);
        self.loose.deinit(self.gpa);
        self.over.deinit(self.gpa);
        self.strings.deinit();
        if (self.root) |d| d.close(self.io);
    }

    /// Adds an archive above everything added so far.
    pub fn addArchive(self: *Vfs, path: []const u8) !void {
        const a = try Archive.open(self.gpa, self.io, path);
        errdefer a.close();
        try self.archives.append(self.gpa, a);
        var it = a.index.keyIterator();
        while (it.next()) |name| try self.winners.put(self.gpa, name.*, a);
    }

    /// Mounts an install directory: loose files, base archives, then DLC.
    pub fn addInstall(self: *Vfs, root_path: []const u8) !void {
        const io = self.io;
        const root = try Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = true });
        self.root = root;
        const arena = self.strings.allocator();

        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(self.gpa);

        var walker = try root.walk(self.gpa);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (e.kind != .file) continue;
            const real = try arena.dupe(u8, e.path);
            const key = try normalize(arena, real);
            if (std.mem.endsWith(u8, key, ".z2f")) {
                try paths.append(self.gpa, real);
            } else if (!std.mem.startsWith(u8, key, "dlc/")) {
                try self.loose.put(self.gpa, key, real);
            }
        }

        // Base archives (top level) first, then DLC; each group sorted by path.
        const Ctx = struct {
            fn rank(p: []const u8) u8 {
                return if (std.mem.indexOfAny(u8, p, "/\\") == null) 0 else 1;
            }
            fn less(_: void, a: []const u8, b: []const u8) bool {
                const ra = rank(a);
                const rb = rank(b);
                if (ra != rb) return ra < rb;
                return std.ascii.lessThanIgnoreCase(a, b);
            }
        };
        std.mem.sort([]const u8, paths.items, {}, Ctx.less);

        for (paths.items) |rel| {
            const full = try std.fs.path.join(self.gpa, &.{ root_path, rel });
            defer self.gpa.free(full);
            try self.addArchive(full);
        }
    }

    /// Mounts every z2f found under `dir_path` (sorted by path) above what is
    /// already mounted. An archive with the same file name and size as one
    /// already mounted is skipped: DLC installers keep a duplicate download
    /// cache, and mounting both would only double the memory.
    pub fn addExtraDir(self: *Vfs, dir_path: []const u8) !void {
        const io = self.io;
        var dir = try Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var rels: std.ArrayList([]const u8) = .empty;
        var walker = try dir.walk(self.gpa);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (e.kind == .file and std.ascii.endsWithIgnoreCase(e.basename, ".z2f"))
                try rels.append(arena.allocator(), try arena.allocator().dupe(u8, e.path));
        }
        std.mem.sort([]const u8, rels.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.ascii.lessThanIgnoreCase(a, b);
            }
        }.less);
        for (rels.items) |rel| {
            const full = try std.fs.path.join(self.gpa, &.{ dir_path, rel });
            defer self.gpa.free(full);
            const st = try Io.Dir.cwd().statFile(io, full, .{});
            if (self.hasArchive(std.fs.path.basename(full), st.size)) continue;
            try self.addArchive(full);
        }
    }

    /// Mounts a folder of loose files that override the game's: a file at
    /// `<dir>/textures/foo.dds` replaces `textures/foo.dds`. Later calls win.
    pub fn addOverrideDir(self: *Vfs, dir_path: []const u8) !void {
        const io = self.io;
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return error.FileNotFound;
        defer dir.close(io);
        const arena = self.strings.allocator();
        const base = try Io.Dir.cwd().realPathFileAlloc(io, dir_path, arena);
        var walker = try dir.walk(self.gpa);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (e.kind != .file) continue;
            const key = try normalize(arena, e.path);
            const real = try std.fs.path.join(arena, &.{ base, e.path });
            try self.over.put(self.gpa, key, real);
        }
    }

    fn hasArchive(self: *const Vfs, basename: []const u8, size: u64) bool {
        for (self.archives.items) |a| {
            if (a.size == size and std.ascii.eqlIgnoreCase(std.fs.path.basename(a.path), basename)) return true;
        }
        return false;
    }

    pub fn exists(self: *const Vfs, path: []const u8) bool {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const key = normalizeBuf(&buf, path) orelse return false;
        return self.over.contains(key) or self.winners.contains(key) or self.loose.contains(key);
    }

    /// Returns the contents of `path`; caller owns the result.
    pub fn read(self: *Vfs, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const key = normalizeBuf(&buf, path) orelse return error.FileNotFound;
        if (self.over.get(key)) |real| return Io.Dir.cwd().readFileAlloc(self.io, real, gpa, .unlimited);
        if (self.winners.get(key)) |a| return a.readAlloc(gpa, key);
        if (self.loose.get(key)) |real| {
            const root = self.root orelse return error.FileNotFound;
            return root.readFileAlloc(self.io, real, gpa, .unlimited);
        }
        return error.FileNotFound;
    }

    /// Calls `f(ctx, normalized_path)` for every visible file.
    pub fn forEach(self: *const Vfs, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8) anyerror!void) !void {
        var oit = self.over.keyIterator();
        while (oit.next()) |k| try f(ctx, k.*);
        var it = self.winners.keyIterator();
        while (it.next()) |k| if (!self.over.contains(k.*)) try f(ctx, k.*);
        var lit = self.loose.iterator();
        while (lit.next()) |e| {
            if (!self.winners.contains(e.key_ptr.*) and !self.over.contains(e.key_ptr.*)) try f(ctx, e.key_ptr.*);
        }
    }

    pub fn fileCount(self: *const Vfs) usize {
        var n = self.over.count();
        var wit = self.winners.keyIterator();
        while (wit.next()) |k| {
            if (!self.over.contains(k.*)) n += 1;
        }
        var lit = self.loose.keyIterator();
        while (lit.next()) |k| {
            if (!self.winners.contains(k.*) and !self.over.contains(k.*)) n += 1;
        }
        return n;
    }
};

/// Lowercases and converts backslashes to slashes. Caller owns the result.
pub fn normalize(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, path);
    for (out) |*c| c.* = if (c.* == '\\') '/' else std.ascii.toLower(c.*);
    return out;
}

fn normalizeBuf(buf: []u8, path: []const u8) ?[]const u8 {
    if (path.len > buf.len) return null;
    const out = buf[0..path.len];
    for (path, out) |c, *o| o.* = if (c == '\\') '/' else std.ascii.toLower(c);
    return out;
}

test "normalize folds case and separators" {
    const gpa = std.testing.allocator;
    const n = try normalize(gpa, "UI\\Sound\\Config.XML");
    defer gpa.free(n);
    try std.testing.expectEqualStrings("ui/sound/config.xml", n);
}
