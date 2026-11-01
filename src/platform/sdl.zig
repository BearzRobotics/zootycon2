//! The only file that talks to SDL. Everything platform-specific (window,
//! input, later audio) goes through here so the rest of the engine stays
//! platform-independent.

const std = @import("std");
const c = @import("sdl_c");

pub const Error = error{ SdlInit, WindowCreate };

pub const Event = union(enum) {
    quit,
    key_down: struct { scancode: u32, repeat: bool },
    key_up: struct { scancode: u32 },
    resized: struct { width: u32, height: u32 },
    mouse_move: struct { x: f32, y: f32 },
    mouse_button: struct { button: u8, down: bool, x: f32, y: f32 },
    mouse_wheel: struct { dx: f32, dy: f32 },
};

pub const scancode_escape: u32 = c.SDL_SCANCODE_ESCAPE;

/// Text of the most recent SDL error.
pub fn lastError() []const u8 {
    return std.mem.span(c.SDL_GetError());
}

pub const Platform = struct {
    pub fn init() Error!Platform {
        if (!c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS)) return error.SdlInit;
        return .{};
    }

    pub fn deinit(_: Platform) void {
        c.SDL_Quit();
    }

    /// Name of the video driver in use (e.g. "wayland", "x11").
    pub fn videoDriver(_: Platform) []const u8 {
        const name = c.SDL_GetCurrentVideoDriver() orelse return "none";
        return std.mem.span(name);
    }

    /// Returns the next pending event, or null if none are queued.
    pub fn pollEvent(_: Platform) ?Event {
        var e: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&e)) {
            switch (e.type) {
                c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => return .quit,
                c.SDL_EVENT_KEY_DOWN => return .{ .key_down = .{ .scancode = @intCast(e.key.scancode), .repeat = e.key.repeat } },
                c.SDL_EVENT_KEY_UP => return .{ .key_up = .{ .scancode = @intCast(e.key.scancode) } },
                c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => return .{ .resized = .{
                    .width = @intCast(e.window.data1),
                    .height = @intCast(e.window.data2),
                } },
                c.SDL_EVENT_MOUSE_MOTION => return .{ .mouse_move = .{ .x = e.motion.x, .y = e.motion.y } },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => return .{ .mouse_button = .{
                    .button = e.button.button,
                    .down = e.button.down,
                    .x = e.button.x,
                    .y = e.button.y,
                } },
                c.SDL_EVENT_MOUSE_WHEEL => return .{ .mouse_wheel = .{ .dx = e.wheel.x, .dy = e.wheel.y } },
                else => {},
            }
        }
        return null;
    }

    pub fn delayMs(_: Platform, ms: u32) void {
        c.SDL_Delay(ms);
    }

    pub fn ticksMs(_: Platform) u64 {
        return c.SDL_GetTicks();
    }
};

pub const Window = struct {
    handle: *c.SDL_Window,

    pub fn create(title: [:0]const u8, width: u32, height: u32) Error!Window {
        const w = c.SDL_CreateWindow(title.ptr, @intCast(width), @intCast(height), c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse
            return error.WindowCreate;
        return .{ .handle = w };
    }

    pub fn destroy(self: Window) void {
        c.SDL_DestroyWindow(self.handle);
    }
};

test "event union is usable without SDL initialised" {
    const e: Event = .{ .key_down = .{ .scancode = scancode_escape, .repeat = false } };
    try std.testing.expect(e == .key_down);
}
