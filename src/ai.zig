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
    /// Dock with the task's target (the walk there is added by the brain).
    enter,
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
    /// Entity flags (`b_Granivore`) the subject must all have, or any of.
    flags_and: []const []const u8 = &.{},
    flags_or: []const []const u8 = &.{},
    /// The kind of object the task works on (`BrowseHolder_Hay`), when it is
    /// not the animal itself.
    target: ?[]const u8 = null,
    /// The target must hold food (`f_FoodLevel`).
    needs_food: bool = false,
    /// How much the target's food level drops when the task completes.
    target_use: f32 = 0,
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
    if (eq(n, "BFBehEnter")) return .enter;
    const ignorable = [_][]const u8{ "BFBehAttachObject", "BFBehDetachObject", "BFBehExit", "ZTBehFeedback", "ZTBehViewEvent", "BFBehHeadLook", "BFBehFaceTarget", "BFBehSendToken", "BFBehSetAttribute", "BFBehSendTrigger", "ZTBehMorph", "ZTBehEconomy" };
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

fn startsWithFlag(name: []const u8) bool {
    return name.len > 2 and name[0] == 'b' and name[1] == '_';
}

fn parseTask(a: std.mem.Allocator, t: *const xml.Element) !Task {
    var supported = true;
    var subjects: std.ArrayList([]const u8) = .empty;
    var quals: std.ArrayList(Qual) = .empty;
    var flags_and: std.ArrayList([]const u8) = .empty;
    var flags_or: std.ArrayList([]const u8) = .empty;
    var self_target = false;
    var target: ?[]const u8 = null;
    var needs_food = false;
    if (t.child("BFAICreateData")) |cd| {
        for (cd.children) |sect| {
            const is_subjects = eq(sect.name, "Subjects") or eq(sect.name, "Subjects_AND") or eq(sect.name, "Subjects_OR");
            if (!is_subjects) continue;
            const or_flags = eq(sect.name, "Subjects_OR");
            for (sect.children) |c| {
                if (std.mem.startsWith(u8, c.name, "Qualifiers")) {
                    try parseQuals(a, &quals, c);
                } else if (startsWithFlag(c.name)) {
                    try (if (or_flags) flags_or else flags_and).append(a, c.name);
                } else try subjects.append(a, c.name);
            }
        }
        if (cd.child("Targets")) |tg| for (tg.children) |c| {
            if (std.mem.startsWith(u8, c.name, "Qualifiers")) {
                if (c.attr("f_FoodLevel") != null) needs_food = true;
                continue;
            }
            if (eq(c.name, "self")) {
                self_target = true;
            } else if (target == null) target = c.name;
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
    var target_use: f32 = 0;
    if (t.child("BFAICompletionData")) |cd| {
        completion = parseMap(cd.child("BFAIAttributeFloatMap"));
        if (cd.child("BFAITargetData")) |td| target_use = -attrF(td, "f_FoodLevel", 0);
        var ignore_support = true;
        followup = try parseExec(a, cd.child("BFBehExecTask"), &ignore_support);
    }
    const exec = try parseExec(a, t.child("BFBehExecTask"), &supported);
    // Tokens come from other animals; only the animal itself or a food-like
    // object (named in the data, found by the world) can be a target.
    const needs_object = target != null and !eq(target.?, "fromToken");
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
        .supported = supported and (self_target or needs_object),
        .flags_and = try flags_and.toOwnedSlice(a),
        .flags_or = try flags_or.toOwnedSlice(a),
        .target = if (self_target) null else target,
        .needs_food = needs_food,
        .target_use = target_use,
    };
}

// ------------------------------------------------------------------ brain

/// Something the animal can walk to and use (a feeder).
pub const Target = struct {
    id: u32,
    pos: [2]f32,
    /// The kind of container (`BrowseHolder`, `FoodDish`, `Trough`...), which
    /// selects the behaviour set the animal plays there.
    kind: []const u8 = "",
};

/// Answers questions about the animal and its surroundings. Animations
/// differ by model, flags come from the entity definition, and targets live
/// in the world.
pub const Oracle = struct {
    ctx: *anyopaque,
    /// Length in seconds of an animation, or null if the model has none by that name.
    duration: *const fn (ctx: *anyopaque, anim: []const u8) ?f32,
    /// Whether the animal has an entity flag such as `b_Granivore`.
    flag: *const fn (ctx: *anyopaque, name: []const u8) bool = noFlag,
    /// The nearest usable object of a kind, if any.
    find_target: *const fn (ctx: *anyopaque, class: []const u8) ?Target = noTarget,
    /// Takes `amount` of food from a target.
    use_target: *const fn (ctx: *anyopaque, id: u32, amount: f32) void = noUse,
};

fn noFlag(_: *anyopaque, _: []const u8) bool {
    return false;
}
fn noTarget(_: *anyopaque, _: []const u8) ?Target {
    return null;
}
fn noUse(_: *anyopaque, _: u32, _: f32) void {}

/// The name of the pose an animation belongs to: its prefix (`Stand_Idle` ->
/// `Stand`, `EatTrough_Idle` -> `EatTrough`); sleeping counts as lying.
pub fn poseOf(anim: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, anim, '_') orelse anim.len;
    const prefix = anim[0..end];
    if (std.ascii.startsWithIgnoreCase(prefix, "sleep")) return "Lie";
    return prefix;
}

fn isBasicPose(p: []const u8) bool {
    return eq(p, "Stand") or eq(p, "Sit") or eq(p, "Lie");
}

const Item = union(enum) {
    beh: Beh,
    /// Wait out an animation already started.
    anim: struct { name: []const u8, remaining: f32 },
    wander: struct { remaining: f32, speed: Speed },
    /// Walk to a point; the simulation calls `reached` on arrival.
    goto: [2]f32,
};

/// What the animal should be doing right now.
pub const Action = union(enum) {
    /// Play an animation (looping while there is nothing else to do).
    anim: []const u8,
    wander: Speed,
    goto: [2]f32,
};

pub const Brain = struct {
    gpa: std.mem.Allocator,
    lib: *const Library,
    /// Names the animal answers to: its species and groups (`Lion`,
    /// `Lion_Adult`, `Lion_Adult_F`, ...).
    groups: []const []const u8,
    needs: [n_needs]f32,
    /// The pose the animal is in: `Stand`, `Sit`, `Lie`, or one of its own
    /// (`Eat`, `Drink`...) learned from animation names.
    pose: []const u8 = "Stand",
    queue: std.ArrayList(Item) = .empty,
    task: ?usize = null,
    /// The object the current task works on.
    target: ?Target = null,
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

    fn appliesTo(self: *const Brain, t: *const Task, oracle: Oracle) bool {
        if (t.subjects.len > 0) {
            var ok = false;
            for (t.subjects) |s| {
                for (self.groups) |g| if (eq(s, g)) {
                    ok = true;
                };
            }
            if (!ok) return false;
        }
        for (t.flags_and) |f| if (!oracle.flag(oracle.ctx, f)) return false;
        if (t.flags_or.len > 0) {
            var any = false;
            for (t.flags_or) |f| if (oracle.flag(oracle.ctx, f)) {
                any = true;
            };
            if (!any) return false;
        }
        return true;
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
    pub fn score(self: *const Brain, idx: usize, oracle: Oracle) ?f32 {
        const t = &self.lib.tasks.items[idx];
        if (!t.supported or !self.appliesTo(t, oracle)) return null;
        for (t.quals) |q| if (!self.qualHolds(q)) return null;
        // Tasks with a large fixed score are triggered by events (birth,
        // puberty); they are not chosen by need.
        if (t.fixed_score) |f| {
            if (f >= 10) return null;
            if (t.target != null and oracle.find_target(oracle.ctx, t.target.?) == null) return null;
            return f;
        }
        var s: f32 = 0;
        for (t.eval, self.needs) |effect, need| {
            if (effect < 0) s += need * (-effect) / 100.0;
        }
        if (s <= 0) return null;
        // A task on an object needs one to exist.
        if (t.target) |name| if (oracle.find_target(oracle.ctx, name) == null) return null;
        return s;
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
                    self.pose = poseOf(an.name);
                    _ = self.queue.pop();
                },
                .wander => |*w| {
                    w.remaining -= dt;
                    if (w.remaining > 0) return;
                    self.pose = "Stand";
                    _ = self.queue.pop();
                },
                .goto => return,
                .beh => {},
            }
        }
        // Start the next thing, expanding sets until something is visible.
        var guard: usize = 0;
        while (guard < 64) : (guard += 1) {
            if (self.queue.items.len == 0) {
                self.finishTask(oracle);
                if (!self.chooseTask(oracle)) {
                    self.idle(oracle);
                    return;
                }
            }
            const top = self.queue.items[self.queue.items.len - 1];
            switch (top) {
                .anim, .wander, .goto => return,
                .beh => |b| {
                    _ = self.queue.pop();
                    self.run(b, oracle);
                    if (self.queue.items.len > 0) switch (self.queue.items[self.queue.items.len - 1]) {
                        .anim, .wander, .goto => return,
                        .beh => {},
                    };
                },
            }
        }
    }

    /// The simulation calls this when the animal has walked to the target.
    pub fn reached(self: *Brain) void {
        if (self.queue.items.len > 0 and self.queue.items[self.queue.items.len - 1] == .goto) {
            _ = self.queue.pop();
            self.pose = "Stand";
        }
    }

    /// Gives up on the current task (the way was blocked): no rewards.
    pub fn abort(self: *Brain) void {
        self.queue.clearRetainingCapacity();
        self.task = null;
        self.target = null;
    }

    fn finishTask(self: *Brain, oracle: Oracle) void {
        const ti = self.task orelse return;
        const t = &self.lib.tasks.items[ti];
        for (&self.needs, t.completion) |*n, d| n.* = std.math.clamp(n.* + d, 0, 100);
        if (self.target) |tg| oracle.use_target(oracle.ctx, tg.id, t.target_use);
        self.task = null;
        self.target = null;
    }

    fn chooseTask(self: *Brain, oracle: Oracle) bool {
        while (self.last_run.items.len < self.lib.tasks.items.len) self.last_run.append(self.gpa, -1000) catch return false;
        var best: ?usize = null;
        var best_score: f32 = 0;
        const rnd = self.rng.random();
        for (self.lib.tasks.items, 0..) |_, i| {
            const base = self.score(i, oracle) orelse continue;
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
        self.task = idx;
        self.last_run.items[idx] = self.clock;
        self.pushList(t.followup); // runs last
        self.pushList(t.exec);
        if (t.target) |name| {
            if (oracle.find_target(oracle.ctx, name)) |tg| {
                self.target = tg;
                // Walk there first (top of the stack).
                self.queue.append(self.gpa, .{ .goto = tg.pos }) catch {};
            } else {
                self.abort();
                return false;
            }
        }
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

    /// Plays a named set. `useContainer` means "whatever this species does
    /// at this kind of container", looked up as `Use<Kind>`, `Drink<Kind>`,
    /// `Eat`, `Drink`.
    fn pushSet(self: *Brain, name: []const u8) void {
        if (eq(name, "useContainer")) {
            const kind = if (self.target) |t| t.kind else "";
            var buf: [96]u8 = undefined;
            if (kind.len > 0) {
                const specific = std.fmt.bufPrint(&buf, "Use{s}", .{kind}) catch "";
                if (specific.len > 0) if (self.lib.set(specific)) |s| return self.pushList(s.behaviors);
            }
            // Shelters share one generic set (`UseShelter`), rocks another.
            const generic = [_][2][]const u8{ .{ "_Shelter", "UseShelter" }, .{ "Rock", "UseRock" } };
            for (generic) |g| if (std.mem.indexOf(u8, kind, g[0]) != null) {
                if (self.lib.set(g[1])) |s| return self.pushList(s.behaviors);
            };
            const candidates = [_][]const u8{ "Drink", "Eat" };
            for (candidates) |prefix| {
                if (kind.len == 0 and prefix.len == 5) continue;
                const n = if (std.mem.eql(u8, prefix, "Eat"))
                    "Eat"
                else
                    std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, kind }) catch continue;
                if (self.lib.set(n)) |s| return self.pushList(s.behaviors);
            }
            if (self.lib.set("Drink")) |s| return self.pushList(s.behaviors);
            return;
        }
        if (self.lib.set(name)) |s| self.pushList(s.behaviors);
    }

    fn byPosture(self: *const Brain, table: []const PostureEntry) ?[]const u8 {
        const key = if (isBasicPose(self.pose)) self.pose else "Stand";
        var fallback: ?[]const u8 = null;
        for (table) |e| {
            if (eq(e.key, key)) return e.value;
            if (eq(e.key, "default")) fallback = e.value;
        }
        return fallback;
    }

    /// True if `p` is a pose the animal can be in: the basic three, or one
    /// its model has a transition to from standing.
    fn isPose(self: *const Brain, p: []const u8, oracle: Oracle) bool {
        _ = self;
        if (isBasicPose(p)) return true;
        var buf: [64]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "Stand_2{s}", .{p}) catch return false;
        return oracle.duration(oracle.ctx, t) != null;
    }

    /// Plays an animation, first moving to its pose if needed.
    fn startAnim(self: *Brain, name: []const u8, play_time: f32, oracle: Oracle) void {
        const len = oracle.duration(oracle.ctx, name) orelse return;
        const target_pose = poseOf(name);
        // Queue the animation itself, then any transitions in front of it.
        self.queue.append(self.gpa, .{ .anim = .{ .name = name, .remaining = if (play_time > 0) play_time else len } }) catch return;
        if (!eq(target_pose, self.pose) and self.isPose(target_pose, oracle)) self.transition(self.pose, target_pose, oracle);
        self.action = .{ .anim = name };
        self.anim_time = 0;
    }

    fn transition(self: *Brain, from: []const u8, to: []const u8, oracle: Oracle) void {
        var buf: [96]u8 = undefined;
        const direct = std.fmt.bufPrint(&buf, "{s}_2{s}", .{ from, to }) catch return;
        if (oracle.duration(oracle.ctx, direct)) |len| {
            self.pushTransition(direct, len);
            return;
        }
        // No direct transition: go through standing.
        if (!eq(from, "Stand") and !eq(to, "Stand")) {
            self.transition("Stand", to, oracle);
            self.transition(from, "Stand", oracle);
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
                // The walk goes beneath any posture transition pushed for it.
                self.queue.append(self.gpa, .{ .wander = .{ .remaining = @max(w.min_time + (if (w.max_time > w.min_time) self.rng.random().float(f32) * (w.max_time - w.min_time) else 0), 1), .speed = w.speed } }) catch return;
                if (!eq(self.pose, "Stand")) self.transition(self.pose, "Stand", oracle);
                self.action = .{ .wander = w.speed };
            },
            .enter, .ignore, .unsupported => {},
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

    /// With nothing to do, hold the current pose.
    fn idle(self: *Brain, oracle: Oracle) void {
        var buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "{s}_Idle", .{self.pose}) catch "Stand_Idle";
        const use: []const u8 = if (oracle.duration(oracle.ctx, name) != null) blk: {
            // keep a stable copy of the name
            const a = @constCast(self.lib).arena.allocator();
            break :blk a.dupe(u8, name) catch return;
        } else if (oracle.duration(oracle.ctx, "Stand_Idle") != null) "Stand_Idle" else return;
        self.queue.append(self.gpa, .{ .anim = .{ .name = use, .remaining = 4.0 } }) catch return;
        self.action = .{ .anim = use };
    }

    /// What to show right now: the animation or movement at the top of the stack.
    pub fn current(self: *Brain) Action {
        if (self.queue.items.len > 0) switch (self.queue.items[self.queue.items.len - 1]) {
            .anim => |a| return .{ .anim = a.name },
            .wander => |w| return .{ .wander = w.speed },
            .goto => |p| return .{ .goto = p },
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
    \\ <UseFoodDish><behaviors><BFBehAnimate targetAnim="Eat_Idle"/></behaviors></UseFoodDish>
    \\ <Eat><behaviors><BFBehAnimate targetAnim="Stand_Idle"/></behaviors></Eat>
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
    flags: []const []const u8 = &.{},
    target: ?Target = null,
    used: f32 = 0,
    used_id: u32 = 0,

    fn duration(ctx: *anyopaque, name: []const u8) ?f32 {
        const self: *TestOracle = @ptrCast(@alignCast(ctx));
        for (self.names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return 2.0;
        return null;
    }
    fn flag(ctx: *anyopaque, name: []const u8) bool {
        const self: *TestOracle = @ptrCast(@alignCast(ctx));
        for (self.flags) |f| if (std.ascii.eqlIgnoreCase(f, name)) return true;
        return false;
    }
    fn findTarget(ctx: *anyopaque, class: []const u8) ?Target {
        const self: *TestOracle = @ptrCast(@alignCast(ctx));
        const t = self.target orelse return null;
        return if (std.ascii.eqlIgnoreCase(class, "FoodDish_Hay") or std.ascii.eqlIgnoreCase(class, "SmallRockCave_Shelter")) t else null;
    }
    fn useTarget(ctx: *anyopaque, id: u32, amount: f32) void {
        const self: *TestOracle = @ptrCast(@alignCast(ctx));
        self.used += amount;
        self.used_id = id;
    }
    fn oracle(self: *TestOracle) Oracle {
        return .{ .ctx = self, .duration = duration, .flag = flag, .find_target = findTarget, .use_target = useTarget };
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
    try testing.expect(!lib.tasks.items[2].supported); // pursuit needs a behaviour we lack
    try testing.expectEqual(@as(f32, -35), lib.tasks.items[0].eval[0]);
}

test "task selection follows needs, species and qualifiers" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    try lib.addSets(test_beh);
    try lib.addTasks(test_tsk);
    var to = TestOracle{ .names = &.{} };
    const oracle = to.oracle();
    var brain = try Brain.init(testing.allocator, &lib, &.{ "Lion", "Lion_Adult_F" }, 1);
    defer brain.deinit();
    brain.needs = @splat(0);
    try testing.expectEqual(@as(?f32, null), brain.score(0, oracle));
    try testing.expectEqual(@as(?f32, null), brain.score(1, oracle));
    brain.needs[0] = 80; // tired
    try testing.expectApproxEqAbs(@as(f32, 28.0), brain.score(0, oracle).?, 1e-4); // 80 * 35 / 100
    try testing.expect(brain.score(1, oracle) == null); // exercise need is 0
    brain.needs[1] = 50;
    try testing.expectApproxEqAbs(@as(f32, 15.0), brain.score(1, oracle).?, 1e-4);
    try testing.expect(brain.score(2, oracle) == null);
    try testing.expect(brain.score(3, oracle) == null);
}

test "a tired animal sleeps, and sleeping relieves the need" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    try lib.addSets(test_beh);
    try lib.addTasks(test_tsk);
    var to = TestOracle{ .names = &.{ "Sleep_Idle", "SleepPaws_Idle", "Stand_Idle", "Lie_Idle", "Stand_2Lie", "Lie_2Stand", "Stand_Yawn", "Lie_Yawn" } };
    const oracle = to.oracle();
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
            else => {},
        }
        if (saw_sleep) break;
    }
    try testing.expect(saw_transition);
    try testing.expect(saw_sleep);
    for (0..400) |_| brain.update(0.1, oracle);
    try testing.expect(brain.needs[0] < 60);
}

test "posture switch sets pick by pose" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    try lib.addSets(test_beh);
    try lib.addTasks(test_tsk);
    var to = TestOracle{ .names = &.{ "Stand_Yawn", "Lie_Yawn", "Stand_Idle", "Lie_Idle", "Lie_2Stand", "Stand_2Lie" } };
    const oracle = to.oracle();
    var brain = try Brain.init(testing.allocator, &lib, &.{"Lion"}, 5);
    defer brain.deinit();
    brain.pose = "Lie";
    brain.pushSet("Yawn");
    var yawned_lying = false;
    for (0..100) |_| {
        brain.update(0.1, oracle);
        switch (brain.current()) {
            .anim => |a| if (std.mem.eql(u8, a, "Lie_Yawn")) {
                yawned_lying = true;
            },
            else => {},
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
    var to = TestOracle{ .names = &.{ "Stand_Idle", "Lie_Idle", "Lie_2Stand", "Stand_2Lie" } };
    const oracle = to.oracle();
    var brain = try Brain.init(testing.allocator, &lib, &.{"Lion"}, 9);
    defer brain.deinit();
    brain.needs = @splat(0);
    brain.needs[0] = 90;
    brain.needs[1] = 90;
    var wandered = false;
    for (0..300) |_| {
        brain.update(0.1, oracle);
        switch (brain.current()) {
            .wander => |s| {
                try testing.expectEqual(Speed.slow, s);
                wandered = true;
            },
            else => {},
        }
    }
    try testing.expect(wandered);
}

const feed_tsk =
    \\<BFAITaskTemplateList>
    \\ <BFAITaskTemplate Name="Eat" reserveTag="Eat"><BFAICreateData>
    \\   <Subjects_AND><b_Granivore/><b_LargeAnimal/><Qualifiers inWater_OR_onLand="true"/></Subjects_AND>
    \\   <Targets><FoodDish_Hay/><Qualifiers_AND f_FoodLevel="GE 1" inHabitat="true"/></Targets></BFAICreateData>
    \\   <BFAIEvalData><BFAIAttributeFloatMap hunger="-40"/></BFAIEvalData>
    \\   <BFBehExecTask><BFBehEnter/><BFBehPlaySet behSet="useContainer"/></BFBehExecTask>
    \\   <BFAICompletionData><BFAIAttributeFloatMap hunger="-100"/><BFAITargetData f_FoodLevel="-20"/></BFAICompletionData></BFAITaskTemplate>
    \\</BFAITaskTemplateList>
;

test "feeding tasks parse their flags and target" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    try lib.addTasks(feed_tsk);
    const t = lib.tasks.items[0];
    try testing.expect(t.supported);
    try testing.expectEqualStrings("FoodDish_Hay", t.target.?);
    try testing.expect(t.needs_food);
    try testing.expectEqual(@as(usize, 2), t.flags_and.len);
    try testing.expectEqual(@as(f32, 20), t.target_use);
}

test "a hungry animal with the right flags walks to a feeder, eats and uses up food" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    try lib.addSets(test_beh);
    try lib.addTasks(feed_tsk);
    const target = Target{ .id = 77, .pos = .{ 10, 20 }, .kind = "FoodDish" };
    var to = TestOracle{
        .names = &.{ "Stand_Idle", "Eat_Idle", "Stand_2Eat", "Eat_2Stand" },
        .flags = &.{ "b_Granivore", "b_LargeAnimal" },
        .target = target,
    };
    const oracle = to.oracle();
    var brain = try Brain.init(testing.allocator, &lib, &.{"Zebra"}, 2);
    defer brain.deinit();
    brain.needs = @splat(0);
    brain.needs[5] = 90; // hunger
    // first it heads for the feeder
    brain.update(0.1, oracle);
    switch (brain.current()) {
        .goto => |p| {
            try testing.expectEqual(@as(f32, 10), p[0]);
            try testing.expectEqual(@as(f32, 20), p[1]);
        },
        else => return error.TestUnexpectedResult,
    }
    // it stays on its way until the simulation says it arrived
    brain.update(1.0, oracle);
    try testing.expect(brain.current() == .goto);
    brain.reached();
    var saw_transition = false;
    var saw_eating = false;
    for (0..80) |_| {
        brain.update(0.1, oracle);
        switch (brain.current()) {
            .anim => |a| {
                if (std.mem.eql(u8, a, "Stand_2Eat")) saw_transition = true;
                if (std.mem.eql(u8, a, "Eat_Idle")) saw_eating = true;
            },
            else => {},
        }
    }
    try testing.expect(saw_transition);
    try testing.expect(saw_eating);
    // the meal took 20 off the feeder and relieved the hunger
    try testing.expectEqual(@as(u32, 77), to.used_id);
    try testing.expectApproxEqAbs(@as(f32, 20), to.used, 1e-4);
    try testing.expect(brain.needs[5] < 30);
}

test "wrong diet or no feeder means no feeding task" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    try lib.addSets(test_beh);
    try lib.addTasks(feed_tsk);
    var to = TestOracle{ .names = &.{ "Stand_Idle", "Eat_Idle" }, .flags = &.{"b_Granivore"}, .target = .{ .id = 1, .pos = .{ 0, 0 } } };
    var brain = try Brain.init(testing.allocator, &lib, &.{"Zebra"}, 2);
    defer brain.deinit();
    brain.needs = @splat(0);
    brain.needs[5] = 90;
    // missing b_LargeAnimal
    try testing.expectEqual(@as(?f32, null), brain.score(0, to.oracle()));
    to.flags = &.{ "b_Granivore", "b_LargeAnimal" };
    try testing.expect(brain.score(0, to.oracle()) != null);
    // and without a feeder in reach
    to.target = null;
    try testing.expectEqual(@as(?f32, null), brain.score(0, to.oracle()));
}

test "an animal resting in a shelter plays the generic shelter set" {
    var lib = Library.init(testing.allocator);
    defer lib.deinit();
    try lib.addSets(
        \\<Sets>
        \\ <UseShelter><subjects><Zebra/></subjects><behaviors><BFBehAnimate targetAnim="Lie_Idle" playTime="20"/></behaviors></UseShelter>
        \\</Sets>
    );
    try lib.addTasks(
        \\<BFAITaskTemplateList>
        \\ <BFAITaskTemplate Name="Rest"><BFAICreateData><Subjects_AND><Qualifiers inWater_OR_onLand="true"/></Subjects_AND>
        \\   <Targets><SmallRockCave_Shelter/><Qualifiers inHabitat="true"/></Targets></BFAICreateData>
        \\   <BFAIEvalData><BFAIAttributeFloatMap rest="-45"/></BFAIEvalData>
        \\   <BFBehExecTask><BFBehEnter/><BFBehPlaySet behSet="useContainer"/></BFBehExecTask>
        \\   <BFAICompletionData><BFAIAttributeFloatMap rest="-100"/></BFAICompletionData></BFAITaskTemplate>
        \\</BFAITaskTemplateList>
    );
    var to = TestOracle{
        .names = &.{ "Stand_Idle", "Lie_Idle", "Stand_2Lie", "Lie_2Stand" },
        .target = .{ .id = 5, .pos = .{ 3, 4 }, .kind = "SmallRockCave_Shelter" },
    };
    const oracle = to.oracle();
    var brain = try Brain.init(testing.allocator, &lib, &.{"Zebra"}, 3);
    defer brain.deinit();
    brain.needs = @splat(0);
    brain.needs[0] = 90; // rest
    brain.update(0.1, oracle);
    try testing.expect(brain.current() == .goto);
    brain.reached();
    var lay = false;
    for (0..80) |_| {
        brain.update(0.1, oracle);
        switch (brain.current()) {
            .anim => |a| if (std.mem.eql(u8, a, "Lie_Idle")) {
                lay = true;
            },
            else => {},
        }
    }
    try testing.expect(lay);
}
