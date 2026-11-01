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

pub const Kind = enum { person, animal };

pub const Anim = enum { idle, walk };

pub const State = enum { idle, walk };

pub const Agent = struct {
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
    /// Simulated seconds since the start.
    time: f64 = 0,
    /// World revision the walkway graph was built from.
    graph_paths: usize = std.math.maxInt(usize),
    /// Fixed step and leftover time for `advance`.
    step_len: f32 = 1.0 / 30.0,
    accum: f32 = 0,

    pub fn init(gpa: std.mem.Allocator, seed: u64) Sim {
        return .{ .gpa = gpa, .rng = .init(seed) };
    }

    pub fn deinit(self: *Sim) void {
        self.agents.deinit(self.gpa);
        self.graph.deinit();
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
            if (found) i += 1 else _ = self.agents.orderedRemove(i);
        }
        // Add agents for new actors.
        for (w.actors.items) |a| {
            if (self.agentFor(a.id) != null) continue;
            const kind = classify(a.binder);
            const ground = w.terrain.zAt(a.position[0], a.position[1]);
            // The rotation matrix's first column is the model's +x axis in
            // the world; models face -y, so heading follows from yaw.
            const yaw = std.math.atan2(a.rotation[3], a.rotation[0]);
            try self.agents.append(self.gpa, .{
                .id = a.id,
                .kind = kind,
                .pos = a.position,
                .ground_offset = a.position[2] - ground,
                .yaw = yaw,
                .speed = if (kind == .person) 0.85 else 1.1,
                .home = .{ a.position[0], a.position[1] },
                .target = .{ a.position[0], a.position[1] },
                .timer = self.rng.random().float(f32) * 3.0,
            });
        }
        if (self.graph_paths != w.paths.items.len) {
            self.graph.deinit();
            self.graph = try Graph.build(self.gpa, w.paths.items, 3.6);
            self.graph_paths = w.paths.items.len;
            for (self.agents.items) |*ag| {
                ag.node = null;
                ag.prev_node = null;
            }
        }
    }

    /// Advances by wall-clock `dt` in fixed steps and writes agent
    /// positions back into the world's actors.
    pub fn advance(self: *Sim, w: *world_mod.World, dt: f32) void {
        self.accum += @min(dt, 0.25);
        while (self.accum >= self.step_len) {
            self.accum -= self.step_len;
            self.stepOnce(w, self.step_len);
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
        for (self.agents.items) |*ag| {
            ag.anim_time += dt;
            switch (ag.state) {
                .idle => {
                    ag.timer -= dt;
                    if (ag.timer <= 0) self.decide(ag, w);
                },
                .walk => self.walk(ag, w, dt),
            }
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
        ag.timer = 2.0 + self.rng.random().float(f32) * 4.0;
    }

    fn startWalk(_: *Sim, ag: *Agent) void {
        ag.state = .walk;
        ag.anim = .walk;
        ag.anim_time = 0;
    }

    fn walk(self: *Sim, ag: *Agent, w: *const world_mod.World, dt: f32) void {
        const dx = ag.target[0] - ag.pos[0];
        const dy = ag.target[1] - ag.pos[1];
        const dist = @sqrt(dx * dx + dy * dy);
        if (dist < 0.15) {
            if (ag.kind == .person and self.rng.random().float(f32) < 0.85) {
                self.decide(ag, w);
            } else self.rest(ag);
            return;
        }
        // Turn towards the target, then move along the heading.
        const want = std.math.atan2(dy, dx) + std.math.pi / 2.0;
        var diff = want - ag.yaw;
        while (diff > std.math.pi) diff -= std.math.tau;
        while (diff < -std.math.pi) diff += std.math.tau;
        const max_turn = 4.0 * dt;
        ag.yaw += std.math.clamp(diff, -max_turn, max_turn);
        // Only advance once roughly facing the target.
        if (@abs(diff) < 1.0) {
            const step = @min(ag.speed * dt, dist);
            ag.pos[0] += dx / dist * step;
            ag.pos[1] += dy / dist * step;
            ag.pos[2] = w.terrain.zAt(ag.pos[0], ag.pos[1]) + ag.ground_offset;
        }
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
