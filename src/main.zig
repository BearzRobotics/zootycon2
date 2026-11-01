const std = @import("std");
const Io = std.Io;
const zootycon2 = @import("zootycon2");
const config = zootycon2.config;

const usage =
    \\usage: zootycon2 [--data <dir>] <command> [args]
    \\
    \\Game data is found via --data, $ZOOTYCON2_DATA, the config file
    \\(~/.config/zootycon2/config, line "data=<dir>"), an imported working copy,
    \\then standard Windows/Wine locations.
    \\
    \\  where                        show which game data would be used
    \\  import [source]              copy game data into the working copy
    \\  info                         summarize mounted archives and files
    \\  list [prefix]                list visible files (sorted)
    \\  cat <path>                   write a file to stdout
    \\  entities                    load entity definitions and show statistics
    \\  entity <name>                show an entity's inheritance chain and data
    \\  window [seconds]             open a test window (Esc or close to quit)
    \\  xmlcheck [prefix]            parse every .xml and report failures
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [4096]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    // Split --data from the positional arguments.
    var data_opt: ?[]const u8 = null;
    var pos: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--data")) {
            i += 1;
            if (i >= argv.len) return fail("--data needs a directory\n");
            data_opt = argv[i];
        } else try pos.append(init.arena.allocator(), argv[i]);
    }
    if (pos.items.len == 0) return fail(usage);
    const cmd = pos.items[0];
    const rest = pos.items[1..];

    if (std.mem.eql(u8, cmd, "window")) {
        const seconds = if (rest.len > 0) try std.fmt.parseInt(u64, rest[0], 10) else 5;
        const plat = zootycon2.platform.Platform.init() catch {
            std.debug.print("SDL init failed: {s}\n", .{zootycon2.platform.lastError()});
            return error.PlatformInit;
        };
        defer plat.deinit();
        const win = zootycon2.platform.Window.create("zootycon2", 1280, 720) catch {
            std.debug.print("window creation failed: {s}\n", .{zootycon2.platform.lastError()});
            return error.PlatformWindow;
        };
        defer win.destroy();
        try out.print("video driver: {s}\n", .{plat.videoDriver()});
        try out.flush();
        const end = plat.ticksMs() + seconds * 1000;
        run: while (plat.ticksMs() < end) {
            while (plat.pollEvent()) |ev| switch (ev) {
                .quit => break :run,
                .key_down => |k| if (k.scancode == zootycon2.platform.scancode_escape) break :run,
                else => {},
            };
            plat.delayMs(16);
        }
        return;
    }

    if (std.mem.eql(u8, cmd, "import")) {
        const src_override = if (rest.len > 0) rest[0] else data_opt;
        const found = config.locate(gpa, io, env, src_override) catch
            return fail("no game data found; pass the source dir: zootycon2 import <dir>\n");
        defer gpa.free(found.path);
        const dest = try config.workingCopyDir(gpa, env);
        defer gpa.free(dest);
        try out.print("copying {s}\n     to {s}\n", .{ found.path, dest });
        try out.flush();
        var extras = try config.extraDlcDirs(gpa, io, env);
        defer config.freeList(gpa, &extras);
        for (extras.items) |x| try out.print("  + DLC from {s}\n", .{x});
        try out.flush();
        const stats = try config.importData(gpa, io, found.path, extras.items, dest);
        try out.print("done: {d} files, {d} MiB\n", .{ stats.files, stats.bytes >> 20 });
        return;
    }

    const found = config.locate(gpa, io, env, data_opt) catch |err| switch (err) {
        error.NotAnInstall => return fail("--data directory has no .z2f files\n"),
        error.InstallNotFound => return fail("could not find Zoo Tycoon 2; use --data <dir>, set ZOOTYCON2_DATA, or add data=<dir> to ~/.config/zootycon2/config\n"),
        else => return err,
    };
    defer gpa.free(found.path);

    if (std.mem.eql(u8, cmd, "where")) {
        try out.print("{s}\n  found via: {s}\n", .{ found.path, @tagName(found.source) });
        return;
    }

    var vfs = zootycon2.vfs.Vfs.init(gpa, io);
    defer vfs.deinit();
    try vfs.addInstall(found.path);
    // The working copy already contains its DLC; otherwise also mount the
    // separate DLC download folders.
    if (found.source != .working_copy) {
        var extras = try config.extraDlcDirs(gpa, io, env);
        defer config.freeList(gpa, &extras);
        for (extras.items) |x| try vfs.addExtraDir(x);
    }

    if (std.mem.eql(u8, cmd, "info")) {
        try out.print("data:     {s} ({s})\narchives: {d}\nfiles:    {d}\n", .{ found.path, @tagName(found.source), vfs.archives.items.len, vfs.fileCount() });
    } else if (std.mem.eql(u8, cmd, "list")) {
        const prefix = if (rest.len > 0) rest[0] else "";
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        const Collect = struct {
            list: *std.ArrayList([]const u8),
            gpa: std.mem.Allocator,
            prefix: []const u8,
            fn add(c: @This(), name: []const u8) anyerror!void {
                if (std.mem.startsWith(u8, name, c.prefix)) try c.list.append(c.gpa, name);
            }
        };
        try vfs.forEach(Collect{ .list = &names, .gpa = gpa, .prefix = prefix }, Collect.add);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (names.items) |n| try out.print("{s}\n", .{n});
    } else if (std.mem.eql(u8, cmd, "cat") and rest.len > 0) {
        const data = try vfs.read(gpa, rest[0]);
        defer gpa.free(data);
        try out.writeAll(data);
    } else if (std.mem.eql(u8, cmd, "entities") or (std.mem.eql(u8, cmd, "entity") and rest.len > 0)) {
        var reg = zootycon2.entity.Registry.init(gpa);
        defer reg.deinit();
        try reg.load(&vfs);
        if (std.mem.eql(u8, cmd, "entities")) {
            var abstract_n: usize = 0;
            var with_chain: usize = 0;
            var it = reg.binders.valueIterator();
            while (it.next()) |b| {
                if (b.*.abstract) abstract_n += 1;
                const ch = try reg.chain(gpa, b.*);
                defer gpa.free(ch);
                if (ch.len > 1) with_chain += 1;
            }
            try out.print("binders:    {d} ({d} abstract)\noverridden: {d}\nskipped:    {d}\ninherit:    {d} have at least one ancestor binder\n", .{ reg.binders.count(), abstract_n, reg.overridden, reg.skipped, with_chain });
        } else {
            const b = reg.get(rest[0]) orelse return fail("no such entity\n");
            const ch = try reg.chain(gpa, b);
            defer gpa.free(ch);
            try out.print("{s}{s}\n  file: {s}\n  type: ", .{ b.name, if (b.abstract) " (abstract)" else "", b.source });
            for (b.type_path, 0..) |t, ti| try out.print("{s}{s}", .{ if (ti > 0) "/" else "", t });
            try out.writeAll("\n  inherits from:");
            for (ch[0 .. ch.len - 1]) |a| try out.print(" {s}", .{a.name});
            try out.writeAll("\n");
            // Effective attributes of each shared component, most specific wins.
            for (ch) |c| {
                const sec = c.section(.shared) orelse continue;
                for (sec.children) |comp| {
                    for (comp.attributes) |at| {
                        const eff = zootycon2.entity.Registry.attr(ch, .shared, comp.name, at.name).?;
                        if (std.mem.eql(u8, eff, at.value)) try out.print("  {s}.{s} = {s}\n", .{ comp.name, at.name, at.value });
                    }
                }
            }
        }
    } else if (std.mem.eql(u8, cmd, "xmlcheck")) {
        const prefix = if (rest.len > 0) rest[0] else "";
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        const Collect = struct {
            list: *std.ArrayList([]const u8),
            gpa: std.mem.Allocator,
            prefix: []const u8,
            fn add(c: @This(), name: []const u8) anyerror!void {
                if (std.mem.startsWith(u8, name, c.prefix) and std.mem.endsWith(u8, name, ".xml")) try c.list.append(c.gpa, name);
            }
        };
        try vfs.forEach(Collect{ .list = &names, .gpa = gpa, .prefix = prefix }, Collect.add);
        var failed: usize = 0;
        for (names.items) |n| {
            const data = try vfs.read(gpa, n);
            defer gpa.free(data);
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            var diag: zootycon2.xml.Diagnostic = .{};
            _ = zootycon2.xml.parse(arena.allocator(), data, &diag) catch |err| {
                failed += 1;
                if (failed <= 25) try out.print("{s}:{d}:{d}: {s}\n", .{ n, diag.line, diag.column, @errorName(err) });
            };
        }
        try out.print("{d} files, {d} failed\n", .{ names.items.len, failed });
    } else return fail(usage);
}

fn fail(msg: []const u8) error{InvalidArguments} {
    std.debug.print("{s}", .{msg});
    return error.InvalidArguments;
}
