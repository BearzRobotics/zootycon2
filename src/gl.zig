//! Minimal OpenGL 3.3 core bindings, loaded at runtime through a
//! caller-supplied `getProcAddress` (SDL provides one). Only what the
//! renderer uses is declared.

const std = @import("std");

pub const Enum = u32;
pub const Uint = u32;
pub const Int = i32;
pub const Sizei = i32;
pub const Float = f32;
pub const Bitfield = u32;

pub const COLOR_BUFFER_BIT: Bitfield = 0x4000;
pub const DEPTH_BUFFER_BIT: Bitfield = 0x0100;
pub const DEPTH_TEST: Enum = 0x0B71;
pub const CULL_FACE: Enum = 0x0B44;
pub const BLEND: Enum = 0x0BE2;
pub const LEQUAL: Enum = 0x0203;
pub const BACK: Enum = 0x0405;
pub const CCW: Enum = 0x0901;
pub const CW: Enum = 0x0900;
pub const SRC_ALPHA: Enum = 0x0302;
pub const ONE_MINUS_SRC_ALPHA: Enum = 0x0303;
pub const TEXTURE_2D: Enum = 0x0DE1;
pub const TEXTURE0: Enum = 0x84C0;
pub const TEXTURE_MIN_FILTER: Enum = 0x2801;
pub const TEXTURE_MAG_FILTER: Enum = 0x2800;
pub const TEXTURE_WRAP_S: Enum = 0x2802;
pub const TEXTURE_WRAP_T: Enum = 0x2803;
pub const TEXTURE_MAX_LEVEL: Enum = 0x813D;
pub const LINEAR: Enum = 0x2601;
pub const NEAREST: Enum = 0x2600;
pub const TRIANGLE_STRIP: Enum = 0x0005;
pub const LINEAR_MIPMAP_LINEAR: Enum = 0x2703;
pub const REPEAT: Enum = 0x2901;
pub const CLAMP_TO_EDGE: Enum = 0x812F;
pub const RGBA: Enum = 0x1908;
pub const RGBA8: Enum = 0x8058;
pub const UNSIGNED_BYTE: Enum = 0x1401;
pub const UNSIGNED_SHORT: Enum = 0x1403;
pub const UNSIGNED_INT: Enum = 0x1405;
pub const FLOAT: Enum = 0x1406;
pub const TRIANGLES: Enum = 0x0004;
pub const ARRAY_BUFFER: Enum = 0x8892;
pub const ELEMENT_ARRAY_BUFFER: Enum = 0x8893;
pub const STATIC_DRAW: Enum = 0x88E4;
pub const DYNAMIC_DRAW: Enum = 0x88E8;
pub const FRAMEBUFFER: Enum = 0x8D40;
pub const DEPTH_ATTACHMENT: Enum = 0x8D00;
pub const FRAMEBUFFER_COMPLETE: Enum = 0x8CD5;
pub const DEPTH_COMPONENT: Enum = 0x1902;
pub const DEPTH_COMPONENT24: Enum = 0x81A6;
pub const NONE: Enum = 0;
pub const TEXTURE_COMPARE_MODE: Enum = 0x884C;
pub const TEXTURE_COMPARE_FUNC: Enum = 0x884D;
pub const COMPARE_REF_TO_TEXTURE: Enum = 0x884E;
pub const TEXTURE_BORDER_COLOR: Enum = 0x1004;
pub const CLAMP_TO_BORDER: Enum = 0x812D;
pub const FRONT: Enum = 0x0404;
pub const POLYGON_OFFSET_FILL: Enum = 0x8037;
pub const TEXTURE6: Enum = 0x84C6;
pub const VERTEX_SHADER: Enum = 0x8B31;
pub const FRAGMENT_SHADER: Enum = 0x8B30;
pub const COMPILE_STATUS: Enum = 0x8B81;
pub const LINK_STATUS: Enum = 0x8B82;
pub const INFO_LOG_LENGTH: Enum = 0x8B84;
pub const VERSION: Enum = 0x1F02;
pub const RENDERER: Enum = 0x1F01;
pub const PACK_ALIGNMENT: Enum = 0x0D05;
pub const UNPACK_ALIGNMENT: Enum = 0x0CF5;
pub const COMPRESSED_RGB_S3TC_DXT1_EXT: Enum = 0x83F0;
pub const COMPRESSED_RGBA_S3TC_DXT1_EXT: Enum = 0x83F1;
pub const COMPRESSED_RGBA_S3TC_DXT3_EXT: Enum = 0x83F2;
pub const COMPRESSED_RGBA_S3TC_DXT5_EXT: Enum = 0x83F3;

const C = std.builtin.CallingConvention.c;

/// Function table. Field `fooBar` is loaded from the symbol `glFooBar`.
pub const Gl = struct {
    clearColor: *const fn (Float, Float, Float, Float) callconv(C) void = undefined,
    clear: *const fn (Bitfield) callconv(C) void = undefined,
    viewport: *const fn (Int, Int, Sizei, Sizei) callconv(C) void = undefined,
    enable: *const fn (Enum) callconv(C) void = undefined,
    disable: *const fn (Enum) callconv(C) void = undefined,
    depthFunc: *const fn (Enum) callconv(C) void = undefined,
    depthMask: *const fn (u8) callconv(C) void = undefined,
    blendFunc: *const fn (Enum, Enum) callconv(C) void = undefined,
    cullFace: *const fn (Enum) callconv(C) void = undefined,
    frontFace: *const fn (Enum) callconv(C) void = undefined,
    genTextures: *const fn (Sizei, [*]Uint) callconv(C) void = undefined,
    deleteTextures: *const fn (Sizei, [*]const Uint) callconv(C) void = undefined,
    bindTexture: *const fn (Enum, Uint) callconv(C) void = undefined,
    texParameteri: *const fn (Enum, Enum, Int) callconv(C) void = undefined,
    texImage2D: *const fn (Enum, Int, Int, Sizei, Sizei, Int, Enum, Enum, ?*const anyopaque) callconv(C) void = undefined,
    compressedTexImage2D: *const fn (Enum, Int, Enum, Sizei, Sizei, Int, Sizei, ?*const anyopaque) callconv(C) void = undefined,
    generateMipmap: *const fn (Enum) callconv(C) void = undefined,
    activeTexture: *const fn (Enum) callconv(C) void = undefined,
    pixelStorei: *const fn (Enum, Int) callconv(C) void = undefined,
    createShader: *const fn (Enum) callconv(C) Uint = undefined,
    shaderSource: *const fn (Uint, Sizei, [*]const [*:0]const u8, ?[*]const Int) callconv(C) void = undefined,
    compileShader: *const fn (Uint) callconv(C) void = undefined,
    getShaderiv: *const fn (Uint, Enum, *Int) callconv(C) void = undefined,
    getShaderInfoLog: *const fn (Uint, Sizei, ?*Sizei, [*]u8) callconv(C) void = undefined,
    deleteShader: *const fn (Uint) callconv(C) void = undefined,
    createProgram: *const fn () callconv(C) Uint = undefined,
    attachShader: *const fn (Uint, Uint) callconv(C) void = undefined,
    linkProgram: *const fn (Uint) callconv(C) void = undefined,
    getProgramiv: *const fn (Uint, Enum, *Int) callconv(C) void = undefined,
    getProgramInfoLog: *const fn (Uint, Sizei, ?*Sizei, [*]u8) callconv(C) void = undefined,
    useProgram: *const fn (Uint) callconv(C) void = undefined,
    getUniformLocation: *const fn (Uint, [*:0]const u8) callconv(C) Int = undefined,
    uniform1i: *const fn (Int, Int) callconv(C) void = undefined,
    uniform1f: *const fn (Int, Float) callconv(C) void = undefined,
    uniform3fv: *const fn (Int, Sizei, [*]const Float) callconv(C) void = undefined,
    uniform3f: *const fn (Int, Float, Float, Float) callconv(C) void = undefined,
    uniform4f: *const fn (Int, Float, Float, Float, Float) callconv(C) void = undefined,
    uniformMatrix4fv: *const fn (Int, Sizei, u8, [*]const Float) callconv(C) void = undefined,
    genVertexArrays: *const fn (Sizei, [*]Uint) callconv(C) void = undefined,
    bindVertexArray: *const fn (Uint) callconv(C) void = undefined,
    genBuffers: *const fn (Sizei, [*]Uint) callconv(C) void = undefined,
    bindBuffer: *const fn (Enum, Uint) callconv(C) void = undefined,
    bufferData: *const fn (Enum, isize, ?*const anyopaque, Enum) callconv(C) void = undefined,
    bufferSubData: *const fn (Enum, isize, isize, ?*const anyopaque) callconv(C) void = undefined,
    deleteBuffers: *const fn (Sizei, [*]const Uint) callconv(C) void = undefined,
    deleteVertexArrays: *const fn (Sizei, [*]const Uint) callconv(C) void = undefined,
    vertexAttribPointer: *const fn (Uint, Int, Enum, u8, Sizei, ?*const anyopaque) callconv(C) void = undefined,
    enableVertexAttribArray: *const fn (Uint) callconv(C) void = undefined,
    genFramebuffers: *const fn (Sizei, [*]Uint) callconv(C) void = undefined,
    bindFramebuffer: *const fn (Enum, Uint) callconv(C) void = undefined,
    framebufferTexture2D: *const fn (Enum, Enum, Enum, Uint, Int) callconv(C) void = undefined,
    checkFramebufferStatus: *const fn (Enum) callconv(C) Enum = undefined,
    drawBuffers: *const fn (Sizei, [*]const Enum) callconv(C) void = undefined,
    readBuffer: *const fn (Enum) callconv(C) void = undefined,
    texParameterfv: *const fn (Enum, Enum, [*]const Float) callconv(C) void = undefined,
    polygonOffset: *const fn (Float, Float) callconv(C) void = undefined,
    drawArrays: *const fn (Enum, Int, Sizei) callconv(C) void = undefined,
    uniform2f: *const fn (Int, Float, Float) callconv(C) void = undefined,
    drawElements: *const fn (Enum, Sizei, Enum, ?*const anyopaque) callconv(C) void = undefined,
    readPixels: *const fn (Int, Int, Sizei, Sizei, Enum, Enum, ?*anyopaque) callconv(C) void = undefined,
    getString: *const fn (Enum) callconv(C) ?[*:0]const u8 = undefined,
    getError: *const fn () callconv(C) Enum = undefined,

    pub const GetProc = *const fn ([*:0]const u8) ?*const anyopaque;

    /// Resolves every entry point. Returns the first missing symbol's name.
    pub fn load(self: *Gl, get: GetProc) ?[]const u8 {
        inline for (@typeInfo(Gl).@"struct".field_names) |name| {
            const sym = comptime symbolName(name);
            const p = get(sym) orelse return name;
            @field(self, name) = @ptrCast(p);
        }
        return null;
    }
};

/// `clearColor` -> `glClearColor`
fn symbolName(comptime name: []const u8) [*:0]const u8 {
    comptime {
        var buf: [name.len + 2:0]u8 = undefined;
        buf[0] = 'g';
        buf[1] = 'l';
        buf[2] = std.ascii.toUpper(name[0]);
        for (name[1..], 0..) |ch, i| buf[3 + i] = ch;
        const final = buf;
        return &final;
    }
}

test "symbol names are derived from field names" {
    try std.testing.expectEqualStrings("glClearColor", std.mem.span(comptime symbolName("clearColor")));
    try std.testing.expectEqualStrings("glUniformMatrix4fv", std.mem.span(comptime symbolName("uniformMatrix4fv")));
}
