//! Data-driven animal behaviour, read from the game's `ai/tasks` files.
//!
//! The game describes behaviour in two kinds of file per species:
//!
//!   `<species>.tsk`  task templates. A task names the subjects it applies
//!     to (species or age/sex groups), qualifiers on the subject's needs
//!     (`rest="LE 29"`), what it does to needs (`BFAIEvalData`, and
//!     `BFAICompletionData` when it finishes) and the behaviours to run
//!     (`BFBehExecTask`). Needs are levels where higher means more urgent;
//!     a task's score is how much need it would relieve.
//!   `<species>.beh`  named behaviour sets: lists of behaviours such as
//!     `BFBehAnimate`, weighted `BFBehRandomSet`, posture switches
//!     (`BFBehAnimSwitchSet`, `BFBehAnimateSwitch`) and `BFBehWander`.
//!
//! This module implements the subset that needs no other entity: tasks whose
//! target is the animal itself. Tasks that need a target (food, water,
//! another animal), scripts and tokens are skipped. Need growth rates are
//! our own tuning; the files do not state them.

const std = @import("std");
const xml = @import("xml.zig");

pub const need_names = [_][]const u8{ "rest", "exercise", "social", "stimulation", "hygiene", "hunger", "thirst", "reproduction" };
pub const n_needs = need_names.len;

fn needIndex(name: []const u8) ?usize {
    for (need_names, 0..) |n, i| if (std.ascii.eqlIgnoreCase(n, name)) return i;
    return null;
}

pub const Posture = enum { stand, sit, lie };

pub const Speed = enum { slow, medium, fast };

pub const Weighted = struct { name: []const u8, weight: f32 };
pub const PostureEntry = struct { key: []const u8, value: []const u8 };

pub const Beh = union(enum) {
    /// Play one animation to its end (or for `play_time` seconds if set).
    animate: struct { anim: []const u8, play_time: f32 },
    /// Choose an animation by current posture (`Stand`, `Sit`, `Lie`, `default`).
    animate_switch: []const PostureEntry,
    /// Run another set.
    play_set: []const u8,
    random_set: []const Weighted,
    /// Choose a set by current posture.
    anim_switch_set: []const PostureEntry,
    /// Choose a set by terrain: only `ground` is used.
    loco_switch_set: []const PostureEntry,
    /// Walk around for a while.
    wander: struct { min_time: f32, max_time: f32, speed: Speed },
    /// Play random animations a few times (`BFBehAnimateRandom`).
    animate_random: struct { anims: []const Weighted, min_plays: u32, max_plays: u32 },
    /// Understood but does nothing here (feedback, head look, tokens, ...).
    ignore,
    /// Needs something we do not model; a task containing this is skipped.
    unsupported,
};

pub const BehSet = struct { name: []const u8, behaviors: []const Beh };

pub const Cmp = enum { le, ge, eq, lt, gt };

pub const Qual = struct {
    kind: union(enum) {
        need: struct { index: usize, cmp: Cmp, value: f32 },
        /// A true/false condition on the animal's situation.
        flag: bool,
        /// A condition we cannot evaluate: the task is skipped.
        unknown,
    },
};

pub const Task = struct {
    name: []const u8,
    subjects: []const []const u8,
    quals: []const Qual,
    /// True when the task needs no other entity.
    self_target: bool,
    fixed_score: ?f32,
    /// Change to each need on completion (negative relieves it).
    completion: [n_needs]f32,
    /// What the evaluation says the task relieves.
    eval: [n_needs]f32,
    exec: []const Beh,
    followup: []const Beh,
    supported: bool,
};

pub const Library = struct {
    arena: std.heap.ArenaAllocator,
    sets: std.StringHashMapUnmanaged(*const BehSet) = .empty,
    tasks: std.ArrayList(Task) = .empty,

    pub fn init(gpa: std.mem.Allocator) Library {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Library) void {
        self.arena.deinit();
    }

    pub fn set(self: *const Library, name: []const u8) ?*const BehSet {
        var buf: [96]u8 = undefined;
        if (name.len > buf.len) return null;
        return self.sets.get(std.ascii.lowerString(&buf, name));
    }

    /// Adds the behaviour sets from a `.beh` file.
    pub fn addSets(self: *Library, data: []const u8) !void {
        const a = self.arena.allocator();
        const root = xml.parse(a, data, null) catch return error.BadAi;
        for (root.children) |s| {
            const beh = s.child("behaviors") orelse continue;
            var list: std.ArrayList(Beh) = .empty;
            for (beh.children) |b| try list.append(a, try parseBeh(a, b));
            const bs = try a.create(BehSet);
            bs.* = .{ .name = s.name, .behaviors = try list.toOwnedSlice(a) };
            const key = try std.ascii.allocLowerString(a, s.name);
            try self.sets.put(a, key, bs);
        }
    }

    /// Adds the task templates from a `.tsk` file.
    pub fn addTasks(self: *Library, data: []const u8) !void {
        const a = self.arena.allocator();
        const root = xml.parse(a, data, null) catch return error.BadAi;
        for (root.children) |t| {
            if (!std.ascii.eqlIgnoreCase(t.name, "BFAITaskTemplate")) continue;
            try self.tasks.append(a, try parseTask(a, t));
        }
    }
};

fn attrF(e: *const xml.Element, name: []const u8, default: f32) f32 {
    const v = e.attr(name) orelse return default;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch default;
}

fn weightedChildren(a: std.mem.Allocator, e: *const xml.Element) ![]const Weighted {
    var list: std.ArrayList(Weighted) = .empty;
    for (e.children) |c| try list.append(a, .{ .name = c.name, .weight = attrF(c, "weight", 1) });
    return list.toOwnedSlice(a);
}

fn tableChildren(a: std.mem.Allocator, e: *const xml.Element, value_attr: []const u8) ![]const PostureEntry {
    var list: std.ArrayList(PostureEntry) = .empty;
    for (e.children) |c| {
        const v = c.attr(value_attr) orelse continue;
        try list.append(a, .{ .key = c.name, .value = v });
    }
    return list.toOwnedSlice(a);
}

fn eq(name: []const u8, other: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, other);
}

fn parseSpeed(text: ?[]const u8) Speed {
    const t = text orelse return .medium;
    if (eq(t, "slow")) return .slow;
    if (eq(t, "fast")) return .fast;
    return .medium;
}

fn parseBeh(a: std.mem.Allocator, e: *const xml.Element) !Beh {
    const n = e.name;
    if (eq(n, "BFBehAnimate")) {
        return .{ .animate = .{ .anim = e.attr("targetAnim") orelse return .ignore, .play_time = attrF(e, "playTime", 0) } };
    } else if (eq(n, "BFBehAnimateSwitch")) {
        const t = e.child("animTable") orelse return .ignore;
        return .{ .animate_switch = try tableChildren(a, t, "anim") };
    } else if (eq(n, "BFBehPlaySet")) {
        return .{ .play_set = e.attr("behSet") orelse return .ignore };
    } else if (eq(n, "BFBehRandomSet")) {
        const t = e.child("randomSets") orelse return .ignore;
        return .{ .random_set = try weightedChildren(a, t) };
    } else if (eq(n, "BFBehAnimSwitchSet")) {
        const t = e.child("behaviorTable") orelse return .ignore;
        return .{ .anim_switch_set = try tableChildren(a, t, "behSet") };
    } else if (eq(n, "BFBehLocoSwitchSet")) {
        const t = e.child("behaviorTable") orelse return .ignore;
        return .{ .loco_switch_set = try tableChildren(a, t, "behSet") };
    } else if (eq(n, "BFBehWander")) {
        const play = attrF(e, "playTime", 10);
        return .{ .wander = .{
            .min_time = attrF(e, "minPlayTime", play),
            .max_time = attrF(e, "maxPlayTime", play),
            .speed = parseSpeed(e.attr("locoSpeed")),
        } };
    } else if (eq(n, "BFBehAnimateRandom")) {
        const t = e.child("randomAnims") orelse return .ignore;
        return .{ .animate_random = .{
            .anims = try weightedChildren(a, t),
            .min_plays = @intFromFloat(attrF(e, "minPlays", 1)),
            .max_plays = @intFromFloat(attrF(e, "maxPlays", 1)),
        } };
    }
    const ignorable = [_][]const u8{ "ZTBehFeedback", "ZTBehViewEvent", "BFBehHeadLook", "BFBehFaceTarget", "BFBehSendToken", "BFBehSetAttribute", "BFBehSendTrigger", "ZTBehMorph", "ZTBehEconomy" };
    for (ignorable) |i| if (eq(n, i)) return .ignore;
    return .unsupported;
}

fn parseCmp(text: []const u8) ?struct { cmp: Cmp, value: f32 } {
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    const op = it.next() orelse return null;
    const val_text = it.next() orelse return null;
    const v = std.fmt.parseFloat(f32, val_text) catch return null;
    const c: Cmp = if (eq(op, "LE")) .le else if (eq(op, "GE")) .ge else if (eq(op, "E")) .eq else if (eq(op, "LT")) .lt else if (eq(op, "GT")) .gt else return null;
    return .{ .cmp = c, .value = v };
}

/// Conditions about the animal's surroundings that hold for an animal
/// standing on land with nothing special going on.
fn flagValue(name: []const u8) ?bool {
    const flags = [_]struct { n: []const u8, v: bool }{
        .{ .n = "onLand", .v = true },
        .{ .n = "inWater", .v = false },
        .{ .n = "isSwimming", .v = false },
        .{ .n = "inWater_OR_onLand", .v = true },
        .{ .n = "b_Pregnant", .v = false },
    };
    for (flags) |f| if (eq(f.n, name)) return f.v;
    return null;
}

fn parseQuals(a: std.mem.Allocator, list: *std.ArrayList(Qual), e: *const xml.Element) !void {
    for (e.attributes) |at| {
        if (needIndex(at.name)) |idx| {
            if (parseCmp(at.value)) |c| {
                try list.append(a, .{ .kind = .{ .need = .{ .index = idx, .cmp = c.cmp, .value = c.value } } });
                continue;
            }
        }
        if (flagValue(at.name)) |actual| {
            const want = eq(at.value, "true");
            const is_false = eq(at.value, "false") or eq(at.value, "E false");
            if (want or is_false) {
                try list.append(a, .{ .kind = .{ .flag = if (want) actual else !actual } });
                continue;
            }
        }
        try list.append(a, .{ .kind = .unknown });
    }
}

fn parseMap(e: ?*const xml.Element) [n_needs]f32 {
    var out: [n_needs]f32 = @splat(0);
    const m = e orelse return out;
    for (m.attributes) |at| {
        if (needIndex(at.name)) |i| out[i] = std.fmt.parseFloat(f32, std.mem.trim(u8, at.value, " ")) catch 0;
    }
    return out;
}

fn parseExec(a: std.mem.Allocator, e: ?*const xml.Element, supported: *bool) ![]const Beh {
    const x = e orelse return &.{};
    var list: std.ArrayList(Beh) = .empty;
    for (x.children) |b| {
        const beh = try parseBeh(a, b);
        if (beh == .unsupported) supported.* = false;
        try list.append(a, beh);
    }
    return list.toOwnedSlice(a);
}

fn parseTask(a: std.mem.Allocator, t: *const xml.Element) !Task {
    var supported = true;
    var subjects: std.ArrayList([]const u8) = .empty;
    var quals: std.ArrayList(Qual) = .empty;
    var self_target = false;
    if (t.child("BFAICreateData")) |cd| {
        if (cd.child("Subjects")) |s| for (s.children) |c| {
            if (std.mem.startsWith(u8, c.name, "Qualifiers")) try parseQuals(a, &quals, c) else try subjects.append(a, c.name);
        };
        if (cd.child("Targets")) |tg| for (tg.children) |c| {
            if (eq(c.name, "self")) self_target = true;
        };
    }
    var fixed: ?f32 = null;
    var eval: [n_needs]f32 = @splat(0);
    if (t.child("BFAIEvalData")) |ev| {
        if (ev.attr("fixedScore")) |v| fixed = std.fmt.parseFloat(f32, std.mem.trim(u8, v, " ")) catch null;
        eval = parseMap(ev.child("BFAIAttributeFloatMap"));
    }
    var completion: [n_needs]f32 = @splat(0);
    var followup: []const Beh = &.{};
    if (t.child("BFAICompletionData")) |cd| {
        completion = parseMap(cd.child("BFAIAttributeFloatMap"));
        var ignore_support = true;
        followup = try parseExec(a, cd.child("BFBehExecTask"), &ignore_support);
    }
    const exec = try parseExec(a, t.child("BFBehExecTask"), &supported);
    return .{
        .name = t.attr("Name") orelse "",
        .subjects = try subjects.toOwnedSlice(a),
        .quals = try quals.toOwnedSlice(a),
        .self_target = self_target,
        .fixed_score = fixed,
        .completion = completion,
        .eval = eval,
        .exec = exec,
        .followup = followup,
        .supported = supported and self_target,
    };
}

// ------------------------------------------------------------------ brain

/// Answers questions about the animal's animations (they differ by model).
pub const Oracle = struct {
    ctx: *anyopaque,
    /// Length in seconds of an animation, or null if the model has none by that name.
    duration: *const fn (ctx: *anyopaque, anim: []const u8) ?f32,
};

pub fn postureOf(anim: []const u8) ?Posture {
    if (std.ascii.startsWithIgnoreCase(anim, "stand")) return .stand;
    if (std.ascii.startsWithIgnoreCase(anim, "sit")) return .sit;
    if (std.ascii.startsWithIgnoreCase(anim, "lie") or std.ascii.startsWithIgnoreCase(anim, "sleep")) return .lie;
    return null;
}

fn postureKey(p: Posture) []const u8 {
    return switch (p) {
        .stand => "Stand",
        .sit => "Sit",
        .lie => "Lie",
    };
}

const Item = union(enum) {
    beh: Beh,
    /// Wait out an animation already started.
    anim: struct { name: []const u8, remaining: f32 },
    wander: struct { remaining: f32, speed: Speed },
};

/// What the animal should be doing right now.
pub const Action = union(enum) {
    /// Play an animation (looping while there is nothing else to do).
    anim: []const u8,
    wander: Speed,
};

pub const Brain = struct {
    gpa: std.mem.Allocator,
    lib: *const Library,
    /// Names the animal answers to: its species and groups (`Lion`,
    /// `Lion_Adult`, `Lion_Adult_F`, ...).
    groups: []const []const u8,
    needs: [n_needs]f32,
    posture: Posture = .stand,
    queue: std.ArrayList(Item) = .empty,
    task: ?*const Task = null,
    /// Time since each task last ran, to avoid repeating one forever.
    last_run: std.ArrayList(f32) = .empty,
    clock: f32 = 0,
    action: Action = .{ .anim = "Stand_Idle" },
    /// Seconds into the current animation.
    anim_time: f32 = 0,
    rng: std.Random.DefaultPrng,

    pub fn init(gpa: std.mem.Allocator, lib: *const Library, groups: []const []const u8, seed: u64) !Brain {
        var b: Brain = .{ .gpa = gpa, .lib = lib, .groups = groups, .needs = undefined, .rng = .init(seed) };
        for (&b.needs) |*n| n.* = 15 + b.rng.random().float(f32) * 45;
        try b.last_run.appendNTimes(gpa, -1000, lib.tasks.items.len);
        return b;
    }

    pub fn deinit(self: *Brain) void {
        self.queue.deinit(self.gpa);
        self.last_run.deinit(self.gpa);
    }

    fn appliesTo(self: *const Brain, t: *const Task) bool {
        if (t.subjects.len == 0) return true;
        for (t.subjects) |s| {
            for (self.groups) |g| if (eq(s, g)) return true;
        }
        return false;
    }

    fn qualHolds(self: *const Brain, q: Qual) bool {
        switch (q.kind) {
            .flag => |v| return v,
            .unknown => return false,
            .need => |n| {
                const v = self.needs[n.index];
                return switch (n.cmp) {
                    .le => v <= n.value,
                    .ge => v >= n.value,
                    .lt => v < n.value,
                    .gt => v > n.value,
                    .eq => v == n.value,
                };
            },
        }
    }

    /// How much this task is worth doing now, or null if it cannot run.
    pub fn score(self: *const Brain, idx: usize) ?f32 {
        const t = &self.lib.tasks.items[idx];
        if (!t.supported or !self.appliesTo(t)) return null;
        for (t.quals) |q| if (!self.qualHolds(q)) return null;
        // Tasks with a large fixed score are triggered by events (birth,
        // puberty); they are not chosen by need.
        if (t.fixed_score) |f| return if (f < 10) f else null;
        var s: f32 = 0;
        for (t.eval, self.needs) |effect, need| {
            if (effect < 0) s += need * (-effect) / 100.0;
        }
        return if (s > 0) s else null;
    }

    pub fn update(self: *Brain, dt: f32, oracle: Oracle) void {
        self.clock += dt;
        self.anim_time += dt;
        // Needs grow while time passes.
        for (&self.needs) |*n| n.* = @min(100, n.* + 0.35 * dt);

        // Progress what is running.
        if (self.queue.items.len > 0) {
            const top = &self.queue.items[self.queue.items.len - 1];
            switch (top.*) {
                .anim => |*an| {
                    an.remaining -= dt;
                    if (an.remaining > 0) return;
                    if (postureOf(an.name)) |p| self.posture = p;
                    _ = self.queue.pop();
                },
                .wander => |*w| {
                    w.remaining -= dt;
                    if (w.remaining > 0) return;
                    self.posture = .stand;
                    _ = self.queue.pop();
                },
                .beh => {},
            }
        }
        // Start the next thing, expanding sets until something is visible.
        var guard: usize = 0;
        while (guard < 64) : (guard += 1) {
            if (self.queue.items.len == 0) {
                self.finishTask();
                if (!self.chooseTask()) {
                    self.idle(oracle);
                    return;
                }
            }
            const top = self.queue.items[self.queue.items.len - 1];
            switch (top) {
                .anim, .wander => return,
                .beh => |b| {
                    _ = self.queue.pop();
                    self.run(b, oracle);
                    if (self.queue.items.len > 0) switch (self.queue.items[self.queue.items.len - 1]) {
                        .anim, .wander => return,
                        .beh => {},
                    };
                },
            }
        }
    }

    fn finishTask(self: *Brain) void {
        const t = self.task orelse return;
        for (&self.needs, t.completion) |*n, d| n.* = std.math.clamp(n.* + d, 0, 100);
        self.task = null;
    }

    fn chooseTask(self: *Brain) bool {
        var best: ?usize = null;
        var best_score: f32 = 0;
        const rnd = self.rng.random();
        for (self.lib.tasks.items, 0..) |_, i| {
            const base = self.score(i) orelse continue;
            // Recently done tasks are less attractive; a little noise breaks ties.
            const since = self.clock - self.last_run.items[i];
            const fresh = std.math.clamp(since / 60.0, 0.1, 1.0);
            const s = base * fresh * (0.85 + rnd.float(f32) * 0.3);
            if (best == null or s > best_score) {
                best = i;
                best_score = s;
            }
        }
        const idx = best orelse return false;
        const t = &self.lib.tasks.items[idx];
        self.task = t;
        self.last_run.items[idx] = self.clock;
        self.pushList(t.followup); // runs last
        self.pushList(t.exec);
        return true;
    }

    /// Pushes behaviours so the first one runs first (the queue is a stack).
    fn pushList(self: *Brain, list: []const Beh) void {
        var i = list.len;
        while (i > 0) {
            i -= 1;
            self.queue.append(self.gpa, .{ .beh = list[i] }) catch return;
        }
    }

    fn pushBeh(self: *Brain, b: Beh) void {
        self.queue.append(self.gpa, .{ .beh = b }) catch {};
    }

    fn pushSet(self: *Brain, name: []const u8) void {
        if (self.lib.set(name)) |s| self.pushList(s.behaviors);
    }

    fn byPosture(self: *const Brain, table: []const PostureEntry) ?[]const u8 {
        const key = postureKey(self.posture);
        var fallback: ?[]const u8 = null;
        for (table) |e| {
            if (eq(e.key, key)) return e.value;
            if (eq(e.key, "default")) fallback = e.value;
        }
        return fallback;
    }

    /// Plays an animation, first moving to its posture if needed.
    fn startAnim(self: *Brain, name: []const u8, play_time: f32, oracle: Oracle) void {
        const len = oracle.duration(oracle.ctx, name) orelse return;
        const target = postureOf(name);
        if (target != null and target.? != self.posture) {
            // Queue the animation itself, then transitions in front of it.
            self.queue.append(self.gpa, .{ .anim = .{ .name = name, .remaining = if (play_time > 0) play_time else len } }) catch return;
            self.transition(self.posture, target.?, oracle);
        } else {
            self.queue.append(self.gpa, .{ .anim = .{ .name = name, .remaining = if (play_time > 0) play_time else len } }) catch return;
        }
        self.action = .{ .anim = name };
        self.anim_time = 0;
    }

    fn transition(self: *Brain, from: Posture, to: Posture, oracle: Oracle) void {
        var buf: [48]u8 = undefined;
        const direct = std.fmt.bufPrint(&buf, "{s}_2{s}", .{ postureKey(from), postureKey(to) }) catch return;
        if (oracle.duration(oracle.ctx, direct)) |len| {
            self.pushTransition(direct, len);
            return;
        }
        // No direct transition: go through standing.
        if (from != .stand and to != .stand) {
            self.transition(.stand, to, oracle);
            self.transition(from, .stand, oracle);
        }
    }

    fn pushTransition(self: *Brain, name: []const u8, len: f32) void {
        // `name` points into a stack buffer, so keep an owned copy alive in the library arena.
        const a = @constCast(self.lib).arena.allocator();
        const copy = a.dupe(u8, name) catch return;
        self.queue.append(self.gpa, .{ .anim = .{ .name = copy, .remaining = len } }) catch return;
    }

    fn run(self: *Brain, b: Beh, oracle: Oracle) void {
        switch (b) {
            .animate => |an| self.startAnim(an.anim, an.play_time, oracle),
            .animate_switch => |t| if (self.byPosture(t)) |n| self.startAnim(n, 0, oracle),
            .play_set => |n| self.pushSet(n),
            .anim_switch_set => |t| if (self.byPosture(t)) |n| self.pushSet(n),
            .loco_switch_set => |t| for (t) |e| if (eq(e.key, "ground")) self.pushSet(e.value),
            .random_set => |opts| if (self.pick(opts)) |n| self.pushSet(n),
            .animate_random => |ar| {
                if (self.pick(ar.anims)) |n| {
                    const span = ar.max_plays -| ar.min_plays;
                    const plays = ar.min_plays + (if (span > 0) self.rng.random().uintLessThan(u32, span + 1) else 0);
                    var i: u32 = 0;
                    while (i < @max(plays, 1)) : (i += 1) self.startAnim(n, 0, oracle);
                }
            },
            .wander => |w| {
                if (self.posture != .stand) self.transition(self.posture, .stand, oracle);
                const span = w.max_time - w.min_time;
                const t = w.min_time + (if (span > 0) self.rng.random().float(f32) * span else 0);
                // The walk is pushed first so any posture transition (now on
                // top of the stack) plays before it.
                const top_len = self.queue.items.len;
                _ = top_len;
                self.queue.append(self.gpa, .{ .wander = .{ .remaining = @max(t, 1), .speed = w.speed } }) catch return;
                self.fixWanderOrder();
                self.action = .{ .wander = w.speed };
            },
            .ignore, .unsupported => {},
        }
    }

    /// A wander item must run after any transition pushed just before it:
    /// the stack top runs first, so the wander goes beneath them.
    fn fixWanderOrder(self: *Brain) void {
        const items = self.queue.items;
        if (items.len < 2) return;
        var i = items.len - 1; // the wander
        while (i > 0 and items[i - 1] == .anim) : (i -= 1) {
            std.mem.swap(Item, &items[i], &items[i - 1]);
        }
    }

    fn pick(self: *Brain, opts: []const Weighted) ?[]const u8 {
        var total: f32 = 0;
        for (opts) |o| total += o.weight;
        if (total <= 0) return null;
        var r = self.rng.random().float(f32) * total;
        for (opts) |o| {
            r -= o.weight;
            if (r <= 0) return o.name;
        }
        return opts[opts.len - 1].name;
    }

    /// With nothing to do, hold the current posture.
    fn idle(self: *Brain, oracle: Oracle) void {
        const name: []const u8 = switch (self.posture) {
            .stand => "Stand_Idle",
            .sit => "Sit_Idle",
            .lie => "Lie_Idle",
        };
        if (oracle.duration(oracle.ctx, name) != null) {
            self.queue.append(self.gpa, .{ .anim = .{ .name = name, .remaining = 4.0 } }) catch return;
            self.action = .{ .anim = name };
        }
    }

    /// What to show right now: the animation or movement at the top of the stack.
    pub fn current(self: *Brain) Action {
        if (self.queue.items.len > 0) switch (self.queue.items[self.queue.items.len - 1]) {
            .anim => |a| return .{ .anim = a.name },
            .wander => |w| return .{ .wander = w.speed },
            .beh => {},
        };
        return self.action;
    }
};

const testing = std.testing;

const test_beh =
    \\<BehaviorSets>
    \\ <Sleep><subjects><Lion/></subjects><behaviors>
    \\   <BFBehRandomSet><randomSets><SleepSide weight="50"/><SleepPaws weight="50"/></randomSets></BFBehRandomSet>
    \\ </behaviors></Sleep>
    \\ <SleepSide><behaviors><ZTBehFeedback/><BFBehAnimate targetAnim="Sleep_Idle"/></behaviors></SleepSide>
    \\ <SleepPaws><behaviors><BFBehAnimate targetAnim="SleepPaws_Idle"/></behaviors></SleepPaws>
    \\ <Yawn><behaviors><BFBehAnimSwitchSet><behaviorTable><Stand behSet="Stand_Yawn"/><Lie behSet="Lie_Yawn"/><default behSet="Stand_Yawn"/></behaviorTable></BFBehAnimSwitchSet></behaviors></Yawn>
    \\ <Stand_Yawn><behaviors><BFBehAnimate targetAnim="Stand_Yawn"/></behaviors></Stand_Yawn>
    \\ <Lie_Yawn><behaviors><BFBehAnimate targetAnim="Lie_Yawn"/></behaviors></Lie_Yawn>
    \\ <Walk><behaviors><BFBehWander minPlayTime="5" maxPlayTime="5" locoSpeed="slow"/></behaviors></Walk>
    \\</BehaviorSets>
;

const test_tsk =
    \\<BFAITaskTemplateList>
    \\ <BFAITaskTemplate Name="Sleep"><BFAICreateData><Subjects><Lion/><Qualifiers_AND onLand="true" isSwimming="false"/></Subjects><Targets><self/></Targets></BFAICreateData>
    \\   <BFAIEvalData><BFAIAttributeFloatMap rest="-35"/></BFAIEvalData>
    \\   <BFBehExecTask><BFBehPlaySet behSet="Sleep"/></BFBehExecTask>
    \\   <BFAICompletionData><BFAIAttributeFloatMap rest="-100"/></BFAICompletionData></BFAITaskTemplate>
    \\ <BFAITaskTemplate Name="SlowWander"><BFAICreateData><Subjects><Lion/><Qualifiers_AND rest="GE 70"/></Subjects><Targets><self/></Targets></BFAICreateData>
    \\   <BFAIEvalData><BFAIAttributeFloatMap exercise="-30"/></BFAIEvalData>
    \\   <BFBehExecTask><BFBehPlaySet behSet="Walk"/></BFBehExecTask>
    \\   <BFAICompletionData><BFAIAttributeFloatMap exercise="-100"/></BFAICompletionData></BFAITaskTemplate>
    \\ <BFAITaskTemplate Name="Hunt"><BFAICreateData><Subjects><Lion/></Subjects><Targets><Gazelle/></Targets></BFAICreateData>
    \\   <BFAIEvalData fixedScore="5"/><BFBehExecTask><BFBehPursuit/></BFBehExecTask></BFAITaskTemplate>
    \\ <BFAITaskTemplate Name="TigerOnly"><BFAICreateData><Subjects><Tiger/></Subjects><Targets><self/></Targets></BFAICreateData>
    \\   <BFAIEvalData fixedScore="5"/><BFBehExecTask><BFBehPlaySet behSet="Sleep"/></BFBehExecTask></BFAITaskTemplate>
    \\ <BFAITaskTemplate Name="Yawn"><BFAICreateData><Subjects><Lion/></Subjects><Targets><self/></Targets></BFAICreateData>
    \\   <BFAIEvalData><BFAIAttributeFloatMap social="-1"/></BFAIEvalData>
    \\   <BFBehExecTask><BFBehPlaySet behSet="Yawn"/></BFBehExecTask></BFAITaskTemplate>
    \\</BFAITaskTemplateList>
;

const TestOracle = struct {
    names: []const []const u8,
    fn duration(ctx: *anyopaque, name: []const u8) ?f32 {
        const self: *TestOracle = @ptrCast(@alignCast(ctx));
        for (self.names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return 2.0;
        return null;
    }
};

test "library parses sets and tasks, skipping what needs other entities" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    try lib.addSets(test_beh);
    try lib.addTasks(test_tsk);
    try testing.expect(lib.set("sleep") != null);
    try testing.expect(lib.set("SleepSide") != null);
    try testing.expectEqual(@as(usize, 5), lib.tasks.items.len);
    try testing.expect(lib.tasks.items[0].supported);
    try testing.expect(!lib.tasks.items[2].supported); // pursuit of another animal
    try testing.expectEqual(@as(f32, -35), lib.tasks.items[0].eval[0]);
}

test "task selection follows needs, species and qualifiers" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    try lib.addSets(test_beh);
    try lib.addTasks(test_tsk);
    var brain = try Brain.init(testing.allocator, &lib, &.{ "Lion", "Lion_Adult_F" }, 1);
    defer brain.deinit();
    brain.needs = @splat(0);
    // not tired: sleeping and slow wandering do not apply
    try testing.expectEqual(@as(?f32, null), brain.score(0));
    try testing.expectEqual(@as(?f32, null), brain.score(1));
    brain.needs[0] = 80; // tired
    try testing.expectApproxEqAbs(@as(f32, 28.0), brain.score(0).?, 1e-4); // 80 * 35 / 100
    try testing.expect(brain.score(1) == null); // exercise need is 0
    brain.needs[1] = 50;
    try testing.expectApproxEqAbs(@as(f32, 15.0), brain.score(1).?, 1e-4);
    // another species' task and an unsupported one are never eligible
    try testing.expect(brain.score(2) == null);
    try testing.expect(brain.score(3) == null);
}

test "a tired animal sleeps, and sleeping relieves the need" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    try lib.addSets(test_beh);
    try lib.addTasks(test_tsk);
    var names = TestOracle{ .names = &.{ "Sleep_Idle", "SleepPaws_Idle", "Stand_Idle", "Lie_Idle", "Stand_2Lie", "Lie_2Stand", "Stand_Yawn", "Lie_Yawn" } };
    const oracle: Oracle = .{ .ctx = &names, .duration = TestOracle.duration };
    var brain = try Brain.init(testing.allocator, &lib, &.{ "Lion", "Lion_Adult_F" }, 3);
    defer brain.deinit();
    brain.needs = @splat(0);
    brain.needs[0] = 95;
    var saw_transition = false;
    var saw_sleep = false;
    for (0..400) |_| {
        brain.update(0.1, oracle);
        switch (brain.current()) {
            .anim => |a| {
                if (std.mem.eql(u8, a, "Stand_2Lie")) saw_transition = true;
                if (std.mem.startsWith(u8, a, "Sleep")) saw_sleep = true;
            },
            .wander => {},
        }
        if (saw_sleep) break;
    }
    // it had to lie down first, then sleep
    try testing.expect(saw_transition);
    try testing.expect(saw_sleep);
    // after the task finishes, rest is relieved
    for (0..400) |_| brain.update(0.1, oracle);
    try testing.expect(brain.needs[0] < 60);
}

test "posture switch sets pick by posture" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    try lib.addSets(test_beh);
    try lib.addTasks(test_tsk);
    var names = TestOracle{ .names = &.{ "Stand_Yawn", "Lie_Yawn", "Stand_Idle", "Lie_Idle", "Lie_2Stand", "Stand_2Lie" } };
    const oracle: Oracle = .{ .ctx = &names, .duration = TestOracle.duration };
    var brain = try Brain.init(testing.allocator, &lib, &.{"Lion"}, 5);
    defer brain.deinit();
    brain.posture = .lie;
    brain.pushSet("Yawn");
    var yawned_lying = false;
    for (0..100) |_| {
        brain.update(0.1, oracle);
        switch (brain.current()) {
            .anim => |a| if (std.mem.eql(u8, a, "Lie_Yawn")) {
                yawned_lying = true;
            },
            .wander => {},
        }
    }
    try testing.expect(yawned_lying);
}

test "wander becomes a movement action" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    try lib.addSets(test_beh);
    // Only the slow-wander task, so nothing else competes for the animal.
    try lib.addTasks(
        \\<BFAITaskTemplateList>
        \\ <BFAITaskTemplate Name="SlowWander"><BFAICreateData><Subjects><Lion/><Qualifiers_AND rest="GE 70"/></Subjects><Targets><self/></Targets></BFAICreateData>
        \\   <BFAIEvalData><BFAIAttributeFloatMap exercise="-30"/></BFAIEvalData>
        \\   <BFBehExecTask><BFBehPlaySet behSet="Walk"/></BFBehExecTask>
        \\   <BFAICompletionData><BFAIAttributeFloatMap exercise="-100"/></BFAICompletionData></BFAITaskTemplate>
        \\</BFAITaskTemplateList>
    );
    var names = TestOracle{ .names = &.{ "Stand_Idle", "Lie_Idle", "Lie_2Stand", "Stand_2Lie" } };
    const oracle: Oracle = .{ .ctx = &names, .duration = TestOracle.duration };
    var brain = try Brain.init(testing.allocator, &lib, &.{"Lion"}, 9);
    defer brain.deinit();
    brain.needs = @splat(0);
    brain.needs[0] = 90; // tired enough for slow wandering (rest GE 70)...
    brain.needs[1] = 90; // ...and in need of exercise
    var wandered = false;
    for (0..300) |_| {
        brain.update(0.1, oracle);
        switch (brain.current()) {
            .wander => |s| {
                try testing.expectEqual(Speed.slow, s);
                wandered = true;
            },
            .anim => {},
        }
    }
    try testing.expect(wandered);
}
