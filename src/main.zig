const std = @import("std");
const Io = std.Io;
const zootycon2 = @import("zootycon2");
const config = zootycon2.config;

const usage =
    \\usage: zootycon2 [--data <dir>] [--mod <dir>]... <command> [args]
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
    \\  modelcheck [prefix]         parse every .bfm manifest and .bfmat material
    \\  ddscheck [prefix]           parse every .dds texture and report formats
    \\  nifinfo <path>               print a NIF's scene graph
    \\  view <model> [--anim A] [--time S] [--shot]  view a .nif/.bfm model
    \\  play <map|save> [--save-dir D] [--seed N] [--no-sim] [--view]  interactive zoo with build tools
    \\  map <file.zt2> [--shot] [--at X Y] [--yaw R] [--pitch R] [--zoom F]  view a map
    \\  elements <prefix> <suffix> [name-prefix]  count XML element names in matching files
    \\  mapcheck [prefix]           parse every map and its terrain
    \\  bfcheck [prefix]            parse every .bf animation and report coverage
    \\  nifcheck [prefix]           parse every .nif/.kf and report coverage
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
    var mods: std.ArrayList([]const u8) = .empty;
    var pos: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--data")) {
            i += 1;
            if (i >= argv.len) return fail("--data needs a directory\n");
            data_opt = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--mod")) {
            i += 1;
            if (i >= argv.len) return fail("--mod needs a directory\n");
            try mods.append(init.arena.allocator(), argv[i]);
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

    // Override folders (texture packs, replacement data): ./mods/*, the user
    // data dir's mods/*, then --mod directories; later ones win.
    {
        const user = config.userDataDir(gpa, env) catch null;
        defer if (user) |u| gpa.free(u);
        var roots: [2]?[]u8 = .{ null, null };
        defer for (roots) |r| if (r) |x| gpa.free(x);
        roots[0] = gpa.dupe(u8, "mods") catch null;
        if (user) |u| roots[1] = std.fs.path.join(gpa, &.{ u, "mods" }) catch null;
        for (roots) |r0| {
            const r = r0 orelse continue;
            var d = Io.Dir.cwd().openDir(io, r, .{ .iterate = true }) catch continue;
            defer d.close(io);
            var names: std.ArrayList([]u8) = .empty;
            defer {
                for (names.items) |n| gpa.free(n);
                names.deinit(gpa);
            }
            var it = d.iterate();
            while (it.next(io) catch null) |e| {
                if (e.kind == .directory) try names.append(gpa, try gpa.dupe(u8, e.name));
            }
            std.mem.sort([]u8, names.items, {}, struct {
                fn less(_: void, a: []u8, b: []u8) bool {
                    return std.ascii.lessThanIgnoreCase(a, b);
                }
            }.less);
            for (names.items) |n| {
                const full = try std.fs.path.join(gpa, &.{ r, n });
                defer gpa.free(full);
                vfs.addOverrideDir(full) catch {};
            }
        }
        for (mods.items) |m| vfs.addOverrideDir(m) catch return fail("--mod: cannot open directory\n");
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
    } else if (std.mem.eql(u8, cmd, "export") and rest.len > 1) {
        // export <prefix-or-suffix> <dir>: extract matching files for offline analysis.
        const pat = rest[0];
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        const Match = struct {
            list: *std.ArrayList([]const u8),
            gpa: std.mem.Allocator,
            pat: []const u8,
            fn add(c: @This(), name: []const u8) anyerror!void {
                if (std.mem.startsWith(u8, name, c.pat) or std.mem.endsWith(u8, name, c.pat)) try c.list.append(c.gpa, name);
            }
        };
        try vfs.forEach(Match{ .list = &names, .gpa = gpa, .pat = pat }, Match.add);
        const root = Io.Dir.cwd();
        for (names.items) |n| {
            const dest = try std.fs.path.join(gpa, &.{ rest[1], n });
            defer gpa.free(dest);
            if (std.fs.path.dirname(dest)) |d| try root.createDirPath(io, d);
            const data = try vfs.read(gpa, n);
            defer gpa.free(data);
            try root.writeFile(io, .{ .sub_path = dest, .data = data });
        }
        try out.print("exported {d} files\n", .{names.items.len});
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
    } else if (std.mem.eql(u8, cmd, "dds2ppm")) {
        // Debug: write a texture's top level as a PPM (alpha shown on black).
        if (rest.len < 1) return fail("dds2ppm <file.dds>\n");
        const data = try vfs.read(gpa, rest[0]);
        defer gpa.free(data);
        var img = try zootycon2.dds.parse(gpa, data);
        defer img.deinit();
        const rgba = try zootycon2.dds.decodeLevel(gpa, &img, 0, 0);
        defer gpa.free(rgba);
        const lv = img.level(0, 0);
        try out.print("P6\n{d} {d}\n255\n", .{ lv.width, lv.height });
        var pi: usize = 0;
        while (pi < @as(usize, lv.width) * lv.height) : (pi += 1) {
            const a: u32 = rgba[pi * 4 + 3];
            const px = [3]u8{ @intCast(@as(u32, rgba[pi * 4]) * a / 255), @intCast(@as(u32, rgba[pi * 4 + 1]) * a / 255), @intCast(@as(u32, rgba[pi * 4 + 2]) * a / 255) };
            try out.writeAll(&px);
        }
    } else if (std.mem.eql(u8, cmd, "typecount")) {
        // Debug: how many concrete entities sit under each of the first type-path levels.
        var reg = zootycon2.entity.Registry.init(gpa);
        defer reg.deinit();
        try reg.load(&vfs);
        var counts = std.StringHashMap(u32).init(gpa);
        defer counts.deinit();
        var it = reg.binders.valueIterator();
        while (it.next()) |b| {
            if (b.*.abstract) continue;
            const tp = b.*.type_path;
            if (tp.len < 2) continue;
            const depth = @min(tp.len, if (rest.len > 0) (std.fmt.parseInt(usize, rest[0], 10) catch 3) else 3);
            const key = try std.mem.join(gpa, "/", tp[0..depth]);
            const e = try counts.getOrPutValue(key, 0);
            e.value_ptr.* += 1;
        }
        var cit = counts.iterator();
        while (cit.next()) |e| try out.print("{d:5} {s}\n", .{ e.value_ptr.*, e.key_ptr.* });
    } else if (std.mem.eql(u8, cmd, "terrstat")) {
        // Debug: height range of a terrain file and how much lies below z = 6 (the base).
        if (rest.len < 1) return fail("terrstat <file.dat>\n");
        const data = try vfs.read(gpa, rest[0]);
        defer gpa.free(data);
        var t = try zootycon2.terrain.parse(gpa, data);
        defer t.deinit();
        var lo: f32 = 1e9;
        var hi: f32 = -1e9;
        var below: usize = 0;
        var below1: usize = 0;
        for (t.z) |z| {
            lo = @min(lo, z);
            hi = @max(hi, z);
            if (z < 6.0) below += 1;
            if (z < 5.0) below1 += 1;
        }
        // The most common height (0.05 bins) and how much of the map sits there.
        var hist = std.AutoHashMap(i32, u32).init(gpa);
        defer hist.deinit();
        for (t.z) |z| {
            const e = try hist.getOrPutValue(@intFromFloat(@round(z * 20)), 0);
            e.value_ptr.* += 1;
        }
        var mode_bin: i32 = 0;
        var mode_n: u32 = 0;
        var hit = hist.iterator();
        while (hit.next()) |e| if (e.value_ptr.* > mode_n) {
            mode_n = e.value_ptr.*;
            mode_bin = e.key_ptr.*;
        };
        try out.print("mode {d:.2} share {d:.0}% | ", .{ @as(f32, @floatFromInt(mode_bin)) / 20.0, 100.0 * @as(f32, @floatFromInt(mode_n)) / @as(f32, @floatFromInt(t.z.len)) });
        try out.print("{s}: {d}x{d} z {d:.1}..{d:.1} below6 {d:.1}% below5 {d:.1}% stride {d}\n", .{ rest[0], t.width, t.height, lo, hi, 100.0 * @as(f32, @floatFromInt(below)) / @as(f32, @floatFromInt(t.z.len)), 100.0 * @as(f32, @floatFromInt(below1)) / @as(f32, @floatFromInt(t.z.len)), t.stride });
    } else if (std.mem.eql(u8, cmd, "headcheck")) {
        // Debug: where the Link_Head node goes in every animation of a model.
        if (rest.len < 1) return fail("headcheck <file.bfm>\n");
        const v = zootycon2.viewer;
        const data = try vfs.read(gpa, rest[0]);
        defer gpa.free(data);
        var mf = try zootycon2.model.parseManifest(gpa, data);
        defer mf.deinit();
        const nb = try vfs.read(gpa, mf.model_name);
        defer gpa.free(nb);
        var nf = try zootycon2.nif.parse(gpa, nb);
        defer nf.deinit();
        var head: ?usize = null;
        var spine: ?usize = null;
        for (nf.blocks, 0..) |blk, bi| switch (blk) {
            .node => |n| {
                if (std.ascii.eqlIgnoreCase(n.av.net.name, "Link_Head")) head = bi;
                if (std.ascii.eqlIgnoreCase(n.av.net.name, "Bip01 Spine")) spine = bi;
            },
            else => {},
        };
        const hi = head orelse return fail("no Link_Head\n");
        const world = try gpa.alloc(v.Mat4, nf.blocks.len);
        defer gpa.free(world);
        for (mf.animations) |an| {
            const ab = vfs.read(gpa, an.path) catch continue;
            defer gpa.free(ab);
            var anim = zootycon2.bf.parse(gpa, ab) catch continue;
            defer anim.deinit();
            var zmin: f32 = 1e9;
            var zmax: f32 = -1e9;
            var bad = false;
            var dmax: f32 = 0;
            var t: f32 = 0;
            while (t <= anim.duration) : (t += 0.05) {
                @memset(world, v.identity);
                v.poseWorld(world, &nf, v.identity, &anim, t);
                const m = world[hi];
                for (m) |x| if (!std.math.isFinite(x)) {
                    bad = true;
                };
                zmin = @min(zmin, m[14]);
                zmax = @max(zmax, m[14]);
                if (spine) |si| {
                    const s = world[si];
                    const dx = m[12] - s[12];
                    const dy = m[13] - s[13];
                    const dz = m[14] - s[14];
                    dmax = @max(dmax, @sqrt(dx * dx + dy * dy + dz * dz));
                }
            }
            try out.print("{s}: z {d:.1}..{d:.1} head-spine {d:.1}{s}\n", .{ an.name, zmin, zmax, dmax, if (bad) " NAN" else "" });
        }
    } else if (std.mem.eql(u8, cmd, "modelcheck")) {
        const prefix = if (rest.len > 0) rest[0] else "";
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        const Collect = struct {
            list: *std.ArrayList([]const u8),
            gpa: std.mem.Allocator,
            prefix: []const u8,
            fn add(c: @This(), name: []const u8) anyerror!void {
                if (std.mem.startsWith(u8, name, c.prefix) and (std.mem.endsWith(u8, name, ".bfm") or std.mem.endsWith(u8, name, ".bfmat")))
                    try c.list.append(c.gpa, name);
            }
        };
        try vfs.forEach(Collect{ .list = &names, .gpa = gpa, .prefix = prefix }, Collect.add);
        var n_bfm: usize = 0;
        var n_mat: usize = 0;
        var n_anim: usize = 0;
        var missing_model: usize = 0;
        var failed: usize = 0;
        for (names.items) |n| {
            const data = try vfs.read(gpa, n);
            defer gpa.free(data);
            if (std.mem.endsWith(u8, n, ".bfm")) {
                var m = zootycon2.model.parseManifest(gpa, data) catch |err| {
                    failed += 1;
                    if (failed <= 15) try out.print("{s}: {s}\n", .{ n, @errorName(err) });
                    continue;
                };
                defer m.deinit();
                n_bfm += 1;
                n_anim += m.animations.len;
                if (!vfs.exists(m.model_name)) {
                    missing_model += 1;
                    if (missing_model <= 5) try out.print("{s}: model not found: {s}\n", .{ n, m.model_name });
                }
            } else {
                var m = zootycon2.model.parseMaterial(gpa, data) catch |err| {
                    failed += 1;
                    if (failed <= 15) try out.print("{s}: {s}\n", .{ n, @errorName(err) });
                    continue;
                };
                m.deinit();
                n_mat += 1;
            }
        }
        try out.print("{d} manifests ({d} animations, {d} with a missing model), {d} materials, {d} failed\n", .{ n_bfm, n_anim, missing_model, n_mat, failed });
    } else if (std.mem.eql(u8, cmd, "ddscheck")) {
        const prefix = if (rest.len > 0) rest[0] else "";
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        const Collect = struct {
            list: *std.ArrayList([]const u8),
            gpa: std.mem.Allocator,
            prefix: []const u8,
            fn add(c: @This(), name: []const u8) anyerror!void {
                if (std.mem.startsWith(u8, name, c.prefix) and std.mem.endsWith(u8, name, ".dds")) try c.list.append(c.gpa, name);
            }
        };
        try vfs.forEach(Collect{ .list = &names, .gpa = gpa, .prefix = prefix }, Collect.add);
        var counts: [4]usize = .{ 0, 0, 0, 0 };
        var cubes: usize = 0;
        var failed: usize = 0;
        var short_mips: usize = 0;
        for (names.items) |n| {
            const data = try vfs.read(gpa, n);
            defer gpa.free(data);
            var img = zootycon2.dds.parse(gpa, data) catch |err| {
                failed += 1;
                if (failed <= 15) try out.print("{s}: {s}\n", .{ n, @errorName(err) });
                continue;
            };
            defer img.deinit();
            counts[@intFromEnum(img.format)] += 1;
            if (img.faces > 1) cubes += 1;
            const full = std.math.log2_int(u32, @max(img.width, img.height)) + 1;
            if (img.mip_count != 1 and img.mip_count != full) short_mips += 1;
            // Exercise the software decoder on the top level.
            const px = try zootycon2.dds.decodeLevel(gpa, &img, 0, 0);
            gpa.free(px);
        }
        try out.print("{d} textures: dxt1 {d}, dxt3 {d}, dxt5 {d}, rgba8 {d}; {d} cube maps; {d} with partial mip chains; {d} failed\n", .{ names.items.len, counts[0], counts[1], counts[2], counts[3], cubes, short_mips, failed });
    } else if (std.mem.eql(u8, cmd, "play")) {
        var aopts: zootycon2.app.Options = .{ .save_dir = "" };
        var save_dir_owned: ?[]u8 = null;
        defer if (save_dir_owned) |d| gpa.free(d);
        // `play` alone shows the map picker over a default map.
        const named = rest.len > 0 and !std.mem.startsWith(u8, rest[0], "--");
        const map_path: []const u8 = if (named) rest[0] else "maps/default/alpinesml.zt2";
        aopts.pick_map = !named;
        var k: usize = if (named) 1 else 0;
        while (k < rest.len) : (k += 1) {
            const arg = rest[k];
            if (std.mem.eql(u8, arg, "--save-dir") and k + 1 < rest.len) {
                k += 1;
                aopts.save_dir = rest[k];
            } else if (std.mem.eql(u8, arg, "--seed") and k + 1 < rest.len) {
                k += 1;
                aopts.seed = try std.fmt.parseInt(u64, rest[k], 10);
            } else if (std.mem.eql(u8, arg, "--input") and k + 1 < rest.len) {
                k += 1;
                aopts.input = rest[k];
            } else if (std.mem.eql(u8, arg, "--script") and k + 1 < rest.len) {
                k += 1;
                aopts.script = rest[k];
            } else if (std.mem.eql(u8, arg, "--tod") and k + 1 < rest.len) {
                k += 1;
                aopts.tod = try std.fmt.parseFloat(f32, rest[k]);
            } else if (std.mem.eql(u8, arg, "--clock")) {
                aopts.tod_auto = true;
            } else if (std.mem.eql(u8, arg, "--modern")) {
                aopts.modern = true;
                if (aopts.viewer.msaa == 0) aopts.viewer.msaa = 4;
            } else if (std.mem.eql(u8, arg, "--no-sound")) {
                aopts.no_sound = true;
            } else if (std.mem.eql(u8, arg, "--no-post")) {
                aopts.no_post = true;
            } else if (std.mem.eql(u8, arg, "--no-shadows")) {
                aopts.no_shadows = true;
            } else if (std.mem.eql(u8, arg, "--msaa") and k + 1 < rest.len) {
                k += 1;
                aopts.viewer.msaa = try std.fmt.parseInt(u32, rest[k], 10);
            } else if (std.mem.eql(u8, arg, "--no-sim")) {
                aopts.sim = false;
            } else if (std.mem.eql(u8, arg, "--view")) {
                aopts.tools = false;
            } else if (std.mem.eql(u8, arg, "--shot")) {
                aopts.viewer.screenshot = out;
            } else if (std.mem.eql(u8, arg, "--at") and k + 2 < rest.len) {
                aopts.viewer.focus = .{ try std.fmt.parseFloat(f32, rest[k + 1]), try std.fmt.parseFloat(f32, rest[k + 2]) };
                k += 2;
            } else if (std.mem.eql(u8, arg, "--yaw") and k + 1 < rest.len) {
                k += 1;
                aopts.viewer.yaw = try std.fmt.parseFloat(f32, rest[k]);
            } else if (std.mem.eql(u8, arg, "--pitch") and k + 1 < rest.len) {
                k += 1;
                aopts.viewer.pitch = try std.fmt.parseFloat(f32, rest[k]);
            } else if (std.mem.eql(u8, arg, "--zoom") and k + 1 < rest.len) {
                k += 1;
                aopts.viewer.zoom = try std.fmt.parseFloat(f32, rest[k]);
            } else return fail("play <map|save> [--save-dir D] [--seed N] [--no-sim] [--view] [--shot] [--at X Y] [--yaw R] [--pitch R] [--zoom F]\n");
        }
        if (aopts.save_dir.len == 0) {
            const base = config.savesDir(gpa, env) catch return fail("cannot work out where to save; pass --save-dir\n");
            save_dir_owned = base;
            aopts.save_dir = base;
        }
        try zootycon2.app.run(gpa, io, &vfs, map_path, aopts);
    } else if ((std.mem.eql(u8, cmd, "view") or std.mem.eql(u8, cmd, "map")) and rest.len > 0) {
        var shot = false;
        var vopts: zootycon2.viewer.Options = .{};
        var k: usize = 1;
        while (k < rest.len) : (k += 1) {
            if (std.mem.eql(u8, rest[k], "--shot")) {
                shot = true;
            } else if (std.mem.eql(u8, rest[k], "--anim") and k + 1 < rest.len) {
                k += 1;
                vopts.anim = rest[k];
            } else if (std.mem.eql(u8, rest[k], "--at") and k + 2 < rest.len) {
                vopts.focus = .{ try std.fmt.parseFloat(f32, rest[k + 1]), try std.fmt.parseFloat(f32, rest[k + 2]) };
                k += 2;
            } else if (std.mem.eql(u8, rest[k], "--yaw") and k + 1 < rest.len) {
                k += 1;
                vopts.yaw = try std.fmt.parseFloat(f32, rest[k]);
            } else if (std.mem.eql(u8, rest[k], "--pitch") and k + 1 < rest.len) {
                k += 1;
                vopts.pitch = try std.fmt.parseFloat(f32, rest[k]);
            } else if (std.mem.eql(u8, rest[k], "--zoom") and k + 1 < rest.len) {
                k += 1;
                vopts.zoom = try std.fmt.parseFloat(f32, rest[k]);
            } else if (std.mem.eql(u8, rest[k], "--time") and k + 1 < rest.len) {
                k += 1;
                vopts.time = try std.fmt.parseFloat(f32, rest[k]);
            } else return fail("view <model> [--anim <name|path.bf>] [--time <s>] [--shot]\n");
        }
        if (shot) vopts.screenshot = out;
        if (std.mem.eql(u8, cmd, "map"))
            try zootycon2.app.run(gpa, io, &vfs, rest[0], .{ .viewer = vopts, .tools = false, .sim = false, .save_dir = "." })
        else
            try zootycon2.viewer.run(gpa, &vfs, rest[0], vopts);
    } else if (std.mem.eql(u8, cmd, "elements") and rest.len >= 2) {
        const name_prefix = if (rest.len > 2) rest[2] else "";
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        const Pick = struct {
            list: *std.ArrayList([]const u8),
            gpa: std.mem.Allocator,
            prefix: []const u8,
            suffix: []const u8,
            fn add(c: @This(), name: []const u8) anyerror!void {
                if (std.mem.startsWith(u8, name, c.prefix) and std.mem.endsWith(u8, name, c.suffix)) try c.list.append(c.gpa, name);
            }
        };
        try vfs.forEach(Pick{ .list = &names, .gpa = gpa, .prefix = rest[0], .suffix = rest[1] }, Pick.add);
        var counts: std.StringHashMapUnmanaged(usize) = .empty;
        // The map and the parsed trees share this arena, so one deinit frees all.
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const Walk = struct {
            fn visit(c: *std.StringHashMapUnmanaged(usize), a: std.mem.Allocator, e: *const zootycon2.xml.Element, pre: []const u8) !void {
                if (std.mem.startsWith(u8, e.name, pre)) {
                    const gop = try c.getOrPut(a, e.name);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }
                for (e.children) |ch| try visit(c, a, ch, pre);
            }
        };
        for (names.items) |n| {
            const data = try vfs.read(gpa, n);
            defer gpa.free(data);
            const root = zootycon2.xml.parse(arena.allocator(), data, null) catch continue;
            try Walk.visit(&counts, arena.allocator(), root, name_prefix);
        }
        const Entry = struct { name: []const u8, n: usize };
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(gpa);
        var it = counts.iterator();
        while (it.next()) |e| try entries.append(gpa, .{ .name = e.key_ptr.*, .n = e.value_ptr.* });
        std.mem.sort(Entry, entries.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return a.n > b.n;
            }
        }.less);
        try out.print("{d} files\n", .{names.items.len});
        for (entries.items[0..@min(entries.items.len, 60)]) |e| try out.print("{d:>7} {s}\n", .{ e.n, e.name });
    } else if (std.mem.eql(u8, cmd, "mapcheck")) {
        const prefix = if (rest.len > 0) rest[0] else "maps/";
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        const Pick = struct {
            list: *std.ArrayList([]const u8),
            gpa: std.mem.Allocator,
            prefix: []const u8,
            fn add(c: @This(), name: []const u8) anyerror!void {
                if (std.mem.startsWith(u8, name, c.prefix) and std.mem.endsWith(u8, name, ".zt2")) try c.list.append(c.gpa, name);
            }
        };
        try vfs.forEach(Pick{ .list = &names, .gpa = gpa, .prefix = prefix }, Pick.add);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        var bad: usize = 0;
        for (names.items) |n| {
            const data = try vfs.read(gpa, n);
            defer gpa.free(data);
            var m = zootycon2.map.parse(gpa, data) catch |e| {
                bad += 1;
                try out.print("{s}: map {s}\n", .{ n, @errorName(e) });
                continue;
            };
            defer m.deinit();
            const dir = std.fs.path.dirname(n) orelse "";
            const tpath = try std.fs.path.join(gpa, &.{ dir, m.terrain_file });
            defer gpa.free(tpath);
            const tdata = vfs.read(gpa, tpath) catch {
                bad += 1;
                try out.print("{s}: terrain {s} missing\n", .{ n, tpath });
                continue;
            };
            defer gpa.free(tdata);
            var t = zootycon2.terrain.parse(gpa, tdata) catch |e| {
                bad += 1;
                try out.print("{s}: terrain {s}\n", .{ n, @errorName(e) });
                continue;
            };
            defer t.deinit();
            try out.print("{s}: {d}x{d} verts, {d:.0}x{d:.0} units, {d} objects\n", .{ n, t.width, t.height, t.world_width, t.world_height, m.objects.len });
        }
        try out.print("{d} maps, {d} problems\n", .{ names.items.len, bad });
    } else if (std.mem.eql(u8, cmd, "bfcheck")) {
        const prefix = if (rest.len > 0) rest[0] else "";
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        const Pick = struct {
            list: *std.ArrayList([]const u8),
            gpa: std.mem.Allocator,
            prefix: []const u8,
            fn add(c: @This(), name: []const u8) anyerror!void {
                if (std.mem.startsWith(u8, name, c.prefix) and std.mem.endsWith(u8, name, ".bf")) try c.list.append(c.gpa, name);
            }
        };
        try vfs.forEach(Pick{ .list = &names, .gpa = gpa, .prefix = prefix }, Pick.add);
        var ok: usize = 0;
        var failed: usize = 0;
        var skipped: usize = 0;
        for (names.items) |n| {
            const data = try vfs.read(gpa, n);
            defer gpa.free(data);
            var anim = zootycon2.bf.parse(gpa, data) catch {
                failed += 1;
                if (failed <= 10) try out.print("  fail {s}\n", .{n});
                continue;
            };
            defer anim.deinit();
            ok += 1;
            skipped += anim.skipped_tracks;
        }
        try out.print("{d} animations: {d} parsed, {d} failed; {d} tracks of undecoded types\n", .{ names.items.len, ok, failed, skipped });
    } else if (std.mem.eql(u8, cmd, "nifinfo") and rest.len > 0) {
        const data = try vfs.read(gpa, rest[0]);
        defer gpa.free(data);
        var parsed = try zootycon2.nif.parse(gpa, data);
        defer parsed.deinit();
        try out.print("{d} blocks, roots:", .{parsed.blocks.len});
        for (parsed.roots) |rt| try out.print(" {d}", .{rt});
        try out.writeAll("\n");
        const Dump = struct {
            fn tex(o: *Io.Writer, nf: *const zootycon2.nif.Nif, ref: zootycon2.nif.Ref, label: []const u8) !void {
                if (ref < 0) return;
                switch (nf.blocks[@intCast(ref)]) {
                    .source_texture => |st| try o.print(" {s}={s}", .{ label, st.file_name orelse "(internal)" }),
                    else => {},
                }
            }
            fn node(o: *Io.Writer, nf: *const zootycon2.nif.Nif, ref: zootycon2.nif.Ref, depth: usize) anyerror!void {
                if (ref < 0) return;
                const b = nf.blocks[@intCast(ref)];
                for (0..depth) |_| try o.writeAll("  ");
                switch (b) {
                    .node => |n| {
                        try o.print("[{d}] {s} \"{s}\" t=({d:.2},{d:.2},{d:.2}) s={d:.2}\n", .{ ref, @tagName(n.kind), n.av.net.name, n.av.transform.translation[0], n.av.transform.translation[1], n.av.transform.translation[2], n.av.transform.scale });
                        for (n.lod_ranges, 0..) |lr, li| try o.print("    lod {d}: {d:.1} .. {d:.1}\n", .{ li, lr[0], lr[1] });
                        for (n.children) |c| try node(o, nf, c, depth + 1);
                    },
                    .geometry => |g| {
                        try o.print("[{d}] {s} \"{s}\"", .{ ref, nf.typeName(@intCast(ref)), g.av.net.name });
                        if (g.data >= 0) switch (nf.blocks[@intCast(g.data)]) {
                            .mesh_data => |m| {
                                try o.print(" verts={d} tris={d} uvsets={d}", .{ m.vertices.len, m.indices.len / 3, m.uv_sets.len });
                                if (m.colors.len == m.vertices.len and m.colors.len > 0) {
                                    // Vertex colours at the highest, lowest and most horizontal vertices.
                                    var hi: usize = 0;
                                    var lo: usize = 0;
                                    var mid: usize = 0;
                                    for (m.vertices, 0..) |v, vi| {
                                        if (v[2] > m.vertices[hi][2]) hi = vi;
                                        if (v[2] < m.vertices[lo][2]) lo = vi;
                                        if (@abs(v[2]) < @abs(m.vertices[mid][2])) mid = vi;
                                    }
                                    try o.print(" colors: top z={d:.0} ({d:.2},{d:.2},{d:.2}) mid z={d:.0} ({d:.2},{d:.2},{d:.2}) low z={d:.0} ({d:.2},{d:.2},{d:.2})", .{
                                        m.vertices[hi][2],  m.colors[hi][0],  m.colors[hi][1],  m.colors[hi][2],
                                        m.vertices[mid][2], m.colors[mid][0], m.colors[mid][1], m.colors[mid][2],
                                        m.vertices[lo][2],  m.colors[lo][0],  m.colors[lo][1],  m.colors[lo][2],
                                    });
                                }
                            },
                            else => {},
                        };
                        if (g.skin >= 0) try o.writeAll(" skinned");
                        for (g.av.properties) |pr| {
                            if (pr < 0) continue;
                            switch (nf.blocks[@intCast(pr)]) {
                                .texturing => |t| if (t.base) |bt| try tex(o, nf, bt.source, "base"),
                                .material => |m| try o.print(" mat=\"{s}\"", .{m.net.name}),
                                else => {},
                            }
                        }
                        try o.writeAll("\n");
                    },
                    else => try o.print("[{d}] {s}\n", .{ ref, nf.typeName(@intCast(ref)) }),
                }
            }
        };
        for (parsed.roots) |rt| try Dump.node(out, &parsed, rt, 0);
    } else if (std.mem.eql(u8, cmd, "nifcheck")) {
        const prefix = if (rest.len > 0) rest[0] else "";
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        const Collect = struct {
            list: *std.ArrayList([]const u8),
            gpa: std.mem.Allocator,
            prefix: []const u8,
            fn add(c: @This(), name: []const u8) anyerror!void {
                if (std.mem.startsWith(u8, name, c.prefix) and (std.mem.endsWith(u8, name, ".nif") or std.mem.endsWith(u8, name, ".kf")))
                    try c.list.append(c.gpa, name);
            }
        };
        try vfs.forEach(Collect{ .list = &names, .gpa = gpa, .prefix = prefix }, Collect.add);
        var ok: usize = 0;
        // Failures keyed by "<error> @ <block type>".
        var failures: std.StringHashMapUnmanaged(usize) = .empty;
        defer {
            var kit = failures.keyIterator();
            while (kit.next()) |k| gpa.free(k.*);
            failures.deinit(gpa);
        }
        var examples: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer examples.deinit(gpa);
        var other_err: usize = 0;
        for (names.items) |n| {
            const data = try vfs.read(gpa, n);
            defer gpa.free(data);
            var diag: zootycon2.nif.Diagnostic = .{};
            if (rest.len > 1) std.debug.print("{s}\n", .{n});
            var parsed = zootycon2.nif.parseDiag(gpa, data, &diag) catch |err| {
                other_err += 1;
                if (rest.len > 1) std.debug.print("  {s} at block {d} ({s}) offset {d}\n", .{ @errorName(err), diag.block_index, diag.blockType(), diag.block_start });
                const key = try std.fmt.allocPrint(gpa, "{s} @ {s}", .{ @errorName(err), diag.blockType() });
                const gop = try failures.getOrPut(gpa, key);
                if (gop.found_existing) {
                    gpa.free(key);
                    gop.value_ptr.* += 1;
                } else {
                    gop.value_ptr.* = 1;
                    try examples.put(gpa, gop.key_ptr.*, n);
                }
                continue;
            };
            parsed.deinit();
            ok += 1;
        }
        var fit = failures.iterator();
        while (fit.next()) |e| try out.print("{d:>5}  {s}   e.g. {s}\n", .{ e.value_ptr.*, e.key_ptr.*, examples.get(e.key_ptr.*).? });
        try out.print("{d} files: {d} parsed, {d} failed\n", .{ names.items.len, ok, other_err });
    } else if (std.mem.eql(u8, cmd, "luacheck")) {
        // Loads every compiled script (running its top level, which only
        // defines functions) and reports the ones that fail.
        const prefix = if (rest.len > 0) rest[0] else "scenario/scripts";
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        const Collect = struct {
            list: *std.ArrayList([]const u8),
            gpa: std.mem.Allocator,
            prefix: []const u8,
            fn add(c: @This(), name: []const u8) anyerror!void {
                if (std.mem.startsWith(u8, name, c.prefix) and std.mem.endsWith(u8, name, ".bin")) try c.list.append(c.gpa, name);
            }
        };
        try vfs.forEach(Collect{ .list = &names, .gpa = gpa, .prefix = prefix }, Collect.add);
        var failed: usize = 0;
        for (names.items) |n| {
            // A fresh VM per script so one failure does not hide the next.
            const eng = try zootycon2.script.Engine.create(gpa, &vfs);
            defer eng.destroy();
            eng.load(n) catch |err| {
                failed += 1;
                if (failed <= 25) try out.print("{s}: {s} {s}\n", .{ n, @errorName(err), eng.errorText() });
            };
        }
        try out.print("{d} scripts, {d} failed\n", .{ names.items.len, failed });
    } else if (std.mem.eql(u8, cmd, "scenariotest")) {
        // scenariotest <goals.xml> [ticks]: runs a scenario headless and
        // prints the rule states and the game functions scripts still need.
        if (rest.len < 1) return fail("usage: scenariotest <goals.xml> [ticks]\n");
        const ticks: usize = if (rest.len > 1) std.fmt.parseInt(usize, rest[1], 10) catch 3 else 3;
        var strings = zootycon2.loc.Loc.init(gpa);
        defer strings.deinit();
        try strings.load(&vfs, "lang/1033/");
        const mgr = try zootycon2.scenario.Manager.create(gpa, &vfs, &strings);
        defer mgr.destroy();
        mgr.log = true;
        mgr.eng.log = true;
        try mgr.add(rest[0]);
        for (0..ticks) |_| mgr.tick();
        const Dump = struct {
            fn node(m: *zootycon2.scenario.Manager, o: anytype, n: *const zootycon2.scenario.Node, depth: usize) !void {
                for (0..depth) |_| try o.writeAll("  ");
                try o.print("{s} {s} [{s}]{s}", .{ if (n.is_group) "group" else "rule", n.name, @tagName(n.state), if (n.hidden) " hidden" else "" });
                if (!n.is_group) try o.print(" \"{s}\"", .{m.textFor(n)[0..@min(m.textFor(n).len, 100)]});
                try o.writeAll("\n");
                for (n.children) |k| try node(m, o, k, depth + 1);
            }
        };
        for (mgr.roots.items) |r| try Dump.node(mgr, out, r, 0);
        try out.print("missing game functions ({d}):", .{mgr.eng.missing.count()});
        for (mgr.eng.missing.keys(), mgr.eng.missing.values()) |k, v| try out.print(" {s}({d})", .{ k, v });
        try out.writeAll("\n");
    } else if (std.mem.eql(u8, cmd, "xmlcheck")) {
        const prefix = if (rest.len > 0) rest[0] else "";
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        const Collect = struct {
            list: *std.ArrayList([]const u8),
            gpa: std.mem.Allocator,
            prefix: []const u8,
            fn add(c: @This(), name: []const u8) anyerror!void {
                if (std.mem.startsWith(u8, name, c.prefix) and (std.mem.endsWith(u8, name, ".xml") or std.mem.endsWith(u8, name, ".bfm") or std.mem.endsWith(u8, name, ".bfmat"))) try c.list.append(c.gpa, name);
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
