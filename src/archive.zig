//! Reader for z2f archives. A z2f file is a standard ZIP container holding the
//! game's data (XML, models, textures, sounds). Only the central directory is
//! read at open time; entry data is read on demand.

const std = @import("std");
const Io = std.Io;
const zip = std.zip;

pub const Archive = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// Path the archive was opened from (owned).
    path: []u8,
    /// Size of the archive file in bytes.
    size: u64,
    file: Io.File,
    file_buffer: []u8,
    reader: Io.File.Reader,
    /// Entry lookup by path. Keys are owned by `names`.
    index: std.StringHashMapUnmanaged(zip.Iterator.Entry),
    names: std.heap.ArenaAllocator,

    pub const OpenError = anyerror;

    /// Opens `path` (absolute) and indexes its central directory.
    /// The result is heap-allocated because the reader refers to its own buffer.
    pub fn open(gpa: std.mem.Allocator, io: Io, path: []const u8) OpenError!*Archive {
        const self = try gpa.create(Archive);
        errdefer gpa.destroy(self);

        self.gpa = gpa;
        self.io = io;
        self.path = try gpa.dupe(u8, path);
        errdefer gpa.free(self.path);
        self.file = try Io.Dir.openFileAbsolute(io, path, .{});
        errdefer self.file.close(io);
        self.size = try self.file.length(io);
        self.file_buffer = try gpa.alloc(u8, 64 * 1024);
        errdefer gpa.free(self.file_buffer);
        self.reader = self.file.reader(io, self.file_buffer);
        self.index = .empty;
        self.names = .init(gpa);
        errdefer self.names.deinit();
        errdefer self.index.deinit(gpa);

        var it = try zip.Iterator.init(&self.reader);
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        while (try it.next()) |entry| {
            const raw = try entry.getFilename(&self.reader, &name_buf, .{ .allow_backslashes = true });
            if (raw.len == 0 or raw[raw.len - 1] == '/') continue; // directory entry
            const name = try self.names.allocator().dupe(u8, raw);
            _ = std.ascii.lowerString(name, name);
            try self.index.put(gpa, name, entry);
        }
        return self;
    }

    pub fn close(self: *Archive) void {
        const gpa = self.gpa;
        self.index.deinit(gpa);
        self.names.deinit();
        gpa.free(self.file_buffer);
        gpa.free(self.path);
        self.file.close(self.io);
        gpa.destroy(self);
    }

    pub fn count(self: *const Archive) usize {
        return self.index.count();
    }

    /// Looks up an entry by path. The game's paths are case-insensitive, so
    /// `path` must already be lowercase.
    pub fn find(self: *const Archive, path: []const u8) ?zip.Iterator.Entry {
        return self.index.get(path);
    }

    /// Writes the uncompressed contents of `path` to `w`.
    ///
    /// std.zip's extractor cross-checks local and central headers and rejects
    /// these archives, so we trust the central directory and only use the local
    /// header to find where the data starts.
    pub fn extract(self: *Archive, path: []const u8, w: *Io.Writer) !void {
        const entry = self.find(path) orelse return error.FileNotFound;
        const r = &self.reader;

        try r.seekTo(entry.file_offset);
        const local = try r.interface.takeStruct(zip.LocalFileHeader, .little);
        if (!std.mem.eql(u8, &local.signature, &zip.local_file_header_sig))
            return error.ZipBadFileOffset;
        try r.seekTo(entry.file_offset + @sizeOf(zip.LocalFileHeader) +
            @as(u64, local.filename_len) + local.extra_len);

        switch (entry.compression_method) {
            .store => r.interface.streamExact64(w, entry.uncompressed_size) catch |err| switch (err) {
                error.ReadFailed => return r.err orelse err,
                else => |e| return e,
            },
            .deflate => {
                var window: [std.compress.flate.max_window_len]u8 = undefined;
                var d: std.compress.flate.Decompress = .init(&r.interface, .raw, &window);
                d.reader.streamExact64(w, entry.uncompressed_size) catch |err| switch (err) {
                    error.ReadFailed => return d.err orelse err,
                    else => |e| return e,
                };
            },
            else => return error.UnsupportedCompressionMethod,
        }
    }

    /// Returns the uncompressed contents of `path`; caller owns the result.
    pub fn readAlloc(self: *Archive, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
        var out: Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try self.extract(path, &out.writer);
        return out.toOwnedSlice();
    }
};
