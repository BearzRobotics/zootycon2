//! Time-of-day environment: lights, ambient colour and fog, read from the
//! game's own files and sampled for any time of day (0..1, wrapping).
//!
//! Files used (paths come from the map's environment file):
//!   `world/lights/<biome>Lights.xml`: `terrainLights` and `objectLights`,
//!     each with `tods` (named keyframes: `t`, `ambient`) and `lights`
//!     (`sunlight`, `sidelight`, `backlight`, each with one element per
//!     keyframe name giving `diffuse`, `direction`, `intensity`).
//!   `world/environments/<biome>_fog.xml`: `FogKeyframeArgs` with `time`,
//!     `start` and `end` (fractions of the fog distance) and `color` (0-255),
//!     in `low`, `medium` and `high` quality sections.
//!   `world/environments/sky/<biome>_sky.xml`: `interpTimes` of the sky dome.

const std = @import("std");
const xml = @import("xml.zig");

pub const Rgb = [3]f32;
pub const Vec3 = [3]f32;

pub const AmbientKey = struct { t: f32, color: Rgb };
pub const LightKey = struct { t: f32, color: Rgb, dir: Vec3, intensity: f32 };
pub const FogKey = struct { t: f32, start: f32, end: f32, color: Rgb };

/// Ambient light plus the sun, side and back lights for one kind of surface.
pub const LightSet = struct {
    ambient: []const AmbientKey = &.{},
    /// sun, side, back
    lights: [3][]const LightKey = .{ &.{}, &.{}, &.{} },
};

/// Everything the shader needs for one moment of the day.
pub const Sample = struct {
    /// Index 0 is terrain, index 1 is objects.
    ambient: [2]Rgb,
    /// Direction the light travels (unit), per set and light.
    dir: [2][3]Vec3,
    /// Diffuse colour already multiplied by intensity.
    color: [2][3]Rgb,
    fog_color: Rgb,
    fog_start: f32,
    fog_end: f32,
};

pub const Environment = struct {
    arena: std.heap.ArenaAllocator,
    terrain: LightSet = .{},
    objects: LightSet = .{},
    fog: []const FogKey = &.{},
    /// Times at which the sky dome keyframes (night, sunrise, ... night) apply.
    sky_times: []const f32 = &.{},

    pub fn deinit(self: *Environment) void {
        self.arena.deinit();
    }

    /// `lights_xml` is required; the others may be null (defaults are used).
    pub fn parse(gpa: std.mem.Allocator, lights_xml: []const u8, fog_xml: ?[]const u8, sky_xml: ?[]const u8) !Environment {
        var env: Environment = .{ .arena = .init(gpa) };
        errdefer env.arena.deinit();
        const a = env.arena.allocator();

        const lroot = xml.parse(a, lights_xml, null) catch return error.BadEnvironment;
        if (lroot.child("terrainLights")) |t| env.terrain = try parseSet(a, t);
        if (lroot.child("objectLights")) |o| env.objects = try parseSet(a, o);

        if (fog_xml) |text| {
            if (xml.parse(a, text, null)) |froot| {
                // Prefer the medium quality keyframes.
                const sect = froot.child("medium") orelse froot.child("high") orelse froot.child("low");
                if (sect) |s| env.fog = try parseFog(a, s);
            } else |_| {}
        }
        if (sky_xml) |text| {
            if (xml.parse(a, text, null)) |sroot| env.sky_times = (try parseSkyTimes(a, sroot)) orelse &.{} else |_| {}
        }
        return env;
    }

    pub fn sample(self: *const Environment, tod: f32) Sample {
        const t = tod - @floor(tod);
        var out: Sample = undefined;
        const sets = [2]*const LightSet{ &self.terrain, &self.objects };
        for (sets, 0..) |set, si| {
            out.ambient[si] = sampleAmbient(set.ambient, t);
            for (0..3) |li| {
                const k = sampleLight(set.lights[li], t);
                out.dir[si][li] = k.dir;
                out.color[si][li] = .{ k.color[0] * k.intensity, k.color[1] * k.intensity, k.color[2] * k.intensity };
            }
        }
        const f = sampleFog(self.fog, t);
        out.fog_color = f.color;
        out.fog_start = f.start;
        out.fog_end = f.end;
        return out;
    }
};

fn parseFloats(comptime n: usize, text: []const u8) ?[n]f32 {
    var out: [n]f32 = undefined;
    var it = std.mem.tokenizeAny(u8, text, " \t,");
    for (&out) |*v| {
        const tok = it.next() orelse return null;
        v.* = std.fmt.parseFloat(f32, tok) catch return null;
    }
    return out;
}

fn attrF(e: *const xml.Element, name: []const u8, default: f32) f32 {
    const v = e.attr(name) orelse return default;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch default;
}

const NamedTime = struct { name: []const u8, t: f32 };

fn parseSet(a: std.mem.Allocator, e: *const xml.Element) !LightSet {
    var set: LightSet = .{};
    var names: std.ArrayList(NamedTime) = .empty;
    if (e.child("tods")) |tods| {
        var amb: std.ArrayList(AmbientKey) = .empty;
        for (tods.children) |k| {
            const t = attrF(k, "t", -1);
            if (t < 0) continue;
            const rgb = parseFloats(3, k.attr("ambient") orelse "") orelse continue;
            try amb.append(a, .{ .t = t, .color = rgb });
            try names.append(a, .{ .name = k.name, .t = t });
        }
        std.mem.sort(AmbientKey, amb.items, {}, struct {
            fn less(_: void, x: AmbientKey, y: AmbientKey) bool {
                return x.t < y.t;
            }
        }.less);
        set.ambient = try amb.toOwnedSlice(a);
    }
    if (e.child("lights")) |lights| {
        const light_names = [3][]const u8{ "sunlight", "sidelight", "backlight" };
        for (light_names, 0..) |ln, li| {
            const le = lights.child(ln) orelse continue;
            var keys: std.ArrayList(LightKey) = .empty;
            for (le.children) |k| {
                var t: f32 = -1;
                for (names.items) |nt| if (std.ascii.eqlIgnoreCase(nt.name, k.name)) {
                    t = nt.t;
                };
                if (t < 0) continue;
                const col = parseFloats(3, k.attr("diffuse") orelse "") orelse continue;
                const dir = parseFloats(3, k.attr("direction") orelse "") orelse continue;
                try keys.append(a, .{ .t = t, .color = col, .dir = normalize(dir), .intensity = attrF(k, "intensity", 1) });
            }
            std.mem.sort(LightKey, keys.items, {}, struct {
                fn less(_: void, x: LightKey, y: LightKey) bool {
                    return x.t < y.t;
                }
            }.less);
            set.lights[li] = try keys.toOwnedSlice(a);
        }
    }
    return set;
}

fn parseFog(a: std.mem.Allocator, e: *const xml.Element) ![]const FogKey {
    var keys: std.ArrayList(FogKey) = .empty;
    for (e.children) |k| {
        const rgb = parseFloats(3, k.attr("color") orelse "") orelse continue;
        try keys.append(a, .{
            .t = attrF(k, "time", 0),
            .start = attrF(k, "start", 0),
            .end = attrF(k, "end", 1),
            .color = .{ rgb[0] / 255.0, rgb[1] / 255.0, rgb[2] / 255.0 },
        });
    }
    std.mem.sort(FogKey, keys.items, {}, struct {
        fn less(_: void, x: FogKey, y: FogKey) bool {
            return x.t < y.t;
        }
    }.less);
    return keys.toOwnedSlice(a);
}

fn parseSkyTimes(a: std.mem.Allocator, root: *const xml.Element) !?[]const f32 {
    for (root.children) |layer| {
        const it = layer.child("interpTimes") orelse continue;
        // Only the colour-interpolating dome has more than a few keys and
        // starts at t1="0.0"; the first `interpTimes` is that layer's.
        var times: std.ArrayList(f32) = .empty;
        for (it.attributes) |at| {
            const v = std.fmt.parseFloat(f32, std.mem.trim(u8, at.value, " ")) catch continue;
            try times.append(a, v);
        }
        std.mem.sort(f32, times.items, {}, std.sort.asc(f32));
        return try times.toOwnedSlice(a);
    }
    return null;
}

fn normalize(v: Vec3) Vec3 {
    const l = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (l == 0) return v;
    return .{ v[0] / l, v[1] / l, v[2] / l };
}

/// Index of the keyframe at or before `t` and the blend towards the next
/// (wrapping around the day).
fn segment(times: anytype, t: f32) struct { i: usize, j: usize, f: f32 } {
    const n = times.len;
    if (n == 1) return .{ .i = 0, .j = 0, .f = 0 };
    var i: usize = n - 1; // before the first key: the last one, wrapped
    for (times, 0..) |k, idx| {
        if (k.t <= t) i = idx else break;
    }
    const j = (i + 1) % n;
    const t0 = times[i].t;
    var t1 = times[j].t;
    var tt = t;
    if (t1 <= t0) t1 += 1; // wrap
    if (tt < t0) tt += 1;
    const span = t1 - t0;
    return .{ .i = i, .j = j, .f = if (span > 0) std.math.clamp((tt - t0) / span, 0, 1) else 0 };
}

fn lerp(a: f32, b: f32, f: f32) f32 {
    return a + (b - a) * f;
}

fn lerp3(a: Vec3, b: Vec3, f: f32) Vec3 {
    return .{ lerp(a[0], b[0], f), lerp(a[1], b[1], f), lerp(a[2], b[2], f) };
}

fn sampleAmbient(keys: []const AmbientKey, t: f32) Rgb {
    if (keys.len == 0) return .{ 0.4, 0.4, 0.4 };
    const s = segment(keys, t);
    return lerp3(keys[s.i].color, keys[s.j].color, s.f);
}

fn sampleLight(keys: []const LightKey, t: f32) LightKey {
    if (keys.len == 0) return .{ .t = 0, .color = .{ 0, 0, 0 }, .dir = .{ 0, 0, -1 }, .intensity = 0 };
    const s = segment(keys, t);
    return .{
        .t = t,
        .color = lerp3(keys[s.i].color, keys[s.j].color, s.f),
        .dir = normalize(lerp3(keys[s.i].dir, keys[s.j].dir, s.f)),
        .intensity = lerp(keys[s.i].intensity, keys[s.j].intensity, s.f),
    };
}

fn sampleFog(keys: []const FogKey, t: f32) FogKey {
    if (keys.len == 0) return .{ .t = 0, .start = 0, .end = 1, .color = .{ 0.6, 0.7, 0.8 } };
    const s = segment(keys, t);
    return .{
        .t = t,
        .start = lerp(keys[s.i].start, keys[s.j].start, s.f),
        .end = lerp(keys[s.i].end, keys[s.j].end, s.f),
        .color = lerp3(keys[s.i].color, keys[s.j].color, s.f),
    };
}

/// Blend factors between sky dome keyframes for time `t`: indices of the two
/// keyframes and the weight of the second.
pub fn skyBlend(times: []const f32, t: f32) struct { i: usize, j: usize, f: f32 } {
    const tt = t - @floor(t);
    if (times.len < 2) return .{ .i = 0, .j = 0, .f = 0 };
    var i: usize = 0;
    for (times, 0..) |k, idx| {
        if (k <= tt) i = idx;
    }
    const j = @min(i + 1, times.len - 1);
    const span = times[j] - times[i];
    return .{ .i = i, .j = j, .f = if (span > 0) std.math.clamp((tt - times[i]) / span, 0, 1) else 0 };
}

const testing = std.testing;

const test_lights =
    \\<lights><terrainLights>
    \\ <tods>
    \\  <nightbegin t="0.0" ambient="0 0 0" shadow="1"/>
    \\  <noon0 t="0.5" ambient="1 0.5 0" shadow="1"/>
    \\  <nightend t="1.0" ambient="0 0 0" shadow="1"/>
    \\ </tods>
    \\ <lights><sunlight>
    \\  <nightbegin diffuse="0 0 1" direction="0 0 -1" intensity="0.2"/>
    \\  <noon0 diffuse="1 1 1" direction="0 1 -1" intensity="1.0"/>
    \\  <nightend diffuse="0 0 1" direction="0 0 -1" intensity="0.2"/>
    \\ </sunlight></lights>
    \\</terrainLights></lights>
;

test "keyframes interpolate and wrap" {
    var env = try Environment.parse(testing.allocator, test_lights,
        \\<fog><medium><FogKeyframeArgs time="0" start="0" end="0.2" color="0 0 255"/><FogKeyframeArgs time="0.5" start="0" end="1.0" color="255 255 255"/></medium></fog>
    , null);
    defer env.deinit();
    const noon = env.sample(0.5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), noon.ambient[0][0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), noon.ambient[0][1], 1e-5);
    // sun at noon: full intensity, direction normalised
    try testing.expectApproxEqAbs(@as(f32, 1.0), noon.color[0][0][0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.7071), noon.dir[0][0][1], 1e-3);
    // halfway to noon: ambient halves, intensity between 0.2 and 1.0
    const dawn = env.sample(0.25);
    try testing.expectApproxEqAbs(@as(f32, 0.5), dawn.ambient[0][0], 1e-5);
    // colour (0,0,1)->(1,1,1) is (0.5,0.5,1) at the midpoint, times intensity 0.6
    try testing.expectApproxEqAbs(@as(f32, 0.3), dawn.color[0][0][0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0.6), dawn.color[0][0][2], 1e-4);
    // the day wraps: t = 1.25 equals t = 0.25
    const wrapped = env.sample(1.25);
    try testing.expectApproxEqAbs(dawn.ambient[0][0], wrapped.ambient[0][0], 1e-5);
    // fog keyframes: blue at night, white at t=0.5; past the last key it blends back
    const f0 = env.sample(0.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), f0.fog_color[2], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), f0.fog_color[0], 1e-5);
    const f1 = env.sample(0.5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), f1.fog_color[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), f1.fog_end, 1e-5);
    // a set that is missing gets a harmless default
    try testing.expectApproxEqAbs(@as(f32, 0.4), noon.ambient[1][0], 1e-5);
}

test "sky blend" {
    const times = [_]f32{ 0, 0.5, 1.0 };
    const b = skyBlend(&times, 0.25);
    try testing.expectEqual(@as(usize, 0), b.i);
    try testing.expectEqual(@as(usize, 1), b.j);
    try testing.expectApproxEqAbs(@as(f32, 0.5), b.f, 1e-5);
    const late = skyBlend(&times, 0.999);
    try testing.expectEqual(@as(usize, 1), late.i);
    try testing.expectEqual(@as(usize, 2), late.j);
    // exactly 1.0 is the start of the next day
    try testing.expectEqual(@as(usize, 0), skyBlend(&times, 1.0).i);
}

test "sky times come from the first interpTimes" {
    var env = try Environment.parse(testing.allocator, test_lights, null,
        \\<skylayers><Dome><interpTimes t1="0.0" t2="0.5" t3="1.0"/></Dome></skylayers>
    );
    defer env.deinit();
    try testing.expectEqual(@as(usize, 3), env.sky_times.len);
    try testing.expectApproxEqAbs(@as(f32, 0.5), env.sky_times[1], 1e-6);
}
