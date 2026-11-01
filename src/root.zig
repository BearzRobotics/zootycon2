//! zootycon2: an open-source engine for Zoo Tycoon 2. Requires the player's
//! own game install; ships no game assets.

pub const archive = @import("archive.zig");
pub const vfs = @import("vfs.zig");
pub const config = @import("config.zig");
pub const xml = @import("xml.zig");
pub const entity = @import("entity.zig");
pub const platform = @import("platform.zig");
pub const gl = @import("gl.zig");
pub const nif = @import("nif.zig");
pub const dds = @import("dds.zig");
pub const model = @import("model.zig");
pub const viewer = @import("viewer.zig");
pub const bf = @import("bf.zig");
pub const terrain = @import("terrain.zig");
pub const map = @import("map.zig");
pub const world = @import("world.zig");
pub const sim = @import("sim.zig");
pub const app = @import("app.zig");
pub const font = @import("font.zig");
pub const environment = @import("environment.zig");
pub const ai = @import("ai.zig");

test {
    _ = archive;
    _ = vfs;
    _ = config;
    _ = xml;
    _ = entity;
    _ = platform;
    _ = gl;
    _ = nif;
    _ = dds;
    _ = model;
    _ = viewer;
    _ = bf;
    _ = terrain;
    _ = map;
    _ = world;
    _ = sim;
    _ = app;
    _ = font;
    _ = environment;
    _ = ai;
}
