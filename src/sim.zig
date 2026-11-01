//! Simulation core: agents that live in a `World`, advanced in fixed steps.
//!
//! Each agent runs a tiny task loop modelled on what the game's AI data
//! describes (`ai/tasks/*.tsk`): a default idle task that plays idle
//! animations, and a movement task. People follow the walkway network built
//! from the world's path tiles; animals wander near where they were placed.
//! The loop is deliberately small: data-driven tasks and needs plug in at
//! `decide`, which picks the next task for an agent.

const std = @import("std");
const world_mod = @import("world.zig");
const ai = @import("ai.zig");

pub const Kind = enum { person, animal };

pub const Anim = enum { idle, walk };

pub const State = enum { idle, walk };

/// What an animal's brain needs from the outside world.
pub const BrainSetup = struct {
    lib: *const ai.Library,
    /// The species and groups the animal belongs to (`Lion`, `Lion_Adult_F`...).
    groups: []const []const u8,
};

/// Lets the simulation ask the renderer-side about things only it knows.
pub const Hooks = struct {
    ctx: *anyopaque,
    /// Behaviour data for an entity, if its species has any.
    brain: *const fn (ctx: *anyopaque, binder: []const u8) ?BrainSetup,
    /// Length of an animation for this actor's model, null if it has none by that name.
    anim_len: *const fn (ctx: *anyopaque, actor_id: u32, name: []const u8) ?f32,
    /// Whether an entity has a flag such as `b_Granivore`.
    flag: *const fn (ctx: *anyopaque, binder: []const u8, name: []const u8) bool,
    /// If an entity is a feeder, the kind of container it is (`FoodDish`).
    feeder: *const fn (ctx: *anyopaque, binder: []const u8) ?[]const u8,
    /// Monthly salary of a staff entity (0 for everyone else).
    wage: ?*const fn (ctx: *anyopaque, binder: []const u8) f32 = null,
};

/// A food or water container placed in the world.
pub const Feeder = struct {
    prop_id: u32,
    pos: [2]f32,
    binder: []const u8,
    kind: []const u8,
    /// 0..100, drops as animals eat.
    food: f32,
};

/// What an animal's brain can ask about its surroundings.
const OracleCtx = struct {
    sim: *Sim,
    hooks: Hooks,
    id: u32,
    binder: []const u8,
    pos: [2]f32,

    fn duration(ctx: *anyopaque, name: []const u8) ?f32 {
        const c: *OracleCtx = @ptrCast(@alignCast(ctx));
        return c.hooks.anim_len(c.hooks.ctx, c.id, name);
    }

    fn flag(ctx: *anyopaque, name: []const u8) bool {
        const c: *OracleCtx = @ptrCast(@alignCast(ctx));
        return c.hooks.flag(c.hooks.ctx, c.binder, name);
    }

    /// The nearest feeder of this kind that has food and can be walked to
    /// (no fence in between).
    fn findTarget(ctx: *anyopaque, class: []const u8) ?ai.Target {
        const c: *OracleCtx = @ptrCast(@alignCast(ctx));
        var best: ?ai.Target = null;
        var best_d: f32 = 30 * 30;
        for (c.sim.feeders.items) |f| {
            if (!std.ascii.eqlIgnoreCase(f.binder, class) or f.food < 1) continue;
            const dx = f.pos[0] - c.pos[0];
            const dy = f.pos[1] - c.pos[1];
            const d = dx * dx + dy * dy;
            if (d >= best_d) continue;
            if (c.sim.blocked(c.pos, f.pos)) continue;
            best_d = d;
            best = .{ .id = f.prop_id, .pos = f.pos, .kind = f.kind };
        }
        return best;
    }

    fn useTarget(ctx: *anyopaque, id: u32, amount: f32) void {
        const c: *OracleCtx = @ptrCast(@alignCast(ctx));
        for (c.sim.feeders.items) |*f| if (f.prop_id == id) {
            f.food = @max(0, f.food - amount);
        };
    }
};

/// What a guest is currently heading for.
pub const Goal = enum { none, view, wander, leave };

/// Zoo-wide numbers shown to the player.
pub const Zoo = struct {
    guests_total: u32 = 0,
    guests_left: u32 = 0,
    /// Admission taken so far.
    income: f64 = 0,
    /// Times a guest has stopped to watch an animal.
    views: u32 = 0,
    /// Feeders refilled by keepers, and salaries paid so far.
    refills: u32 = 0,
    wages_paid: f64 = 0,
};

/// What a keeper is doing about feeders.
pub const Job = enum { none, go, work };

pub const Agent = struct {
    /// Behaviour driven by game data (animals); null uses the built-in
    /// idle/walk loop.
    brain: ?ai.Brain = null,
    /// The entity name this agent was made from.
    binder: []const u8 = "",
    /// True while walking to a brain-chosen destination (a feeder).
    goto_active: bool = false,
    /// Visitors follow routes along the paths, watch animals and leave.
    is_guest: bool = false,
    goal: Goal = .none,
    /// Path nodes still to visit, in order, from `route_i`.
    route: std.ArrayList(u32) = .empty,
    route_i: usize = 0,
    /// The animal a guest is walking to or watching.
    view_target: ?u32 = null,
    /// Seconds before the guest heads for the exit.
    tour_left: f32 = std.math.inf(f32),
    /// 0..100, rises when watching animals.
    happiness: f32 = 50,
    leave_done: bool = false,
    /// Keepers walk to low feeders and refill them.
    is_keeper: bool = false,
    wage: f32 = 0,
    job: Job = .none,
    job_feeder: u32 = 0,
    /// Animation the agent is playing, by manifest name.
    anim_name: []const u8 = "Stand_Idle",
    /// Id of the world actor this agent drives.
    id: u32,
    kind: Kind,
    pos: [3]f32,
    /// Height above the terrain, kept from placement.
    ground_offset: f32,
    /// Model yaw (rotation about z); models face -y, so a heading of
    /// `theta` (direction of travel) is yaw `theta + pi/2`.
    yaw: f32,
    state: State = .idle,
    /// Seconds left in the current task.
    timer: f32 = 0,
    speed: f32,
    home: [2]f32,
    target: [2]f32,
    node: ?u32 = null,
    prev_node: ?u32 = null,
    anim: Anim = .idle,
    anim_time: f32 = 0,
};

/// Walkway network: one node per path tile, linked to nearby tiles.
pub const Graph = struct {
    nodes: []const [2]f32 = &.{},
    /// `adj[i]` lists the node indices linked to node `i`.
    adj: []const []const u32 = &.{},
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Graph) void {
        if (self.arena) |*a| a.deinit();
        self.* = .{};
    }

    /// Links tiles whose centres are within `link` of each other.
    pub fn build(gpa: std.mem.Allocator, tiles: []const world_mod.PathTile, link: f32) !Graph {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const nodes = try a.alloc([2]f32, tiles.len);
        for (tiles, nodes) |t, *n| n.* = t.position;
        const adj = try a.alloc([]const u32, tiles.len);
        const link2 = link * link;
        var tmp: std.ArrayList(u32) = .empty;
        defer tmp.deinit(gpa);
        // Quadratic, but path networks are a few thousand tiles at most and
        // this only runs when the tiles change.
        for (nodes, 0..) |p, i| {
            tmp.clearRetainingCapacity();
            for (nodes, 0..) |q, j| {
                if (i == j) continue;
                const dx = p[0] - q[0];
                const dy = p[1] - q[1];
                if (dx * dx + dy * dy <= link2) try tmp.append(gpa, @intCast(j));
            }
            adj[i] = try a.dupe(u32, tmp.items);
        }
        return .{ .nodes = nodes, .adj = adj, .arena = arena };
    }

    /// Shortest walk from node `from` to node `to` (A*), excluding `from`.
    /// Empty if they are the same node or not connected. Caller owns the result.
    pub fn route(self: *const Graph, gpa: std.mem.Allocator, from: u32, to: u32) ![]u32 {
        const n = self.nodes.len;
        if (from == to or from >= n or to >= n) return gpa.alloc(u32, 0);
        const inf = std.math.inf(f32);
        const g_cost = try gpa.alloc(f32, n);
        defer gpa.free(g_cost);
        const f_cost = try gpa.alloc(f32, n);
        defer gpa.free(f_cost);
        const came = try gpa.alloc(i32, n);
        defer gpa.free(came);
        const open = try gpa.alloc(bool, n);
        defer gpa.free(open);
        @memset(g_cost, inf);
        @memset(f_cost, inf);
        @memset(came, -1);
        @memset(open, false);
        const h = struct {
            fn dist(a: [2]f32, b: [2]f32) f32 {
                return @sqrt((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1]));
            }
        };
        g_cost[from] = 0;
        f_cost[from] = h.dist(self.nodes[from], self.nodes[to]);
        open[from] = true;
        while (true) {
            // Open node with the lowest estimate (linear scan: graphs are small).
            var cur: ?usize = null;
            var best: f32 = inf;
            for (open, 0..) |is_open, i| if (is_open and f_cost[i] < best) {
                best = f_cost[i];
                cur = i;
            };
            const c = cur orelse return gpa.alloc(u32, 0); // not connected
            if (c == to) break;
            open[c] = false;
            for (self.adj[c]) |nb| {
                const cost = g_cost[c] + h.dist(self.nodes[c], self.nodes[nb]);
                if (cost < g_cost[nb]) {
                    g_cost[nb] = cost;
                    f_cost[nb] = cost + h.dist(self.nodes[nb], self.nodes[to]);
                    came[nb] = @intCast(c);
                    open[nb] = true;
                }
            }
        }
        var len: usize = 0;
        var at: i32 = @intCast(to);
        while (at >= 0 and at != @as(i32, @intCast(from))) : (at = came[@intCast(at)]) len += 1;
        const out = try gpa.alloc(u32, len);
        at = @intCast(to);
        var i = len;
        while (i > 0) {
            i -= 1;
            out[i] = @intCast(at);
            at = came[@intCast(at)];
        }
        return out;
    }

    /// The node nearest to (x, y) within `max_dist`, if any.
    pub fn nearest(self: *const Graph, x: f32, y: f32, max_dist: f32) ?u32 {
        var best: ?u32 = null;
        var best_d = max_dist * max_dist;
        for (self.nodes, 0..) |n, i| {
            const dx = n[0] - x;
            const dy = n[1] - y;
            const d = dx * dx + dy * dy;
            if (d <= best_d) {
                best_d = d;
                best = @intCast(i);
            }
        }
        return best;
    }
};

/// A fence segment animals cannot cross.
pub const Wall = struct { ax: f32, ay: f32, bx: f32, by: f32 };

fn ccw(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32) f32 {
    return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
}

/// True if segment p-q properly crosses segment a-b.
fn segmentsCross(p: [2]f32, q: [2]f32, w: Wall) bool {
    const d1 = ccw(p[0], p[1], q[0], q[1], w.ax, w.ay);
    const d2 = ccw(p[0], p[1], q[0], q[1], w.bx, w.by);
    const d3 = ccw(w.ax, w.ay, w.bx, w.by, p[0], p[1]);
    const d4 = ccw(w.ax, w.ay, w.bx, w.by, q[0], q[1]);
    return ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0));
}

/// Fences that block movement. Curbs and gates do not.
fn blocksMovement(kind: []const u8) bool {
    var buf: [64]u8 = undefined;
    if (kind.len > buf.len) return true;
    const k = std.ascii.lowerString(&buf, kind);
    return std.mem.indexOf(u8, k, "curb") == null and std.mem.indexOf(u8, k, "gate") == null;
}

pub fn isGuest(binder: []const u8) bool {
    var buf: [128]u8 = undefined;
    if (binder.len > buf.len) return false;
    return std.mem.indexOf(u8, std.ascii.lowerString(&buf, binder), "guest") != null;
}

pub fn isChild(binder: []const u8) bool {
    var buf: [128]u8 = undefined;
    if (binder.len > buf.len) return false;
    const l = std.ascii.lowerString(&buf, binder);
    return std.mem.indexOf(u8, l, "young") != null or std.mem.indexOf(u8, l, "child") != null;
}

pub fn classify(binder: []const u8) Kind {
    const people = [_][]const u8{ "guest", "staff", "keeper", "maintenance", "vet", "tour", "worker", "photographer", "specialist" };
    var buf: [128]u8 = undefined;
    if (binder.len > buf.len) return .animal;
    const lower = std.ascii.lowerString(&buf, binder);
    for (people) |p| if (std.mem.indexOf(u8, lower, p) != null) return .person;
    return .animal;
}

pub const Sim = struct {
    gpa: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
    agents: std.ArrayList(Agent) = .empty,
    graph: Graph = .{},
    walls: std.ArrayList(Wall) = .empty,
    walls_for: usize = std.math.maxInt(usize),
    /// Simulated seconds since the start.
    time: f64 = 0,
    /// World revision the walkway graph was built from.
    graph_paths: usize = std.math.maxInt(usize),
    hooks: ?Hooks = null,
    zoo: Zoo = .{},
    feeders: std.ArrayList(Feeder) = .empty,
    feeders_key: usize = std.math.maxInt(usize),
    /// Entity names guests are made from.
    guest_binders: []const []const u8 = &.{},
    max_guests: u32 = 50,
    /// Seconds between arrivals (min, max), and how long a visit lasts.
    spawn_delay: [2]f32 = .{ 1, 6 },
    tour_secs: [2]f32 = .{ 150, 300 },
    adult_price: f32 = 24,
    child_price: f32 = 12,
    spawn_timer: f32 = 3,
    /// Seconds in a pay period ("month"), and cost of one refill.
    month_secs: f32 = 300,
    month_timer: f32 = 300,
    refill_fee: f32 = 10,
    /// A keeper tops a feeder up once it falls below this.
    refill_below: f32 = 45,
    want_spawn: bool = false,
    entrance: ?[2]f32 = null,
    entrance_node: ?u32 = null,
    entrance_key: usize = std.math.maxInt(usize),
    to_remove: std.ArrayList(u32) = .empty,
    /// Fixed step and leftover time for `advance`.
    step_len: f32 = 1.0 / 30.0,
    accum: f32 = 0,

    pub fn init(gpa: std.mem.Allocator, seed: u64) Sim {
        return .{ .gpa = gpa, .rng = .init(seed) };
    }

    pub fn deinit(self: *Sim) void {
        self.to_remove.deinit(self.gpa);
        self.feeders.deinit(self.gpa);
        for (self.agents.items) |*a| self.freeAgent(a);
        self.agents.deinit(self.gpa);
        self.walls.deinit(self.gpa);
        self.graph.deinit();
    }

    fn blocked(self: *const Sim, p: [2]f32, q: [2]f32) bool {
        for (self.walls.items) |w| if (segmentsCross(p, q, w)) return true;
        return false;
    }

    pub fn agentFor(self: *Sim, id: u32) ?*Agent {
        for (self.agents.items) |*a| if (a.id == id) return a;
        return null;
    }

    /// Makes the agent list match the world's actors (keeping the state of
    /// agents that already exist) and rebuilds the walkway graph if the
    /// path tiles changed.
    pub fn sync(self: *Sim, w: *const world_mod.World) !void {
        // Drop agents whose actor is gone.
        var i: usize = 0;
        while (i < self.agents.items.len) {
            const id = self.agents.items[i].id;
            var found = false;
            for (w.actors.items) |a| if (a.id == id) {
                found = true;
            };
            if (found) {
                i += 1;
            } else {
                var gone = self.agents.orderedRemove(i);
                self.freeAgent(&gone);
            }
        }
        // Add agents for new actors.
        for (w.actors.items) |a| {
            if (self.agentFor(a.id) != null) continue;
            try self.agents.append(self.gpa, try self.makeAgent(a, w));
        }
        if (self.walls_for != w.fences.items.len) {
            self.walls.clearRetainingCapacity();
            for (w.fences.items) |f| {
                if (!blocksMovement(f.kind)) continue;
                try self.walls.append(self.gpa, .{
                    .ax = f.position[0],
                    .ay = f.position[1],
                    .bx = f.position[0] + @cos(f.rotation) * 3.0,
                    .by = f.position[1] + @sin(f.rotation) * 3.0,
                });
            }
            self.walls_for = w.fences.items.len;
        }
        if (self.graph_paths != w.paths.items.len) {
            self.graph.deinit();
            self.graph = try Graph.build(self.gpa, w.paths.items, 3.6);
            self.graph_paths = w.paths.items.len;
            for (self.agents.items) |*ag| {
                ag.node = null;
                ag.prev_node = null;
                ag.route.clearRetainingCapacity();
                ag.route_i = 0;
                if (ag.is_guest and ag.goal != .none) ag.goal = .none;
            }
            self.entrance_key = std.math.maxInt(usize);
        }
        self.findEntrance(w);
        self.syncFeeders(w);
    }

    /// Rebuilds the feeder list from the world's props, keeping food levels
    /// of feeders that were already known.
    fn syncFeeders(self: *Sim, w: *const world_mod.World) void {
        const h = self.hooks orelse return;
        var key: usize = w.props.items.len;
        for (w.props.items) |p| key = key *% 31 +% p.id;
        if (key == self.feeders_key) return;
        self.feeders_key = key;
        var next: std.ArrayList(Feeder) = .empty;
        for (w.props.items) |p| {
            if (p.binder.len == 0) continue;
            const kind = h.feeder(h.ctx, p.binder) orelse continue;
            var food = if (p.food < 0) 60 else p.food; // unknown levels start part full
            for (self.feeders.items) |old| if (old.prop_id == p.id) {
                food = old.food;
            };
            next.append(self.gpa, .{ .prop_id = p.id, .pos = .{ p.position[0], p.position[1] }, .binder = p.binder, .kind = kind, .food = food }) catch {};
        }
        self.feeders.deinit(self.gpa);
        self.feeders = next;
    }

    /// Average wellbeing of the animals, 0..100 (hunger and thirst count).
    pub fn animalWelfare(self: *const Sim) f32 {
        var sum: f32 = 0;
        var n: f32 = 0;
        for (self.agents.items) |a| if (a.kind == .animal) if (a.brain) |b| {
            sum += 100 - @max(b.needs[5], b.needs[6]);
            n += 1;
        };
        return if (n > 0) sum / n else 0;
    }

    fn makeAgent(self: *Sim, a: world_mod.Actor, w: *const world_mod.World) !Agent {
        const kind = classify(a.binder);
        const ground = w.terrain.zAt(a.position[0], a.position[1]);
        // The rotation matrix's first column is the model's +x axis in
        // the world; models face -y, so heading follows from yaw.
        const yaw = std.math.atan2(a.rotation[3], a.rotation[0]);
        var brain: ?ai.Brain = null;
        if (kind == .animal) if (self.hooks) |h| if (h.brain(h.ctx, a.binder)) |setup| {
            brain = try ai.Brain.init(self.gpa, setup.lib, setup.groups, self.rng.random().int(u64));
        };
        const guest = kind == .person and isGuest(a.binder);
        const rnd = self.rng.random();
        const keeper = kind == .person and std.ascii.findIgnoreCase(a.binder, "keeper") != null;
        var wage: f32 = 0;
        if (kind == .person and !guest) if (self.hooks) |h| if (h.wage) |wf| {
            wage = wf(h.ctx, a.binder);
        };
        return .{
            .is_keeper = keeper,
            .wage = wage,
            .brain = brain,
            .binder = a.binder,
            .is_guest = guest,
            .tour_left = if (guest) self.tour_secs[0] + rnd.float(f32) * (self.tour_secs[1] - self.tour_secs[0]) else std.math.inf(f32),
            .happiness = 45 + rnd.float(f32) * 20,
            .id = a.id,
            .kind = kind,
            .pos = a.position,
            .ground_offset = a.position[2] - ground,
            .yaw = yaw,
            .speed = if (kind == .person) 0.85 else 1.1,
            .home = .{ a.position[0], a.position[1] },
            .target = .{ a.position[0], a.position[1] },
            .timer = rnd.float(f32) * 3.0,
        };
    }

    fn freeAgent(self: *Sim, a: *Agent) void {
        if (a.brain) |*b| b.deinit();
        a.route.deinit(self.gpa);
    }

    /// Finds the entrance gate (a front-gate prop) and the path node beside
    /// it, which is where guests arrive and leave.
    fn findEntrance(self: *Sim, w: *const world_mod.World) void {
        const key = w.props.items.len * 7919 + w.paths.items.len;
        if (key == self.entrance_key) return;
        self.entrance_key = key;
        self.entrance = null;
        self.entrance_node = null;
        for (w.props.items) |p| {
            var buf: [160]u8 = undefined;
            if (p.model.len > buf.len) continue;
            const l = std.ascii.lowerString(&buf, p.model);
            if (std.mem.indexOf(u8, l, "gate") == null) continue;
            if (std.mem.indexOf(u8, l, "front") == null and std.mem.indexOf(u8, l, "entrance") == null) continue;
            self.entrance = .{ p.position[0], p.position[1] };
            break;
        }
        const e = self.entrance orelse return;
        self.entrance_node = self.graph.nearest(e[0], e[1], 40);
    }

    /// How many guests are in the zoo and not yet on their way out the door.
    pub fn liveGuests(self: *const Sim) u32 {
        var n: u32 = 0;
        for (self.agents.items) |a| if (a.is_guest and !a.leave_done) {
            n += 1;
        };
        return n;
    }

    /// Mean guest happiness, 0..100.
    pub fn happiness(self: *const Sim) f32 {
        var sum: f32 = 0;
        var n: f32 = 0;
        for (self.agents.items) |a| if (a.is_guest and !a.leave_done) {
            sum += a.happiness;
            n += 1;
        };
        return if (n > 0) sum / n else 0;
    }

    /// Advances by wall-clock `dt` in fixed steps and writes agent
    /// positions back into the world's actors.
    pub fn advance(self: *Sim, w: *world_mod.World, dt: f32) void {
        self.accum += @min(dt, 0.25);
        while (self.accum >= self.step_len) {
            self.accum -= self.step_len;
            self.stepOnce(w, self.step_len);
            if (self.want_spawn) {
                self.want_spawn = false;
                self.spawnGuest(w) catch {};
            }
        }
        // Feeder food levels live in the world so they are saved.
        for (self.feeders.items) |f| for (w.props.items) |*p| if (p.id == f.prop_id) {
            p.food = f.food;
        };
        // Guests who reached the exit leave the world.
        if (self.to_remove.items.len > 0) {
            for (self.to_remove.items) |id| {
                _ = w.remove(id);
                self.zoo.guests_left += 1;
            }
            self.to_remove.clearRetainingCapacity();
        }
        for (self.agents.items) |ag| {
            for (w.actors.items) |*a| if (a.id == ag.id) {
                a.position = ag.pos;
                a.rotation = world_mod.yawRotation(ag.yaw);
            };
        }
    }

    fn stepOnce(self: *Sim, w: *const world_mod.World, dt: f32) void {
        self.time += dt;
        // Arrivals: a new guest every so often while there is room.
        self.spawn_timer -= dt;
        if (self.spawn_timer <= 0) {
            const rnd = self.rng.random();
            self.spawn_timer = self.spawn_delay[0] + rnd.float(f32) * (self.spawn_delay[1] - self.spawn_delay[0]);
            if (self.entrance_node != null and self.guest_binders.len > 0 and self.liveGuests() < self.max_guests) self.want_spawn = true;
        }
        // Pay day.
        self.month_timer -= dt;
        if (self.month_timer <= 0) {
            self.month_timer += self.month_secs;
            for (self.agents.items) |ag| if (ag.wage > 0) {
                self.zoo.income -= ag.wage;
                self.zoo.wages_paid += ag.wage;
            };
        }
        for (self.agents.items) |*ag| {
            ag.anim_time += dt;
            if (ag.brain != null and self.hooks != null) {
                self.thinkAnimal(ag, w, dt);
                continue;
            }
            if (ag.is_guest) {
                self.guestStep(ag, w, dt);
                continue;
            }
            if (ag.is_keeper) {
                self.keeperStep(ag, w, dt);
                continue;
            }
            switch (ag.state) {
                .idle => {
                    ag.timer -= dt;
                    if (ag.timer <= 0) self.decide(ag, w);
                },
                .walk => self.walk(ag, w, dt),
            }
        }
    }

    fn feederById(self: *Sim, id: u32) ?*Feeder {
        for (self.feeders.items) |*f| if (f.prop_id == id) return f;
        return null;
    }

    /// Keepers find the emptiest unattended feeder, walk to it and refill it.
    fn keeperStep(self: *Sim, ag: *Agent, w: *const world_mod.World, dt: f32) void {
        switch (ag.job) {
            .none => {
                ag.state = .idle;
                ag.anim = .idle;
                ag.anim_name = "Stand_Idle";
                ag.timer -= dt;
                if (ag.timer > 0) return;
                ag.timer = 1.0;
                var best: ?*Feeder = null;
                var best_d: f32 = std.math.inf(f32);
                for (self.feeders.items) |*f| {
                    if (f.food >= self.refill_below) continue;
                    var taken = false;
                    for (self.agents.items) |o| if (o.is_keeper and o.job != .none and o.job_feeder == f.prop_id) {
                        taken = true;
                    };
                    if (taken) continue;
                    const dx = f.pos[0] - ag.pos[0];
                    const dy = f.pos[1] - ag.pos[1];
                    const d = dx * dx + dy * dy;
                    if (d < best_d) {
                        best_d = d;
                        best = f;
                    }
                }
                if (best) |f| {
                    ag.job = .go;
                    ag.job_feeder = f.prop_id;
                    ag.target = f.pos;
                    ag.state = .walk;
                    ag.anim = .walk;
                    ag.anim_name = "Walk_Ahead";
                    ag.anim_time = 0;
                }
            },
            .go => {
                if (self.feederById(ag.job_feeder) == null) {
                    ag.job = .none;
                    return;
                }
                switch (self.moveToward(ag, w, dt, ag.speed * 1.4)) {
                    .moving => {},
                    .arrived => {
                        ag.job = .work;
                        ag.timer = 2.5;
                        ag.state = .idle;
                        ag.anim = .idle;
                        ag.anim_name = "Stand_Idle";
                        ag.anim_time = 0;
                    },
                    .blocked => ag.job = .none,
                }
            },
            .work => {
                ag.timer -= dt;
                if (ag.timer > 0) return;
                if (self.feederById(ag.job_feeder)) |f| {
                    f.food = 100;
                    self.zoo.income -= self.refill_fee;
                    self.zoo.refills += 1;
                }
                ag.job = .none;
                ag.timer = 0.5;
            },
        }
    }

    /// Picks the agent's next task.
    fn decide(self: *Sim, ag: *Agent, w: *const world_mod.World) void {
        const rnd = self.rng.random();
        switch (ag.kind) {
            .person => {
                if (self.graph.nodes.len == 0) return self.rest(ag);
                if (ag.node == null) ag.node = self.graph.nearest(ag.pos[0], ag.pos[1], 8.0);
                const here = ag.node orelse return self.rest(ag);
                const next = self.pickNeighbour(here, ag.prev_node) orelse return self.rest(ag);
                ag.prev_node = here;
                ag.node = next;
                ag.target = self.graph.nodes[next];
                self.startWalk(ag);
            },
            .animal => {
                if (rnd.float(f32) < 0.4) return self.rest(ag);
                const ang = rnd.float(f32) * std.math.tau;
                const r = 2.0 + rnd.float(f32) * 6.0;
                var tx = ag.home[0] + @cos(ang) * r;
                var ty = ag.home[1] + @sin(ang) * r;
                tx = std.math.clamp(tx, 1, w.terrain.world_width - 1);
                ty = std.math.clamp(ty, 1, w.terrain.world_height - 1);
                ag.target = .{ tx, ty };
                self.startWalk(ag);
            },
        }
    }

    fn pickNeighbour(self: *Sim, here: u32, prev: ?u32) ?u32 {
        const adj = self.graph.adj[here];
        if (adj.len == 0) return null;
        const rnd = self.rng.random();
        // Prefer not to turn straight back.
        var tries: usize = 0;
        while (tries < 6) : (tries += 1) {
            const c = adj[rnd.uintLessThan(usize, adj.len)];
            if (prev == null or c != prev.? or adj.len == 1) return c;
        }
        return adj[rnd.uintLessThan(usize, adj.len)];
    }

    fn rest(self: *Sim, ag: *Agent) void {
        ag.state = .idle;
        ag.anim = .idle;
        ag.anim_name = "Stand_Idle";
        ag.timer = 2.0 + self.rng.random().float(f32) * 4.0;
    }

    fn startWalk(_: *Sim, ag: *Agent) void {
        ag.state = .walk;
        ag.anim = .walk;
        ag.anim_name = "Walk_Ahead";
        ag.anim_time = 0;
    }

    // ---------------------------------------------------------------- guests

    /// A guest arrives at the entrance and pays admission.
    fn spawnGuest(self: *Sim, w: *world_mod.World) !void {
        const node = self.entrance_node orelse return;
        const rnd = self.rng.random();
        const binder = self.guest_binders[rnd.uintLessThan(usize, self.guest_binders.len)];
        const p = self.graph.nodes[node];
        const z = w.terrain.zAt(p[0], p[1]);
        _ = try w.addActor(binder, .{ p[0], p[1], z }, world_mod.yawRotation(rnd.float(f32) * std.math.tau), &.{});
        // The new actor gets its agent now so the tour starts at once.
        const a = w.actors.items[w.actors.items.len - 1];
        try self.agents.append(self.gpa, try self.makeAgent(a, w));
        self.agents.items[self.agents.items.len - 1].node = node;
        self.zoo.guests_total += 1;
        self.zoo.income += if (isChild(binder)) self.child_price else self.adult_price;
    }

    /// Sets the guest's route to `to` from the node it stands on.
    fn routeTo(self: *Sim, ag: *Agent, to: u32) bool {
        const here = ag.node orelse self.graph.nearest(ag.pos[0], ag.pos[1], 8.0) orelse return false;
        ag.node = here;
        const r = self.graph.route(self.gpa, here, to) catch return false;
        defer self.gpa.free(r);
        if (r.len == 0) return false;
        ag.route.clearRetainingCapacity();
        ag.route.appendSlice(self.gpa, r) catch return false;
        ag.route_i = 0;
        return true;
    }

    fn guestRest(self: *Sim, ag: *Agent, lo: f32, hi: f32) void {
        ag.state = .idle;
        ag.anim = .idle;
        ag.anim_name = "Stand_Idle";
        ag.timer = lo + self.rng.random().float(f32) * (hi - lo);
        ag.goal = .none;
    }

    fn guestStep(self: *Sim, ag: *Agent, w: *const world_mod.World, dt: f32) void {
        if (ag.leave_done) return;
        ag.tour_left -= dt;
        ag.happiness = @max(0, ag.happiness - 0.01 * dt);
        switch (ag.state) {
            .idle => {
                ag.timer -= dt;
                if (ag.timer <= 0) self.guestDecide(ag);
            },
            .walk => {
                if (ag.route_i >= ag.route.items.len) return self.guestArrive(ag);
                const node = ag.route.items[ag.route_i];
                ag.target = self.graph.nodes[node];
                switch (self.moveToward(ag, w, dt, ag.speed)) {
                    .moving => {},
                    .arrived => {
                        ag.node = node;
                        ag.route_i += 1;
                        if (ag.route_i >= ag.route.items.len) self.guestArrive(ag);
                    },
                    .blocked => self.guestRest(ag, 1, 3),
                }
            },
        }
    }

    /// Reached the end of a route.
    fn guestArrive(self: *Sim, ag: *Agent) void {
        switch (ag.goal) {
            .leave => {
                ag.leave_done = true;
                self.to_remove.append(self.gpa, ag.id) catch {};
            },
            .view => {
                // Face the animal and watch it for a while.
                if (ag.view_target) |tid| if (self.agentFor(tid)) |target| {
                    const dx = target.pos[0] - ag.pos[0];
                    const dy = target.pos[1] - ag.pos[1];
                    ag.yaw = std.math.atan2(dy, dx) + std.math.pi / 2.0;
                };
                self.zoo.views += 1;
                // A hungry, thirsty animal is less fun to watch.
                var welfare: f32 = 100;
                if (ag.view_target) |tid| if (self.agentFor(tid)) |target| if (target.brain) |b| {
                    welfare = 100 - @max(b.needs[5], b.needs[6]);
                };
                const worth = 0.3 + 0.7 * welfare / 100.0;
                ag.happiness = @min(100, ag.happiness + (6 + self.rng.random().float(f32) * 4) * worth);
                self.guestRest(ag, 8, 18);
            },
            else => self.guestRest(ag, 2, 6),
        }
    }

    /// Picks what the guest does next.
    fn guestDecide(self: *Sim, ag: *Agent) void {
        const rnd = self.rng.random();
        if (self.graph.nodes.len == 0) return self.guestRest(ag, 3, 6);
        // Time to go home?
        if (ag.tour_left <= 0) if (self.entrance_node) |exit| {
            if (ag.goal != .leave) {
                if (self.routeTo(ag, exit)) {
                    ag.goal = .leave;
                    ag.state = .walk;
                    ag.anim = .walk;
                    ag.anim_name = "Walk_Ahead";
                    return;
                }
                // Already at the exit, or cut off from it: leave from here.
                if ((ag.node orelse 0) == exit) {
                    ag.goal = .leave;
                    return self.guestArrive(ag);
                }
            }
        };
        // Otherwise: go and watch an animal, or just stroll.
        var animals: usize = 0;
        for (self.agents.items) |a| if (a.kind == .animal) {
            animals += 1;
        };
        if (animals > 0 and rnd.float(f32) < 0.75) {
            var tries: usize = 0;
            while (tries < 5) : (tries += 1) {
                var pick = rnd.uintLessThan(usize, animals);
                var target: ?*const Agent = null;
                for (self.agents.items) |*a| if (a.kind == .animal) {
                    if (pick == 0) {
                        target = a;
                        break;
                    }
                    pick -= 1;
                };
                const t = target orelse break;
                // A viewing spot: the walkway node nearest the animal.
                const spot = self.graph.nearest(t.pos[0], t.pos[1], 30) orelse continue;
                if (self.routeTo(ag, spot)) {
                    ag.goal = .view;
                    ag.view_target = t.id;
                    ag.state = .walk;
                    ag.anim = .walk;
                    ag.anim_name = "Walk_Ahead";
                    return;
                }
                // Already standing at that spot: watch from here.
                if ((ag.node orelse 0) == spot) {
                    ag.goal = .view;
                    ag.view_target = t.id;
                    return self.guestArrive(ag);
                }
            }
        }
        // Stroll to a random walkway node.
        const dest: u32 = rnd.uintLessThan(u32, @intCast(self.graph.nodes.len));
        if (self.routeTo(ag, dest)) {
            ag.goal = .wander;
            ag.state = .walk;
            ag.anim = .walk;
            ag.anim_name = "Walk_Ahead";
        } else self.guestRest(ag, 2, 5);
    }

    const Move = enum { moving, arrived, blocked };

    /// Turns towards the agent's target and moves along the heading at
    /// `speed`. Animals stop at fences.
    fn moveToward(self: *Sim, ag: *Agent, w: *const world_mod.World, dt: f32, speed: f32) Move {
        const dx = ag.target[0] - ag.pos[0];
        const dy = ag.target[1] - ag.pos[1];
        const dist = @sqrt(dx * dx + dy * dy);
        if (dist < 0.15) return .arrived;
        // Turn towards the target, then move along the heading.
        const want = std.math.atan2(dy, dx) + std.math.pi / 2.0;
        var diff = want - ag.yaw;
        while (diff > std.math.pi) diff -= std.math.tau;
        while (diff < -std.math.pi) diff += std.math.tau;
        const max_turn = 4.0 * dt;
        ag.yaw += std.math.clamp(diff, -max_turn, max_turn);
        // Only advance once roughly facing the target.
        if (@abs(diff) < 1.0) {
            const step = @min(speed * dt, dist);
            const nx = ag.pos[0] + dx / dist * step;
            const ny = ag.pos[1] + dy / dist * step;
            // Animals cannot walk through fences.
            if (ag.kind == .animal and self.blocked(.{ ag.pos[0], ag.pos[1] }, .{ nx, ny })) return .blocked;
            ag.pos[0] = nx;
            ag.pos[1] = ny;
            ag.pos[2] = w.terrain.zAt(ag.pos[0], ag.pos[1]) + ag.ground_offset;
        }
        return .moving;
    }

    fn walk(self: *Sim, ag: *Agent, w: *const world_mod.World, dt: f32) void {
        switch (self.moveToward(ag, w, dt, ag.speed)) {
            .moving => {},
            .arrived => if (ag.kind == .person and self.rng.random().float(f32) < 0.85) {
                self.decide(ag, w);
            } else self.rest(ag),
            .blocked => self.rest(ag),
        }
    }

    /// Runs an animal's data-driven brain and carries out what it asks for.
    fn thinkAnimal(self: *Sim, ag: *Agent, w: *const world_mod.World, dt: f32) void {
        const h = self.hooks.?;
        var oc: OracleCtx = .{ .sim = self, .hooks = h, .id = ag.id, .binder = ag.binder, .pos = .{ ag.pos[0], ag.pos[1] } };
        const brain = &ag.brain.?;
        brain.update(dt, .{
            .ctx = &oc,
            .duration = OracleCtx.duration,
            .flag = OracleCtx.flag,
            .find_target = OracleCtx.findTarget,
            .use_target = OracleCtx.useTarget,
        });
        const before = ag.anim_name;
        switch (brain.current()) {
            .anim => |name| {
                ag.state = .idle;
                ag.anim = .idle;
                ag.anim_name = name;
                ag.goto_active = false;
            },
            .goto => |p| {
                ag.anim_name = "Walk_Ahead";
                ag.anim = .walk;
                ag.state = .walk;
                ag.goto_active = true;
                ag.target = p;
                switch (self.moveToward(ag, w, dt, ag.speed)) {
                    .moving => {},
                    .arrived => brain.reached(),
                    .blocked => brain.abort(),
                }
            },
            .wander => |speed| {
                const fast = speed == .fast and h.anim_len(h.ctx, ag.id, "Run_Ahead") != null;
                ag.anim_name = if (fast) "Run_Ahead" else "Walk_Ahead";
                ag.anim = .walk;
                const factor: f32 = switch (speed) {
                    .slow => 0.6,
                    .medium => 1.0,
                    .fast => 2.2,
                };
                if (ag.state != .walk or ag.goto_active) {
                    ag.state = .walk;
                    ag.goto_active = false;
                    self.pickWanderTarget(ag, w);
                }
                switch (self.moveToward(ag, w, dt, ag.speed * factor)) {
                    .moving => {},
                    .arrived, .blocked => self.pickWanderTarget(ag, w),
                }
            },
        }
        if (!std.mem.eql(u8, before, ag.anim_name)) ag.anim_time = 0;
    }

    fn pickWanderTarget(self: *Sim, ag: *Agent, w: *const world_mod.World) void {
        const rnd = self.rng.random();
        const ang = rnd.float(f32) * std.math.tau;
        const r = 2.0 + rnd.float(f32) * 6.0;
        ag.target = .{
            std.math.clamp(ag.home[0] + @cos(ang) * r, 1, w.terrain.world_width - 1),
            std.math.clamp(ag.home[1] + @sin(ang) * r, 1, w.terrain.world_height - 1),
        };
    }
};

const testing = std.testing;

fn testTerrain(gpa: std.mem.Allocator) !@import("terrain.zig").Terrain {
    const rs = 28;
    const n = 4; // 4x4 vertices
    var buf: [48 + 4 + 4 + n * n * rs]u8 = undefined;
    @memset(&buf, 0);
    const wr = std.mem.writeInt;
    wr(u32, buf[0..4], 11, .little);
    wr(u32, buf[4..8], @bitCast(@as(f32, 60.0)), .little);
    wr(u32, buf[8..12], @bitCast(@as(f32, 60.0)), .little);
    wr(u32, buf[28..32], n, .little);
    wr(u32, buf[32..36], n, .little);
    wr(u32, buf[44..48], 1, .little);
    wr(u32, buf[48..52], 4, .little);
    @memcpy(buf[52..55], "abc");
    for (0..n * n) |i| {
        const rec = 56 + i * rs;
        wr(u32, buf[rec + 18 ..][0..4], @bitCast(@as(f32, 6.0)), .little);
        wr(u32, buf[rec + 22 ..][0..4], @bitCast(@as(f32, 26.0)), .little);
    }
    return @import("terrain.zig").parse(gpa, &buf);
}

test "classify" {
    try testing.expectEqual(Kind.person, classify("Guest_Adult_F_05"));
    try testing.expectEqual(Kind.person, classify("Staff_Keeper_M"));
    try testing.expectEqual(Kind.animal, classify("Lion_Adult_F"));
}

test "graph links neighbouring tiles" {
    const tiles = [_]world_mod.PathTile{
        .{ .id = 1, .texture = "", .position = .{ 0, 0 }, .width = 6, .height = 6 },
        .{ .id = 2, .texture = "", .position = .{ 3, 0 }, .width = 6, .height = 6 },
        .{ .id = 3, .texture = "", .position = .{ 30, 0 }, .width = 6, .height = 6 },
    };
    var g = try Graph.build(testing.allocator, &tiles, 3.6);
    defer g.deinit();
    try testing.expectEqual(@as(usize, 1), g.adj[0].len);
    try testing.expectEqual(@as(usize, 0), g.adj[2].len);
    try testing.expectEqual(@as(?u32, 1), g.nearest(2.9, 0.1, 1.0));
    try testing.expectEqual(@as(?u32, null), g.nearest(15, 0, 1.0));
}

test "guest follows the path and stays on it" {
    const gpa = testing.allocator;
    var w = world_mod.World.init(gpa, try testTerrain(gpa));
    defer w.deinit();
    // A straight east-west walkway of 8 tiles.
    for (0..8) |i| _ = try w.addPath("t", .{ 3.0 * @as(f32, @floatFromInt(i)) + 10, 30 }, 6, 6);
    const ground = w.terrain.zAt(10, 30);
    const id = try w.addActor("Guest_Adult_F_05", .{ 10, 30, ground }, world_mod.identity_rotation, &.{});
    var sim = Sim.init(gpa, 42);
    defer sim.deinit();
    try sim.sync(&w);
    try testing.expectEqual(@as(usize, 1), sim.agents.items.len);
    var walked: f32 = 0;
    var last = sim.agents.items[0].pos;
    for (0..3000) |_| { // 100 simulated seconds
        sim.advance(&w, 1.0 / 30.0);
        const p = sim.agents.items[0].pos;
        walked += @abs(p[0] - last[0]) + @abs(p[1] - last[1]);
        last = p;
        // never leaves the walkway's footprint
        try testing.expect(p[1] > 29.0 and p[1] < 31.0);
        try testing.expect(p[0] > 9.0 and p[0] < 32.0);
    }
    try testing.expect(walked > 10.0); // it actually went somewhere
    // the world actor mirrors the agent
    try testing.expectApproxEqAbs(last[0], w.actors.items[0].position[0], 1e-4);
    _ = id;
}

test "animals wander near home and the sim is deterministic" {
    const gpa = testing.allocator;
    var results: [2][2]f32 = undefined;
    for (&results) |*res| {
        var w = world_mod.World.init(gpa, try testTerrain(gpa));
        defer w.deinit();
        const ground = w.terrain.zAt(30, 30);
        _ = try w.addActor("Lion_Adult_F", .{ 30, 30, ground }, world_mod.identity_rotation, &.{});
        var sim = Sim.init(gpa, 7);
        defer sim.deinit();
        try sim.sync(&w);
        for (0..1500) |_| {
            sim.advance(&w, 1.0 / 30.0);
            const p = sim.agents.items[0].pos;
            const dx = p[0] - 30;
            const dy = p[1] - 30;
            try testing.expect(dx * dx + dy * dy < 12.0 * 12.0);
        }
        res.* = .{ sim.agents.items[0].pos[0], sim.agents.items[0].pos[1] };
    }
    try testing.expectEqual(results[0][0], results[1][0]);
    try testing.expectEqual(results[0][1], results[1][1]);
}

test "animals stay inside a fenced pen" {
    const gpa = testing.allocator;
    var w = world_mod.World.init(gpa, try testTerrain(gpa));
    defer w.deinit();
    // A 12x12 pen from (24,24) to (36,36) built from 3-unit segments.
    const corners = [_][3]f32{ .{ 24, 24, 0 }, .{ 36, 24, std.math.pi / 2.0 }, .{ 36, 36, std.math.pi }, .{ 24, 36, 3.0 * std.math.pi / 2.0 } };
    for (corners) |c| {
        for (0..4) |i| {
            const k = @as(f32, @floatFromInt(i)) * 3.0;
            _ = try w.addFence("zoowall", .{ c[0] + @cos(c[2]) * k, c[1] + @sin(c[2]) * k, 0 }, c[2]);
        }
    }
    _ = try w.addActor("Lion_Adult_F", .{ 30, 30, 6 }, world_mod.identity_rotation, &.{});
    var sim = Sim.init(gpa, 99);
    defer sim.deinit();
    try sim.sync(&w);
    try testing.expectEqual(@as(usize, 16), sim.walls.items.len);
    var moved = false;
    for (0..6000) |_| {
        sim.advance(&w, 1.0 / 30.0);
        const p = sim.agents.items[0].pos;
        if (@abs(p[0] - 30) > 1 or @abs(p[1] - 30) > 1) moved = true;
        try testing.expect(p[0] > 24 and p[0] < 36 and p[1] > 24 and p[1] < 36);
    }
    try testing.expect(moved);
}

const BrainTest = struct {
    lib: *ai.Library,
    fn brain(ctx: *anyopaque, _: []const u8) ?BrainSetup {
        const self: *BrainTest = @ptrCast(@alignCast(ctx));
        return .{ .lib = self.lib, .groups = &.{ "Lion", "Lion_Adult_F" } };
    }
    fn flag(_: *anyopaque, _: []const u8, name: []const u8) bool {
        return std.mem.eql(u8, name, "b_Granivore") or std.mem.eql(u8, name, "b_LargeAnimal");
    }
    fn feeder(_: *anyopaque, binder: []const u8) ?[]const u8 {
        return if (std.mem.startsWith(u8, binder, "FoodDish")) "FoodDish" else null;
    }
    fn animLen(_: *anyopaque, _: u32, name: []const u8) ?f32 {
        const known = [_][]const u8{ "Stand_Idle", "Lie_Idle", "Walk_Ahead", "Stand_2Lie", "Lie_2Stand", "Sleep_Idle", "Eat_Idle", "Stand_2Eat", "Eat_2Stand" };
        for (known) |k| if (std.mem.eql(u8, k, name)) return 1.5;
        return null;
    }
};

test "animals run data-driven tasks: they wander inside the pen and rest" {
    const gpa = testing.allocator;
    var lib = ai.Library.init(gpa);
    defer lib.deinit();
    try lib.addSets(
        \\<BehaviorSets>
        \\ <Walk><behaviors><BFBehWander minPlayTime="6" maxPlayTime="8" locoSpeed="medium"/></behaviors></Walk>
        \\ <Sleep><behaviors><BFBehAnimate targetAnim="Sleep_Idle"/></behaviors></Sleep>
        \\</BehaviorSets>
    );
    try lib.addTasks(
        \\<BFAITaskTemplateList>
        \\ <BFAITaskTemplate Name="Wander"><BFAICreateData><Subjects><Lion/></Subjects><Targets><self/></Targets></BFAICreateData>
        \\  <BFAIEvalData><BFAIAttributeFloatMap exercise="-30"/></BFAIEvalData>
        \\  <BFBehExecTask><BFBehPlaySet behSet="Walk"/></BFBehExecTask>
        \\  <BFAICompletionData><BFAIAttributeFloatMap exercise="-100" rest="30"/></BFAICompletionData></BFAITaskTemplate>
        \\ <BFAITaskTemplate Name="Sleep"><BFAICreateData><Subjects><Lion/></Subjects><Targets><self/></Targets></BFAICreateData>
        \\  <BFAIEvalData><BFAIAttributeFloatMap rest="-35"/></BFAIEvalData>
        \\  <BFBehExecTask><BFBehPlaySet behSet="Sleep"/></BFBehExecTask>
        \\  <BFAICompletionData><BFAIAttributeFloatMap rest="-100"/></BFAICompletionData></BFAITaskTemplate>
        \\</BFAITaskTemplateList>
    );
    var w = world_mod.World.init(gpa, try testTerrain(gpa));
    defer w.deinit();
    const corners = [_][3]f32{ .{ 24, 24, 0 }, .{ 36, 24, std.math.pi / 2.0 }, .{ 36, 36, std.math.pi }, .{ 24, 36, 3.0 * std.math.pi / 2.0 } };
    for (corners) |c| for (0..4) |i| {
        const k = @as(f32, @floatFromInt(i)) * 3.0;
        _ = try w.addFence("zoowall", .{ c[0] + @cos(c[2]) * k, c[1] + @sin(c[2]) * k, 0 }, c[2]);
    };
    _ = try w.addActor("Lion_Adult_F", .{ 30, 30, 6 }, world_mod.identity_rotation, &.{});
    var bt: BrainTest = .{ .lib = &lib };
    var sim = Sim.init(gpa, 21);
    defer sim.deinit();
    sim.hooks = .{ .ctx = &bt, .brain = BrainTest.brain, .anim_len = BrainTest.animLen, .flag = BrainTest.flag, .feeder = BrainTest.feeder };
    try sim.sync(&w);
    try testing.expect(sim.agents.items[0].brain != null);
    var walked = false;
    var slept = false;
    var travelled: f32 = 0;
    var last = sim.agents.items[0].pos;
    for (0..9000) |_| { // five simulated minutes
        sim.advance(&w, 1.0 / 30.0);
        const ag = sim.agents.items[0];
        if (std.mem.eql(u8, ag.anim_name, "Walk_Ahead")) walked = true;
        if (std.mem.startsWith(u8, ag.anim_name, "Sleep")) slept = true;
        travelled += @abs(ag.pos[0] - last[0]) + @abs(ag.pos[1] - last[1]);
        last = ag.pos;
        try testing.expect(ag.pos[0] > 24 and ag.pos[0] < 36 and ag.pos[1] > 24 and ag.pos[1] < 36);
    }
    try testing.expect(walked);
    try testing.expect(slept);
    try testing.expect(travelled > 5.0);
}

test "routes follow the walkway and avoid gaps" {
    const gpa = testing.allocator;
    // Two rows of tiles joined at the left end: a U shape.
    var tiles: std.ArrayList(world_mod.PathTile) = .empty;
    defer tiles.deinit(gpa);
    for (0..5) |i| try tiles.append(gpa, .{ .id = 0, .texture = "", .position = .{ @as(f32, @floatFromInt(i)) * 3, 0 }, .width = 6, .height = 6 });
    try tiles.append(gpa, .{ .id = 0, .texture = "", .position = .{ 0, 3 }, .width = 6, .height = 6 });
    try tiles.append(gpa, .{ .id = 0, .texture = "", .position = .{ 0, 6 }, .width = 6, .height = 6 });
    for (0..5) |i| try tiles.append(gpa, .{ .id = 0, .texture = "", .position = .{ @as(f32, @floatFromInt(i)) * 3, 6 }, .width = 6, .height = 6 });
    try tiles.append(gpa, .{ .id = 0, .texture = "", .position = .{ 100, 100 }, .width = 6, .height = 6 }); // isolated
    var g = try Graph.build(gpa, tiles.items, 3.6);
    defer g.deinit();
    // from the end of the bottom row (node 4) to the end of the top row (node 11)
    const r = try g.route(gpa, 4, 11);
    defer gpa.free(r);
    try testing.expectEqual(@as(u32, 11), r[r.len - 1]);
    // along 4 tiles, up the end (two tiles share one spot), back along 4
    try testing.expect(r.len >= 10 and r.len <= 11);
    // consecutive nodes are neighbours
    var prev: u32 = 4;
    for (r) |n| {
        var linked = false;
        for (g.adj[prev]) |nb| if (nb == n) {
            linked = true;
        };
        try testing.expect(linked);
        prev = n;
    }
    // the isolated tile cannot be reached
    const none = try g.route(gpa, 0, 12);
    defer gpa.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "guests arrive, pay, watch animals and leave" {
    const gpa = testing.allocator;
    var w = world_mod.World.init(gpa, try testTerrain(gpa));
    defer w.deinit();
    for (0..11) |i| _ = try w.addPath("t", .{ 3.0 * @as(f32, @floatFromInt(i)) + 10, 30 }, 6, 6);
    _ = try w.addProp("entities/objects/buildings/frontgate_df/frontgate_df", .{ 10, 28, 6 }, world_mod.identity_rotation, 1, &.{});
    const ground = w.terrain.zAt(30, 36);
    _ = try w.addActor("Lion_Adult_F", .{ 30, 36, ground }, world_mod.identity_rotation, &.{});
    _ = try w.addActor("Tiger_Adult_M", .{ 20, 36, ground }, world_mod.identity_rotation, &.{});
    var sim = Sim.init(gpa, 5);
    defer sim.deinit();
    const binders = [_][]const u8{ "Guest_Adult_F_05", "Guest_Young_M_01" };
    sim.guest_binders = &binders;
    sim.max_guests = 4;
    sim.spawn_delay = .{ 0.5, 1.0 };
    sim.tour_secs = .{ 20, 30 };
    try sim.sync(&w);
    try testing.expect(sim.entrance_node != null);
    var peak: u32 = 0;
    var synced_rev = w.actors_revision;
    for (0..12000) |_| { // 400 simulated seconds
        sim.advance(&w, 1.0 / 30.0);
        if (w.actors_revision != synced_rev) {
            try sim.sync(&w);
            synced_rev = w.actors_revision;
        }
        peak = @max(peak, sim.liveGuests());
        try testing.expect(sim.liveGuests() <= 4);
        for (sim.agents.items) |ag| if (ag.is_guest and !ag.leave_done) {
            try testing.expect(ag.pos[1] > 28.9 and ag.pos[1] < 31.1);
            try testing.expect(ag.pos[0] > 8.5 and ag.pos[0] < 41.5);
        };
    }
    try testing.expect(sim.zoo.guests_total >= 8);
    try testing.expect(sim.zoo.guests_left > 0);
    try testing.expectEqual(@as(u32, 4), peak);
    try testing.expect(sim.zoo.views > 3);
    // admission: every guest paid either 24 or 12
    const total: f64 = @floatFromInt(sim.zoo.guests_total);
    try testing.expect(sim.zoo.income >= 12 * total and sim.zoo.income <= 24 * total);
    // agents and world actors agree once synced
    try sim.sync(&w);
    try testing.expectEqual(w.actors.items.len, sim.agents.items.len);
}

test "hungry animals eat from a reachable feeder and not through a fence" {
    const gpa = testing.allocator;
    var lib = ai.Library.init(gpa);
    defer lib.deinit();
    try lib.addSets(
        \\<BehaviorSets>
        \\ <UseFoodDish><behaviors><BFBehAnimate targetAnim="Eat_Idle"/></behaviors></UseFoodDish>
        \\</BehaviorSets>
    );
    try lib.addTasks(
        \\<BFAITaskTemplateList>
        \\ <BFAITaskTemplate Name="Eat"><BFAICreateData>
        \\   <Subjects_AND><b_Granivore/><b_LargeAnimal/></Subjects_AND>
        \\   <Targets><FoodDish_Hay/><Qualifiers_AND f_FoodLevel="GE 1" inHabitat="true"/></Targets></BFAICreateData>
        \\  <BFAIEvalData><BFAIAttributeFloatMap hunger="-40"/></BFAIEvalData>
        \\  <BFBehExecTask><BFBehEnter/><BFBehPlaySet behSet="useContainer"/></BFBehExecTask>
        \\  <BFAICompletionData><BFAIAttributeFloatMap hunger="-100"/><BFAITargetData f_FoodLevel="-20"/></BFAICompletionData></BFAITaskTemplate>
        \\</BFAITaskTemplateList>
    );
    var w = world_mod.World.init(gpa, try testTerrain(gpa));
    defer w.deinit();
    const corners = [_][3]f32{ .{ 24, 24, 0 }, .{ 36, 24, std.math.pi / 2.0 }, .{ 36, 36, std.math.pi }, .{ 24, 36, 3.0 * std.math.pi / 2.0 } };
    for (corners) |c| for (0..4) |i| {
        const k = @as(f32, @floatFromInt(i)) * 3.0;
        _ = try w.addFence("zoowall", .{ c[0] + @cos(c[2]) * k, c[1] + @sin(c[2]) * k, 0 }, c[2]);
    };
    const inside = try w.addPropEx("m", .{ 32, 32, 6 }, world_mod.identity_rotation, 1, &.{}, "FoodDish_Hay", 100);
    const outside = try w.addPropEx("m", .{ 40, 30, 6 }, world_mod.identity_rotation, 1, &.{}, "FoodDish_Hay", 100);
    _ = try w.addActor("Zebra_Adult_F", .{ 28, 28, 6 }, world_mod.identity_rotation, &.{});
    var bt: BrainTest = .{ .lib = &lib };
    var sim = Sim.init(gpa, 8);
    defer sim.deinit();
    sim.hooks = .{ .ctx = &bt, .brain = BrainTest.brain, .anim_len = BrainTest.animLen, .flag = BrainTest.flag, .feeder = BrainTest.feeder };
    try sim.sync(&w);
    try testing.expectEqual(@as(usize, 2), sim.feeders.items.len);
    sim.agents.items[0].brain.?.needs = @splat(0);
    sim.agents.items[0].brain.?.needs[5] = 95; // very hungry
    const welfare_before = sim.animalWelfare();
    var ate = false;
    for (0..3000) |_| {
        sim.advance(&w, 1.0 / 30.0);
        const ag = sim.agents.items[0];
        if (std.mem.eql(u8, ag.anim_name, "Eat_Idle")) ate = true;
        try testing.expect(ag.pos[0] > 24 and ag.pos[0] < 36 and ag.pos[1] > 24 and ag.pos[1] < 36);
    }
    try testing.expect(ate);
    // the food was taken from the feeder inside the pen, and recorded in the world
    var inside_food: f32 = -1;
    var outside_food: f32 = -1;
    for (w.props.items) |p| {
        if (p.id == inside) inside_food = p.food;
        if (p.id == outside) outside_food = p.food;
    }
    try testing.expect(inside_food < 100);
    try testing.expectEqual(@as(f32, 100), outside_food); // behind the fence: never used
    try testing.expect(sim.animalWelfare() > welfare_before);
}

test "curbs and gates do not block" {
    try testing.expect(blocksMovement("zoowall"));
    try testing.expect(!blocksMovement("curb_jungle"));
    try testing.expect(!blocksMovement("alpinefencegate_df"));
}

test "removing an actor removes its agent" {
    const gpa = testing.allocator;
    var w = world_mod.World.init(gpa, try testTerrain(gpa));
    defer w.deinit();
    const id = try w.addActor("Lion_Adult_F", .{ 30, 30, 6 }, world_mod.identity_rotation, &.{});
    var sim = Sim.init(gpa, 1);
    defer sim.deinit();
    try sim.sync(&w);
    try testing.expectEqual(@as(usize, 1), sim.agents.items.len);
    try testing.expect(w.remove(id));
    try sim.sync(&w);
    try testing.expectEqual(@as(usize, 0), sim.agents.items.len);
}
