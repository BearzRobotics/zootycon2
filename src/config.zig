//! Locating the player's Zoo Tycoon 2 data. Like OpenMW, we look in the usual
//! places (Windows mounts, Wine prefixes) but always let the user say "it's
//! over here" explicitly.
//!
//! Lookup order, first valid directory wins:
//!   1. `--data <dir>` on the command line
//!   2. `ZOOTYCON2_DATA` environment variable
//!   3. `data=<dir>` in `$XDG_CONFIG_HOME/zootycon2/config` (default `~/.config`)
//!   4. the imported working copy in `$XDG_DATA_HOME/zootycon2/data`
//!   5. standard install locations

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Environ = std.process.Environ;

const is_windows = builtin.os.tag == .windows;

pub const Source = enum { command_line, environment, config_file, working_copy, standard_location };

pub const Located = struct {
    path: []const u8,
    source: Source,
};

/// Subdirectories of the install that are relative to the home dir candidates.
const standard_suffixes = [_][]const u8{
    "Program Files (x86)/Microsoft Games/Zoo Tycoon 2",
    "Program Files/Microsoft Games/Zoo Tycoon 2",
};

/// A directory is a game install if it has at least one z2f at its top level.
pub fn isInstall(io: Io, path: []const u8) bool {
    var dir = Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return false) |e| {
        if (e.kind == .file and std.ascii.endsWithIgnoreCase(e.name, ".z2f")) return true;
    }
    return false;
}

pub fn configDir(gpa: std.mem.Allocator, env: *const Environ.Map) ![]u8 {
    if (is_windows) {
        const base = env.get("APPDATA") orelse return error.NoHomeDirectory;
        return std.fs.path.join(gpa, &.{ base, "zootycon2" });
    }
    if (env.get("XDG_CONFIG_HOME")) |x| return std.fs.path.join(gpa, &.{ x, "zootycon2" });
    const home = env.get("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ home, ".config", "zootycon2" });
}

/// Where this user's engine data lives: saves and the imported working copy.
pub fn userDataDir(gpa: std.mem.Allocator, env: *const Environ.Map) ![]u8 {
    if (is_windows) {
        const base = env.get("LOCALAPPDATA") orelse env.get("APPDATA") orelse return error.NoHomeDirectory;
        return std.fs.path.join(gpa, &.{ base, "zootycon2" });
    }
    if (env.get("XDG_DATA_HOME")) |x| return std.fs.path.join(gpa, &.{ x, "zootycon2" });
    const home = env.get("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(gpa, &.{ home, ".local", "share", "zootycon2" });
}

pub fn workingCopyDir(gpa: std.mem.Allocator, env: *const Environ.Map) ![]u8 {
    const base = try userDataDir(gpa, env);
    defer gpa.free(base);
    return std.fs.path.join(gpa, &.{ base, "data" });
}

/// Where saves go by default.
pub fn savesDir(gpa: std.mem.Allocator, env: *const Environ.Map) ![]u8 {
    const base = try userDataDir(gpa, env);
    defer gpa.free(base);
    return std.fs.path.join(gpa, &.{ base, "saves" });
}

/// Finds the game data. Caller owns `path` of the result.
pub fn locate(
    gpa: std.mem.Allocator,
    io: Io,
    env: *const Environ.Map,
    cli_data: ?[]const u8,
) !Located {
    if (cli_data) |p| {
        if (!isInstall(io, p)) return error.NotAnInstall;
        return .{ .path = try gpa.dupe(u8, p), .source = .command_line };
    }
    if (env.get("ZOOTYCON2_DATA")) |p| {
        if (isInstall(io, p)) return .{ .path = try gpa.dupe(u8, p), .source = .environment };
    }
    if (readConfigText(gpa, io, env)) |text| {
        defer gpa.free(text);
        if (try parseData(gpa, text)) |p| {
            if (isInstall(io, p)) return .{ .path = p, .source = .config_file };
            gpa.free(p);
        }
    }
    {
        const p = workingCopyDir(gpa, env) catch null;
        if (p) |wc| {
            if (isInstall(io, wc)) return .{ .path = wc, .source = .working_copy };
            gpa.free(wc);
        }
    }
    var roots: std.ArrayList([]u8) = .empty;
    defer freeList(gpa, &roots);
    try windowsRoots(gpa, env, &roots);
    for (roots.items) |root| {
        for (standard_suffixes) |suffix| {
            const p = try std.fs.path.join(gpa, &.{ root, suffix });
            if (isInstall(io, p)) return .{ .path = p, .source = .standard_location };
            gpa.free(p);
        }
    }
    return error.InstallNotFound;
}

/// Returns every `<key>=<value>` value in config text, in order. Lines
/// starting with `#` are comments; surrounding quotes are stripped.
pub fn parseValues(gpa: std.mem.Allocator, text: []const u8, key: []const u8) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeList(gpa, &out);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) continue;
        var v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
        try out.append(gpa, try gpa.dupe(u8, v));
    }
    return out;
}

pub fn freeList(gpa: std.mem.Allocator, list: *std.ArrayList([]u8)) void {
    for (list.items) |i| gpa.free(i);
    list.deinit(gpa);
}

/// The last `data=<dir>` value, or null. Caller owns the result.
pub fn parseData(gpa: std.mem.Allocator, text: []const u8) !?[]u8 {
    var vals = try parseValues(gpa, text, "data");
    defer vals.deinit(gpa);
    if (vals.items.len == 0) return null;
    const last = vals.pop().?;
    for (vals.items) |v| gpa.free(v);
    return last;
}

fn readConfigText(gpa: std.mem.Allocator, io: Io, env: *const Environ.Map) ?[]u8 {
    const dir = configDir(gpa, env) catch return null;
    defer gpa.free(dir);
    const file = std.fs.path.join(gpa, &.{ dir, "config" }) catch return null;
    defer gpa.free(file);
    return Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(64 * 1024)) catch null;
}

fn isDir(io: Io, path: []const u8) bool {
    var d = Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn windowsRoots(gpa: std.mem.Allocator, env: *const Environ.Map, list: *std.ArrayList([]u8)) !void {
    if (is_windows) {
        // Native Windows: the system drive first, then the other common drives.
        const sys = env.get("SystemDrive") orelse "C:";
        try list.append(gpa, try std.fmt.allocPrint(gpa, "{s}\\", .{sys}));
        for ([_][]const u8{ "D:\\", "E:\\", "F:\\" }) |d| {
            if (std.ascii.startsWithIgnoreCase(sys, d[0..2])) continue;
            try list.append(gpa, try gpa.dupe(u8, d));
        }
        return;
    }
    try list.append(gpa, try gpa.dupe(u8, "/mnt/c"));
    if (env.get("WINEPREFIX")) |w| try list.append(gpa, try std.fs.path.join(gpa, &.{ w, "drive_c" }));
    if (env.get("HOME")) |h| try list.append(gpa, try std.fs.path.join(gpa, &.{ h, ".wine", "drive_c" }));
}

const downloads_suffix = "ProgramData/Microsoft Games/Zoo Tycoon 2/downloads";

/// Extra directories holding downloadable-content z2f archives: `dlc=<dir>`
/// lines from the config file, plus the Windows/Wine downloads cache. Only
/// directories that exist are returned. Caller frees with `freeList`.
pub fn extraDlcDirs(gpa: std.mem.Allocator, io: Io, env: *const Environ.Map) !std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeList(gpa, &out);
    if (readConfigText(gpa, io, env)) |text| {
        defer gpa.free(text);
        var vals = try parseValues(gpa, text, "dlc");
        defer vals.deinit(gpa);
        for (vals.items) |v| {
            if (isDir(io, v)) try out.append(gpa, v) else gpa.free(v);
        }
    }
    var roots: std.ArrayList([]u8) = .empty;
    defer freeList(gpa, &roots);
    try windowsRoots(gpa, env, &roots);
    for (roots.items) |root| {
        const p = try std.fs.path.join(gpa, &.{ root, downloads_suffix });
        if (isDir(io, p)) try out.append(gpa, p) else gpa.free(p);
    }
    return out;
}

/// Files not needed to run the engine (videos, manuals, Windows binaries).
fn skipForImport(name: []const u8) bool {
    const skip = [_][]const u8{ ".bik", ".pdf", ".exe", ".dll", ".rtf", ".url", ".bmp" };
    for (skip) |ext| if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    return false;
}

pub const ImportStats = struct { files: usize = 0, bytes: u64 = 0 };

/// Copies the game data from `src` into `dest` (created if needed), leaving
/// out videos, manuals and Windows binaries. Existing files are replaced.
/// z2f archives from `extra_dlc_dirs` are copied to `dest/downloads/`, except
/// ones whose file name and size match an archive already copied.
pub fn importData(
    gpa: std.mem.Allocator,
    io: Io,
    src: []const u8,
    extra_dlc_dirs: []const []const u8,
    dest: []const u8,
) !ImportStats {
    var src_dir = try Io.Dir.openDirAbsolute(io, src, .{ .iterate = true });
    defer src_dir.close(io);
    try Io.Dir.cwd().createDirPath(io, dest);
    var dst_dir = try Io.Dir.openDirAbsolute(io, dest, .{});
    defer dst_dir.close(io);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);

    var stats: ImportStats = .{};
    var walker = try src_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file or skipForImport(e.basename)) continue;
        try src_dir.copyFile(e.path, dst_dir, e.path, io, .{
            .make_path = true,
            .permissions = .default_file,
        });
        const st = try dst_dir.statFile(io, e.path, .{});
        stats.files += 1;
        stats.bytes += st.size;
        if (std.ascii.endsWithIgnoreCase(e.basename, ".z2f")) _ = try markSeen(arena.allocator(), gpa, &seen, e.basename, st.size);
    }

    for (extra_dlc_dirs) |extra| {
        var xdir = try Io.Dir.openDirAbsolute(io, extra, .{ .iterate = true });
        defer xdir.close(io);
        var xw = try xdir.walk(gpa);
        defer xw.deinit();
        while (try xw.next(io)) |e| {
            if (e.kind != .file or !std.ascii.endsWithIgnoreCase(e.basename, ".z2f")) continue;
            const st = try xdir.statFile(io, e.path, .{});
            if (!try markSeen(arena.allocator(), gpa, &seen, e.basename, st.size)) continue;
            const rel = try std.fs.path.join(gpa, &.{ "downloads", e.path });
            defer gpa.free(rel);
            try xdir.copyFile(e.path, dst_dir, rel, io, .{ .make_path = true, .permissions = .default_file });
            stats.files += 1;
            stats.bytes += st.size;
        }
    }
    return stats;
}

/// Records `name:size`; returns false if it was already present.
fn markSeen(
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    seen: *std.StringHashMapUnmanaged(void),
    name: []const u8,
    size: u64,
) !bool {
    const key = try std.fmt.allocPrint(arena, "{s}:{d}", .{ name, size });
    _ = std.ascii.lowerString(@constCast(key), key);
    const gop = try seen.getOrPut(gpa, key);
    return !gop.found_existing;
}

test "parseData reads the last data= line and strips quotes" {
    const gpa = std.testing.allocator;
    const text = "# comment\ndata=/old\n  data = \"/mnt/c/Zoo Tycoon 2\"  \nother=1\n";
    const got = (try parseData(gpa, text)).?;
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/mnt/c/Zoo Tycoon 2", got);
    try std.testing.expect((try parseData(gpa, "x=1\n")) == null);
}

test "skipForImport" {
    try std.testing.expect(skipForImport("intro.BIK"));
    try std.testing.expect(!skipForImport("x300_000.z2f"));
}
