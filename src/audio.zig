//! Sound from the game's own data. Sound tags (`ui/sound/config.xml`,
//! `entities/sound/*.xml`, `world/soundtags/*.xml`) map names to wav files
//! with volume, pitch, distance and looping settings; animation text keys
//! (`snd 'GruntRoar'`) trigger them. Everything is mixed here to stereo f32
//! and handed to the platform layer, which queues it for the sound device.
//! The WAV decoder handles the PCM and float files the game ships.

const std = @import("std");
const xml = @import("xml.zig");
const vfs_mod = @import("vfs.zig");
const platform = @import("platform.zig");

pub const out_rate: u32 = 44100;
const max_voices = 40;

// ------------------------------------------------------------------ clips

/// A decoded sound: mono samples at their own rate.
pub const Clip = struct {
    samples: []f32,
    rate: u32,

    pub fn deinit(self: *Clip, gpa: std.mem.Allocator) void {
        gpa.free(self.samples);
    }
};

pub const WavError = error{ NotWav, Unsupported, Truncated, OutOfMemory };

fn rd16(b: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, b[o..][0..2], .little);
}
fn rd32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}

/// Decodes PCM (8/16/24/32-bit) or float WAV data to mono.
pub fn decodeWav(gpa: std.mem.Allocator, b: []const u8) WavError!Clip {
    if (b.len < 12 or !std.mem.eql(u8, b[0..4], "RIFF") or !std.mem.eql(u8, b[8..12], "WAVE")) return error.NotWav;
    var pos: usize = 12;
    var tag: u16 = 0;
    var channels: u16 = 0;
    var rate: u32 = 0;
    var bits: u16 = 0;
    var data: ?[]const u8 = null;
    while (pos + 8 <= b.len) {
        const id = b[pos..][0..4];
        const size: usize = rd32(b, pos + 4);
        const body = pos + 8;
        const end = @min(body + size, b.len);
        if (std.mem.eql(u8, id, "fmt ")) {
            if (end - body < 16) return error.Truncated;
            tag = rd16(b, body);
            channels = rd16(b, body + 2);
            rate = rd32(b, body + 4);
            bits = rd16(b, body + 14);
            // WAVE_FORMAT_EXTENSIBLE: the real format is in the sub-format.
            if (tag == 0xFFFE and end - body >= 26) tag = rd16(b, body + 24);
        } else if (std.mem.eql(u8, id, "data")) {
            data = b[body..end];
            break;
        }
        pos = body + size + (size & 1);
    }
    const d = data orelse return error.Truncated;
    if (channels == 0 or rate == 0) return error.Unsupported;
    if (!((tag == 1 and (bits == 8 or bits == 16 or bits == 24 or bits == 32)) or (tag == 3 and bits == 32))) return error.Unsupported;
    const bytes: usize = bits / 8;
    const frame = bytes * channels;
    const n = d.len / frame;
    const out = try gpa.alloc(f32, n);
    errdefer gpa.free(out);
    for (0..n) |i| {
        var sum: f32 = 0;
        for (0..channels) |ch| {
            const o = i * frame + ch * bytes;
            const v: f32 = switch (bits) {
                8 => (@as(f32, @floatFromInt(d[o])) - 128.0) / 128.0,
                16 => @as(f32, @floatFromInt(std.mem.readInt(i16, d[o..][0..2], .little))) / 32768.0,
                24 => blk: {
                    var x: i32 = @as(i32, d[o]) | (@as(i32, d[o + 1]) << 8) | (@as(i32, d[o + 2]) << 16);
                    if (x & 0x800000 != 0) x -= 0x1000000;
                    break :blk @as(f32, @floatFromInt(x)) / 8388608.0;
                },
                else => if (tag == 3)
                    @as(f32, @bitCast(rd32(d, o)))
                else
                    @as(f32, @floatFromInt(std.mem.readInt(i32, d[o..][0..4], .little))) / 2147483648.0,
            };
            sum += v;
        }
        out[i] = sum / @as(f32, @floatFromInt(channels));
    }
    return .{ .samples = out, .rate = rate };
}

// ------------------------------------------------------------------ tags

pub const Snd = struct {
    file: []const u8,
    volume: f32 = 1,
    /// `randvolume`: a random volume in [vmin, vmax] each time.
    rand_volume: bool = false,
    vmin: f32 = 1,
    vmax: f32 = 1,
    pmin: f32 = 1,
    pmax: f32 = 1,
    rand_pan: bool = false,
    looping: bool = false,
    mindist: f32 = 0,
    maxdist: f32 = 0,
};

pub const Tag = struct { snds: []const Snd, is3d: bool };

/// An ambient sound that plays now and then (`BFAmbient2DSndFactory`).
pub const Ambient = struct { tag: []const u8, min_delay: f32, max_delay: f32 };

fn fattr(e: *const xml.Element, name: []const u8, default: f32) f32 {
    const v = e.attr(name) orelse return default;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch default;
}

fn battr(e: *const xml.Element, name: []const u8) bool {
    const v = e.attr(name) orelse return false;
    return std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true");
}

pub const Library = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tags: std.StringHashMapUnmanaged(Tag) = .empty,
    /// Ambient factories by the file stem they were defined in (a biome).
    ambients: std.StringHashMapUnmanaged([]const Ambient) = .empty,

    pub fn init(gpa: std.mem.Allocator) Library {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(self: *Library) void {
        self.tags.deinit(self.gpa);
        self.ambients.deinit(self.gpa);
        self.arena.deinit();
    }

    /// Reads every sound-tag file in the game data.
    pub fn load(self: *Library, vfs: *vfs_mod.Vfs) void {
        const Collect = struct {
            list: *std.ArrayList([]const u8),
            gpa: std.mem.Allocator,
            fn add(c: @This(), name: []const u8) anyerror!void {
                const ok = std.mem.eql(u8, name, "ui/sound/config.xml") or
                    ((std.mem.startsWith(u8, name, "entities/sound/") or std.mem.startsWith(u8, name, "world/soundtags/")) and std.mem.endsWith(u8, name, ".xml"));
                if (ok) try c.list.append(c.gpa, name);
            }
        };
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.gpa);
        vfs.forEach(Collect{ .list = &names, .gpa = self.gpa }, Collect.add) catch return;
        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        for (names.items) |n| {
            const data = vfs.read(self.gpa, n) catch continue;
            defer self.gpa.free(data);
            self.addFile(n, data) catch {};
        }
    }

    pub fn addFile(self: *Library, path: []const u8, data: []const u8) !void {
        const a = self.arena.allocator();
        const root = try xml.parse(a, data, null);
        const stem = std.fs.path.stem(path);
        var amb: std.ArrayList(Ambient) = .empty;
        try self.visit(root, stem, &amb);
        if (amb.items.len > 0) try self.ambients.put(self.gpa, try a.dupe(u8, stem), try amb.toOwnedSlice(a));
    }

    fn visit(self: *Library, e: *const xml.Element, stem: []const u8, amb: *std.ArrayList(Ambient)) !void {
        const a = self.arena.allocator();
        const is2 = std.ascii.eqlIgnoreCase(e.name, "BF2DSndFactory");
        const is3 = std.ascii.eqlIgnoreCase(e.name, "BF3DSndFactory");
        if (is2 or is3) {
            if (e.attr("name")) |name| {
                var list: std.ArrayList(Snd) = .empty;
                for (e.children) |c| {
                    if (!std.ascii.eqlIgnoreCase(c.name, "snd")) continue;
                    const file = c.attr("name") orelse continue;
                    var s: Snd = .{ .file = try normPath(a, file) };
                    s.volume = fattr(c, "volume", 1);
                    s.rand_volume = battr(c, "randvolume");
                    s.vmin = fattr(c, "minvolume", s.volume);
                    s.vmax = fattr(c, "maxvolume", s.volume);
                    s.pmin = fattr(c, "minpitch", 1);
                    s.pmax = fattr(c, "maxpitch", 1);
                    s.rand_pan = battr(c, "randpan");
                    s.looping = battr(c, "looping");
                    s.mindist = fattr(c, "mindist", 0);
                    s.maxdist = fattr(c, "maxdist", 0);
                    try list.append(a, s);
                }
                if (list.items.len > 0) {
                    const key = try a.dupe(u8, name);
                    for (key) |*ch| ch.* = std.ascii.toLower(ch.*);
                    try self.tags.put(self.gpa, key, .{ .snds = try list.toOwnedSlice(a), .is3d = is3 });
                }
            }
            return;
        }
        if (std.ascii.eqlIgnoreCase(e.name, "BFAmbient2DSndFactory")) {
            for (e.children) |c| {
                if (!std.ascii.eqlIgnoreCase(c.name, "snds")) continue;
                for (c.children) |s| {
                    const t = s.attr("name") orelse continue;
                    try amb.append(a, .{ .tag = try a.dupe(u8, t), .min_delay = fattr(s, "mindelay", 20), .max_delay = fattr(s, "maxdelay", 60) });
                }
            }
            return;
        }
        for (e.children) |c| try self.visit(c, stem, amb);
    }

    pub fn find(self: *const Library, name: []const u8) ?*const Tag {
        var buf: [128]u8 = undefined;
        if (name.len > buf.len) return null;
        return self.tags.getPtr(std.ascii.lowerString(&buf, name));
    }
};

/// Normalised (lowercase, forward slash) path with stray spaces kept as the
/// data has them.
fn normPath(a: std.mem.Allocator, p: []const u8) ![]const u8 {
    const out = try a.dupe(u8, p);
    for (out) |*c| c.* = if (c.* == '\\') '/' else std.ascii.toLower(c.*);
    return out;
}

// ----------------------------------------------------------------- mixer

const Voice = struct {
    clip: *const Clip,
    pos: f64 = 0,
    step: f64,
    gl: f32,
    gr: f32,
    looping: bool,
    /// Loop voices are kept by name so they can be stopped.
    loop_id: u32 = 0,
};

pub const Listener = struct {
    pos: [3]f32 = .{ 0, 0, 0 },
    /// Unit vector pointing to the listener's right on the ground plane.
    right: [2]f32 = .{ 1, 0 },
};

const Pending = struct { at: f64, tag: []const u8, pos: ?[3]f32 };

const TextKey = struct { frame: f32, sound: []const u8 };

pub const Engine = struct {
    gpa: std.mem.Allocator,
    vfs: *vfs_mod.Vfs,
    lib: Library,
    out: ?platform.AudioOut = null,
    voices: [max_voices]?Voice = @splat(null),
    clips: std.StringHashMapUnmanaged(?*Clip) = .empty,
    keys: std.StringHashMapUnmanaged([]const TextKey) = .empty,
    keys_arena: std.heap.ArenaAllocator,
    pending: std.ArrayList(Pending) = .empty,
    listener: Listener = .{},
    rng: std.Random.DefaultPrng,
    /// Master volume 0..1 and whether anything is played at all.
    volume: f32 = 0.8,
    enabled: bool = true,
    /// Our distances are larger than the game's (the camera is higher up).
    dist_scale: f32 = 1.0,
    time: f64 = 0,
    /// (tag hash, time) of recent sounds, to stop one tag machine-gunning.
    recent: [16]struct { h: u64 = 0, t: f64 = -1 } = @splat(.{}),
    recent_i: usize = 0,
    ambient_biome: []const u8 = "",
    ambient_timers: std.ArrayList(f32) = .empty,
    ambient_loop: u32 = 0,
    scratch: [1024 * 2]f32 = undefined,
    /// Sounds started so far (diagnostics).
    played: u32 = 0,
    last_tag: []const u8 = "",

    pub fn init(gpa: std.mem.Allocator, vfs: *vfs_mod.Vfs, seed: u64, want_device: bool) Engine {
        var e: Engine = .{ .gpa = gpa, .vfs = vfs, .lib = Library.init(gpa), .keys_arena = .init(gpa), .rng = .init(seed) };
        e.lib.load(vfs);
        if (want_device) e.out = platform.AudioOut.open(out_rate);
        return e;
    }

    pub fn deinit(self: *Engine) void {
        if (self.out) |o| o.close();
        var it = self.clips.valueIterator();
        while (it.next()) |c| if (c.*) |cl| {
            cl.deinit(self.gpa);
            self.gpa.destroy(cl);
        };
        var kit = self.clips.keyIterator();
        while (kit.next()) |k| self.gpa.free(k.*);
        self.clips.deinit(self.gpa);
        self.keys.deinit(self.gpa);
        self.keys_arena.deinit();
        self.pending.deinit(self.gpa);
        self.ambient_timers.deinit(self.gpa);
        self.lib.deinit();
    }

    pub fn hasDevice(self: *const Engine) bool {
        return self.out != null;
    }

    fn clip(self: *Engine, path: []const u8) ?*const Clip {
        if (self.clips.get(path)) |c| return c;
        var result: ?*Clip = null;
        if (self.vfs.read(self.gpa, path)) |bytes| {
            defer self.gpa.free(bytes);
            if (decodeWav(self.gpa, bytes)) |cl| {
                if (self.gpa.create(Clip)) |p| {
                    p.* = cl;
                    result = p;
                } else |_| {
                    var m = cl;
                    m.deinit(self.gpa);
                }
            } else |_| {}
        } else |_| {}
        const key = self.gpa.dupe(u8, path) catch return result;
        self.clips.put(self.gpa, key, result) catch self.gpa.free(key);
        return result;
    }

    fn recentlyPlayed(self: *Engine, name: []const u8) bool {
        const h = std.hash.Wyhash.hash(0, name);
        for (self.recent) |r| if (r.h == h and self.time - r.t < 0.2) return true;
        self.recent[self.recent_i] = .{ .h = h, .t = self.time };
        self.recent_i = (self.recent_i + 1) % self.recent.len;
        return false;
    }

    /// Plays a tag by name. With `pos`, a 3D tag is attenuated and panned
    /// by its distance from the listener. Returns false if it is unknown or
    /// out of earshot.
    pub fn play(self: *Engine, name: []const u8, pos: ?[3]f32) bool {
        if (!self.enabled) return false;
        const tag = self.lib.find(name) orelse return false;
        if (tag.snds.len == 0) return false;
        if (self.recentlyPlayed(name)) return false;
        const rnd = self.rng.random();
        const s = tag.snds[rnd.uintLessThan(usize, tag.snds.len)];
        self.last_tag = name;
        return self.start(s, tag.is3d, pos, 0);
    }

    fn start(self: *Engine, s: Snd, is3d: bool, pos: ?[3]f32, loop_id: u32) bool {
        const cl = self.clip(s.file) orelse return false;
        const rnd = self.rng.random();
        var vol = if (s.rand_volume) s.vmin + rnd.float(f32) * (s.vmax - s.vmin) else s.volume;
        var pan: f32 = 0;
        if (is3d or s.maxdist > 0) if (pos) |p| {
            const dx = p[0] - self.listener.pos[0];
            const dy = p[1] - self.listener.pos[1];
            const dz = p[2] - self.listener.pos[2];
            const d = @sqrt(dx * dx + dy * dy + dz * dz) / self.dist_scale;
            const maxd = if (s.maxdist > 0) s.maxdist else 40;
            if (d >= maxd) return false;
            const mind = s.mindist;
            if (d > mind) vol *= (maxd - d) / (maxd - mind);
            const dl = @max(d * self.dist_scale, 0.001);
            pan = std.math.clamp((dx * self.listener.right[0] + dy * self.listener.right[1]) / dl, -1, 1) * 0.8;
        };
        if (s.rand_pan) pan = (rnd.float(f32) * 2 - 1) * 0.7;
        if (vol < 0.01) return false;
        const pitch = s.pmin + rnd.float(f32) * (s.pmax - s.pmin);
        const ang = (pan + 1) * std.math.pi / 4.0;
        const v = Voice{
            .clip = cl,
            .step = @as(f64, @floatFromInt(cl.rate)) * pitch / @as(f64, @floatFromInt(out_rate)),
            .gl = vol * @cos(ang),
            .gr = vol * @sin(ang),
            .looping = s.looping,
            .loop_id = loop_id,
        };
        // A free voice, else the one that is furthest along.
        var slot: usize = 0;
        var best: f64 = -1;
        for (self.voices, 0..) |mv, i| {
            if (mv == null) {
                slot = i;
                best = 1e18;
                break;
            }
            const frac = mv.?.pos / @as(f64, @floatFromInt(@max(1, mv.?.clip.samples.len)));
            if (!mv.?.looping and frac > best) {
                best = frac;
                slot = i;
            }
        }
        if (best < 0) return false;
        self.voices[slot] = v;
        self.played += 1;
        return true;
    }

    /// Plays a tag after `delay` seconds.
    pub fn playLater(self: *Engine, name: []const u8, pos: ?[3]f32, delay: f32) void {
        self.pending.append(self.gpa, .{ .at = self.time + delay, .tag = name, .pos = pos }) catch {};
    }

    /// Text keys (`snd 'Name'`) of an animation file, cached.
    fn textKeys(self: *Engine, anim_path: []const u8) []const TextKey {
        if (self.keys.get(anim_path)) |k| return k;
        const a = self.keys_arena.allocator();
        var list: std.ArrayList(TextKey) = .empty;
        var path_buf: [512]u8 = undefined;
        if (anim_path.len > 3 and anim_path.len < path_buf.len - 8 and std.ascii.endsWithIgnoreCase(anim_path, ".bf")) {
            const base = anim_path[0 .. anim_path.len - 3];
            const kp = std.fmt.bufPrint(&path_buf, "{s}.txtkeys", .{base}) catch "";
            if (kp.len > 0) {
                if (self.vfs.read(self.gpa, kp)) |bytes| {
                    defer self.gpa.free(bytes);
                    if (xml.parse(a, bytes, null)) |root| {
                        for (root.children) |c| {
                            const text = c.attr("text") orelse continue;
                            const si = std.mem.indexOf(u8, text, "snd '") orelse continue;
                            const rest = text[si + 5 ..];
                            const q = std.mem.indexOfScalar(u8, rest, '\'') orelse continue;
                            list.append(a, .{ .frame = fattr(c, "frame", 0), .sound = rest[0..q] }) catch {};
                        }
                    } else |_| {}
                } else |_| {}
            }
        }
        const owned = list.toOwnedSlice(a) catch &[_]TextKey{};
        const key = a.dupe(u8, anim_path) catch return owned;
        self.keys.put(self.gpa, key, owned) catch {};
        return owned;
    }

    /// An actor started an animation: play the sounds its text keys name.
    /// The tag is the entity name plus the key (`Lion_Adult_F` + `GruntRoar`),
    /// falling back to the entity name without its last part.
    pub fn animStarted(self: *Engine, binder: []const u8, anim_path: []const u8, pos: [3]f32) void {
        if (!self.enabled) return;
        const keys = self.textKeys(anim_path);
        for (keys) |k| {
            var buf: [160]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}_{s}", .{ binder, k.sound }) catch continue;
            var chosen: ?[]const u8 = null;
            if (self.lib.find(full) != null) {
                chosen = self.keys_arena.allocator().dupe(u8, full) catch null;
            } else if (std.mem.lastIndexOfScalar(u8, binder, '_')) |ix| {
                const alt = std.fmt.bufPrint(&buf, "{s}_{s}", .{ binder[0..ix], k.sound }) catch continue;
                if (self.lib.find(alt) != null) chosen = self.keys_arena.allocator().dupe(u8, alt) catch null;
            }
            if (chosen) |t| self.playLater(t, pos, k.frame / 30.0);
        }
    }

    pub fn setListener(self: *Engine, pos: [3]f32, yaw: f32) void {
        self.listener.pos = pos;
        // The camera looks along -(cos yaw, sin yaw); its right is perpendicular.
        self.listener.right = .{ -@sin(yaw), @cos(yaw) };
    }

    /// Starts the ambience for a biome: its loop tag (`<biome>_loop`) and the
    /// occasional sounds its tag file lists.
    pub fn setBiome(self: *Engine, biome: []const u8) void {
        if (std.mem.eql(u8, biome, self.ambient_biome)) return;
        self.ambient_biome = biome;
        self.stopLoop(self.ambient_loop);
        self.ambient_loop = 0;
        self.ambient_timers.clearRetainingCapacity();
        if (!self.enabled) return;
        var buf: [96]u8 = undefined;
        const loop_name = std.fmt.bufPrint(&buf, "{s}_loop", .{biome}) catch return;
        if (self.lib.find(loop_name)) |t| if (t.snds.len > 0) {
            self.ambient_loop = 1;
            _ = self.start(t.snds[0], false, null, 1);
        };
        if (self.lib.ambients.get(biome)) |list| {
            const rnd = self.rng.random();
            for (list) |am| self.ambient_timers.append(self.gpa, am.min_delay * 0.3 + rnd.float(f32) * 10) catch {};
        }
    }

    fn stopLoop(self: *Engine, id: u32) void {
        if (id == 0) return;
        for (&self.voices) |*v| if (v.*) |vv| if (vv.loop_id == id) {
            v.* = null;
        };
    }

    /// Mutes or unmutes everything.
    pub fn setEnabled(self: *Engine, on: bool) void {
        if (on == self.enabled) return;
        self.enabled = on;
        if (!on) {
            for (&self.voices) |*v| v.* = null;
            self.pending.clearRetainingCapacity();
            self.ambient_loop = 0;
            self.ambient_biome = "";
        }
    }

    /// Advances time, starts due sounds and keeps the device fed.
    pub fn update(self: *Engine, dt: f32) void {
        self.time += dt;
        if (!self.enabled) return;
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].at <= self.time) {
                const p = self.pending.swapRemove(i);
                _ = self.play(p.tag, p.pos);
            } else i += 1;
        }
        if (self.lib.ambients.get(self.ambient_biome)) |list| {
            for (self.ambient_timers.items, 0..) |*t, ti| {
                t.* -= dt;
                if (t.* <= 0 and ti < list.len) {
                    const rnd = self.rng.random();
                    t.* = list[ti].min_delay + rnd.float(f32) * (list[ti].max_delay - list[ti].min_delay);
                    _ = self.play(list[ti].tag, null);
                }
            }
        }
        const o = self.out orelse return;
        // Keep about a fifth of a second queued.
        const target: usize = out_rate / 5 * 8;
        var guard: usize = 0;
        while (o.queued() < target and guard < 16) : (guard += 1) {
            self.mix(&self.scratch, 1024);
            o.put(&self.scratch);
        }
    }

    /// Mixes `frames` stereo frames into `out`.
    pub fn mix(self: *Engine, out: []f32, frames: usize) void {
        @memset(out[0 .. frames * 2], 0);
        for (&self.voices) |*mv| {
            const v = &(mv.* orelse continue);
            const n: f64 = @floatFromInt(v.clip.samples.len);
            var f: usize = 0;
            while (f < frames) : (f += 1) {
                if (v.pos >= n) {
                    if (v.looping and n > 0) v.pos = @mod(v.pos, n) else {
                        mv.* = null;
                        break;
                    }
                }
                const ip: usize = @intFromFloat(v.pos);
                const frac: f32 = @floatCast(v.pos - @as(f64, @floatFromInt(ip)));
                const s0 = v.clip.samples[ip];
                const s1 = if (ip + 1 < v.clip.samples.len) v.clip.samples[ip + 1] else if (v.looping) v.clip.samples[0] else s0;
                const s = (s0 + (s1 - s0) * frac) * self.volume;
                out[f * 2] += s * v.gl;
                out[f * 2 + 1] += s * v.gr;
                v.pos += v.step;
            }
        }
        for (out[0 .. frames * 2]) |*s| s.* = std.math.clamp(s.*, -1, 1);
    }
};

// ------------------------------------------------------------------ tests

test "decode a small 16-bit mono wav" {
    const gpa = std.testing.allocator;
    var b: [44 + 8]u8 = undefined;
    @memcpy(b[0..4], "RIFF");
    std.mem.writeInt(u32, b[4..8], 36 + 8, .little);
    @memcpy(b[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, b[16..20], 16, .little);
    std.mem.writeInt(u16, b[20..22], 1, .little);
    std.mem.writeInt(u16, b[22..24], 1, .little);
    std.mem.writeInt(u32, b[24..28], 22050, .little);
    std.mem.writeInt(u32, b[28..32], 44100, .little);
    std.mem.writeInt(u16, b[32..34], 2, .little);
    std.mem.writeInt(u16, b[34..36], 16, .little);
    @memcpy(b[36..40], "data");
    std.mem.writeInt(u32, b[40..44], 8, .little);
    std.mem.writeInt(i16, b[44..46], 16384, .little);
    std.mem.writeInt(i16, b[46..48], -16384, .little);
    std.mem.writeInt(i16, b[48..50], 0, .little);
    std.mem.writeInt(i16, b[50..52], 32767, .little);
    var c = try decodeWav(gpa, &b);
    defer c.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 22050), c.rate);
    try std.testing.expectEqual(@as(usize, 4), c.samples.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), c.samples[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), c.samples[1], 1e-4);
}

test "sound tags and ambient lists are read from the game's xml" {
    const gpa = std.testing.allocator;
    var lib = Library.init(gpa);
    defer lib.deinit();
    try lib.addFile("world/soundtags/alpine.xml",
        \\<soundtags><BFSoundtag><BF2DSndFactory name="Hawk_03">
        \\<snd name="sound/B_AP_Hawk03.wav" randpan="1" randvolume="1" minpitch=".9" maxpitch="1.1" minvolume=".15" maxvolume=".22"/>
        \\</BF2DSndFactory></BFSoundtag>
        \\<BFSoundtag><BFAmbient2DSndFactory name="a"><snds><snd name="Hawk_03" mindelay="25" maxdelay="100"/></snds></BFAmbient2DSndFactory></BFSoundtag>
        \\</soundtags>
    );
    try lib.addFile("entities/sound/lion.xml",
        \\<soundtags><BFSoundtag><BF3DSndFactory name="Lion_Adult_Bit">
        \\<snd name="entities\units\Lion.wav" volume="0.5" mindist="6" maxdist="25"/></BF3DSndFactory></BFSoundtag></soundtags>
    );
    const h = lib.find("hawk_03").?;
    try std.testing.expect(!h.is3d);
    try std.testing.expect(h.snds[0].rand_pan and h.snds[0].rand_volume);
    try std.testing.expectEqualStrings("sound/b_ap_hawk03.wav", h.snds[0].file);
    const l = lib.find("LION_adult_bit").?;
    try std.testing.expect(l.is3d);
    try std.testing.expectEqualStrings("entities/units/lion.wav", l.snds[0].file);
    try std.testing.expectEqual(@as(f32, 25), l.snds[0].maxdist);
    try std.testing.expectEqual(@as(usize, 1), lib.ambients.get("alpine").?.len);
}
