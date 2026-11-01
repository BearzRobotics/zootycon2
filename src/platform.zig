//! Platform layer: window, input and timing. Currently backed by SDL3.
const sdl = @import("platform/sdl.zig");

pub const Platform = sdl.Platform;
pub const Window = sdl.Window;
pub const GlContext = sdl.GlContext;
pub const glGetProcAddress = sdl.glGetProcAddress;
pub const Event = sdl.Event;
pub const scancode_escape = sdl.scancode_escape;
pub const lastError = sdl.lastError;

test {
    _ = sdl;
}
pub const AudioOut = sdl.AudioOut;
