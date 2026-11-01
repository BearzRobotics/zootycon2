//! zootycon2: an open-source engine for Zoo Tycoon 2. Requires the player's
//! own game install; ships no game assets.

pub const archive = @import("archive.zig");
pub const vfs = @import("vfs.zig");
pub const config = @import("config.zig");
pub const xml = @import("xml.zig");
pub const entity = @import("entity.zig");
pub const platform = @import("platform.zig");
pub const nif = @import("nif.zig");

test {
    _ = archive;
    _ = vfs;
    _ = config;
    _ = xml;
    _ = entity;
    _ = platform;
    _ = nif;
}
