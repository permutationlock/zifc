const std = @import("std");
const native_endian = @import("builtin").target.cpu.arch.endian();
const mem = std.mem;
const assert = std.debug.assert;

const Impl = @import("zimpl").Impl;

pub const vio = @import("vio.zig");

pub const FixedBufferReader = @import("io/FixedBufferReader.zig");
pub const FixedBufferStream = @import("io/FixedBufferStream.zig");
pub const CountingWriter = @import("io/counting_writer.zig").CountingWriter;
pub const countingWriter = @import("io/counting_writer.zig").countingWriter;
pub const BufferedReader = @import("io/buffered_reader.zig").BufferedReader;
pub const bufferedReader = @import("io/buffered_reader.zig").bufferedReader;
pub const BufferedWriter = @import("io/buffered_writer.zig").BufferedWriter;
pub const bufferedWriter = @import("io/buffered_writer.zig").bufferedWriter;

pub const null_writer = NullWriter{};

pub const NullWriter = struct {
    pub const WriteError = error{};
    pub fn write(_: NullWriter, data: []const u8) WriteError!usize {
        return data.len;
    }
};

test "null_writer" {
    writeAll(null_writer, .{}, "yay" ** 10) catch |err| switch (err) {};
}

pub fn Reader(comptime T: type) type {
    return struct {
        ReadError: type = anyerror,
        read: fn (reader_ctx: T, buffer: []u8) anyerror!usize,
        readBuffer: ?fn (reader_ctx: T) anyerror![]const u8 = null,
    };
}

pub inline fn read(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
    buffer: []u8,
) reader_impl.ReadError!usize {
    return @errorCast(reader_impl.read(reader_ctx, buffer));
}

pub inline fn isBufferedReader(
    comptime ReaderCtx: type,
    reader_impl: Impl(Reader, ReaderCtx),
) bool {
    return !(reader_impl.readBuffer == null);
}

pub inline fn readBuffer(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
) reader_impl.ReadError![]const u8 {
    if (reader_impl.readBuffer) |readBufferFn| {
        return @errorCast(readBufferFn(reader_ctx));
    }
    @compileError("called 'readBuffer' on unbuffered reader");
}

pub inline fn readAll(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
    buffer: []u8,
) reader_impl.ReadError!usize {
    return readAtLeast(reader_ctx, reader_impl, buffer, buffer.len);
}

pub inline fn readAtLeast(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
    buffer: []u8,
    len: usize,
) reader_impl.ReadError!usize {
    assert(len <= buffer.len);
    var index: usize = 0;
    while (index < len) {
        const amt = try read(reader_ctx, reader_impl, buffer[index..]);
        if (amt == 0) break;
        index += amt;
    }
    return index;
}

pub inline fn readNoEof(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
    buf: []u8,
) (reader_impl.ReadError || error{EndOfStream})!void {
    const amt_read = try readAll(reader_ctx, reader_impl, buf);
    if (amt_read < buf.len) return error.EndOfStream;
}

pub inline fn streamUntilDelimiter(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
    writer_ctx: anytype,
    writer_impl: Impl(Writer, @TypeOf(writer_ctx)),
    delimiter: u8,
    optional_max_size: ?usize,
) (reader_impl.ReadError || writer_impl.WriteError || error{
    EndOfStream,
    StreamTooLong,
})!void {
    if (isBufferedReader(@TypeOf(reader_ctx), reader_impl)) {
        while (true) {
            const buffer = try readBuffer(reader_ctx, reader_impl);
            if (buffer.len == 0) {
                return error.EndOfStream;
            }
            const len = std.mem.indexOfScalar(
                u8,
                buffer,
                delimiter,
            ) orelse buffer.len;
            if (optional_max_size) |max| {
                if (len > max) {
                    return error.StreamTooLong;
                }
            }

            try writeAll(writer_ctx, writer_impl, buffer[0..len]);
            if (len != buffer.len) {
                return skipBytes(reader_ctx, reader_impl, len + 1, .{});
            }
            try skipBytes(reader_ctx, reader_impl, len, .{});
        }
    } else {
        if (optional_max_size) |max_size| {
            for (0..max_size) |_| {
                const byte: u8 = try readByte(reader_ctx, reader_impl);
                if (byte == delimiter) return;
                try writeByte(writer_ctx, writer_impl, byte);
            }
            return error.StreamTooLong;
        } else {
            while (true) {
                const byte: u8 = try readByte(reader_ctx, reader_impl);
                if (byte == delimiter) return;
                try writeByte(writer_ctx, writer_impl, byte);
            }
        }
    }
}

pub inline fn skipUntilDelimiterOrEof(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
    delimiter: u8,
) reader_impl.ReadError!void {
    if (isBufferedReader(@TypeOf(reader_ctx), reader_impl)) {
        while (true) {
            const buffer = try readBuffer(reader_ctx, reader_impl);
            if (buffer.len == 0) {
                return;
            }
            const len = std.mem.indexOfScalar(
                u8,
                buffer,
                delimiter,
            ) orelse buffer.len;
            if (len != buffer.len) {
                skipBytes(
                    reader_ctx,
                    reader_impl,
                    len + 1,
                    .{},
                ) catch unreachable;
                return;
            }
            skipBytes(reader_ctx, reader_impl, len, .{}) catch unreachable;
        }
    } else {
        while (true) {
            const byte = readByte(
                reader_ctx,
                reader_impl,
            ) catch |err| switch (err) {
                error.EndOfStream => return,
                else => |e| return e,
            };
            if (byte == delimiter) return;
        }
    }
}

pub inline fn readByte(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
) (reader_impl.ReadError || error{EndOfStream})!u8 {
    var result: [1]u8 = undefined;
    const amt_read = try read(reader_ctx, reader_impl, result[0..]);
    if (amt_read < 1) return error.EndOfStream;
    return result[0];
}

pub inline fn readByteSigned(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
) (reader_impl.ReadError || error{EndOfStream})!i8 {
    return @as(i8, @bitCast(try readByte(reader_ctx, reader_impl)));
}

pub inline fn readBytesNoEof(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
    comptime num_bytes: usize,
) (reader_impl.ReadError || error{EndOfStream})![num_bytes]u8 {
    var bytes: [num_bytes]u8 = undefined;
    try readNoEof(reader_ctx, reader_impl, &bytes);
    return bytes;
}

pub inline fn readInt(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
    comptime T: type,
    endian: std.builtin.Endian,
) (reader_impl.ReadError || error{EndOfStream})!T {
    const bytes = try readBytesNoEof(
        reader_ctx,
        reader_impl,
        @divExact(@typeInfo(T).Int.bits, 8),
    );
    return mem.readInt(T, &bytes, endian);
}

pub inline fn readVarInt(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
    comptime ReturnType: type,
    endian: std.builtin.Endian,
    size: usize,
) (reader_impl.ReadError || error{EndOfStream})!ReturnType {
    assert(size <= @sizeOf(ReturnType));
    var bytes_buf: [@sizeOf(ReturnType)]u8 = undefined;
    const bytes = bytes_buf[0..size];
    try readNoEof(reader_ctx, reader_impl, bytes);
    return mem.readVarInt(ReturnType, bytes, endian);
}

pub inline fn skipBytes(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
    num_bytes: u64,
    comptime options: struct {
        buf_size: usize = 512,
    },
) (reader_impl.ReadError || error{EndOfStream})!void {
    var buf: [options.buf_size]u8 = undefined;
    var remaining = num_bytes;

    while (remaining > 0) {
        const amt = @min(remaining, options.buf_size);
        try readNoEof(reader_ctx, reader_impl, buf[0..amt]);
        remaining -= amt;
    }
}

pub inline fn isBytes(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
    slice: []const u8,
) (reader_impl.ReadError || error{EndOfStream})!bool {
    var i: usize = 0;
    var matches = true;
    while (i < slice.len) {
        if (isBufferedReader(@TypeOf(reader_ctx), reader_impl)) {
            const buffer = try readBuffer(reader_ctx, reader_impl);
            const len = @min(buffer.len, slice.len - i);
            if (len == 0) {
                return error.EndOfStream;
            }
            if (!std.mem.eql(u8, slice[i..][0..len], buffer[0..len])) {
                matches = false;
            }
            try skipBytes(reader_ctx, reader_impl, len, .{});
            i += len;
        } else {
            if (slice[i] != try readByte(reader_ctx, reader_impl)) {
                matches = false;
            }
            i += 1;
        }
    }
    return matches;
}

pub inline fn readStruct(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
    comptime T: type,
) (reader_impl.ReadError || error{EndOfStream})!T {
    comptime assert(@typeInfo(T).Struct.layout != .Auto);
    var res: [1]T = undefined;
    try readNoEof(reader_ctx, reader_impl, mem.sliceAsBytes(res[0..]));
    return res[0];
}

pub inline fn readStructBig(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
    comptime T: type,
) (reader_impl.ReadError || error{EndOfStream})!T {
    var res = try readStruct(reader_ctx, reader_impl, T);
    if (native_endian != std.builtin.Endian.big) {
        mem.byteSwapAllFields(T, &res);
    }
    return res;
}

pub inline fn readEnum(
    reader_ctx: anytype,
    reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
    comptime Enum: type,
    endian: std.builtin.Endian,
) (reader_impl.ReadError || error{ EndOfStream, InvalidValue })!Enum {
    const type_info = @typeInfo(Enum).Enum;
    const tag = try readInt(
        reader_ctx,
        reader_impl,
        type_info.tag_type,
        endian,
    );

    inline for (std.meta.fields(Enum)) |field| {
        if (tag == field.value) {
            return @field(Enum, field.name);
        }
    }

    return error.InvalidValue;
}

pub fn Writer(comptime T: type) type {
    return struct {
        WriteError: type = anyerror,
        write: fn (writer_ctx: T, bytes: []const u8) anyerror!usize,
        flushBuffer: ?fn (writer_ctx: T) anyerror!void = null,
    };
}

pub inline fn write(
    writer_ctx: anytype,
    writer_impl: Impl(Writer, @TypeOf(writer_ctx)),
    bytes: []const u8,
) writer_impl.WriteError!usize {
    return @errorCast(writer_impl.write(writer_ctx, bytes));
}

pub inline fn flushBuffer(
    writer_ctx: anytype,
    writer_impl: Impl(Writer, @TypeOf(writer_ctx)),
) writer_impl.WriteError!void {
    if (writer_impl.flushBuffer) |flushFn| {
        return @errorCast(flushFn(writer_ctx));
    }
}

pub fn writeAll(
    writer_ctx: anytype,
    writer_impl: Impl(Writer, @TypeOf(writer_ctx)),
    bytes: []const u8,
) writer_impl.WriteError!void {
    var index: usize = 0;
    while (index != bytes.len) {
        index += try write(writer_ctx, writer_impl, bytes[index..]);
    }
}

pub fn writeByte(
    writer_ctx: anytype,
    writer_impl: Impl(Writer, @TypeOf(writer_ctx)),
    byte: u8,
) writer_impl.WriteError!void {
    const array = [1]u8{byte};
    return writeAll(writer_ctx, writer_impl, &array);
}

pub fn writeByteNTimes(
    writer_ctx: anytype,
    writer_impl: Impl(Writer, @TypeOf(writer_ctx)),
    byte: u8,
    n: usize,
) writer_impl.WriteError!void {
    var bytes: [256]u8 = undefined;
    @memset(bytes[0..], byte);

    var remaining: usize = n;
    while (remaining > 0) {
        const to_write = @min(remaining, bytes.len);
        try writeAll(writer_ctx, writer_impl, bytes[0..to_write]);
        remaining -= to_write;
    }
}

pub inline fn writeInt(
    writer_ctx: anytype,
    writer_impl: Impl(Writer, @TypeOf(writer_ctx)),
    comptime T: type,
    value: T,
    endian: std.builtin.Endian,
) writer_impl.WriteError!void {
    var bytes: [@divExact(@typeInfo(T).Int.bits, 8)]u8 = undefined;
    mem.writeInt(
        std.math.ByteAlignedInt(@TypeOf(value)),
        &bytes,
        value,
        endian,
    );
    return writeAll(writer_ctx, writer_impl, &bytes);
}

pub fn writeStruct(
    writer_ctx: anytype,
    writer_impl: Impl(Writer, @TypeOf(writer_ctx)),
    value: anytype,
) writer_impl.WriteError!void {
    comptime assert(@typeInfo(@TypeOf(value)).Struct.layout != .Auto);
    return writeAll(writer_ctx, writer_impl, mem.asBytes(&value));
}

pub fn Seekable(comptime T: type) type {
    return struct {
        SeekError: type = anyerror,

        seekTo: fn (seek_ctx: T, pos: u64) anyerror!void,
        seekBy: fn (seek_ctx: T, amt: i64) anyerror!void,

        GetSeekPosError: type = anyerror,

        getPos: fn (seek_ctx: T) anyerror!u64,
        getEndPos: fn (seek_ctx: T) anyerror!u64,
    };
}

pub fn seekTo(
    seek_ctx: anytype,
    seek_impl: Impl(Seekable, @TypeOf(seek_ctx)),
    pos: u64,
) seek_impl.SeekError!void {
    return @errorCast(seek_impl.seekTo(seek_ctx, pos));
}

pub fn seekBy(
    seek_ctx: anytype,
    seek_impl: Impl(Seekable, @TypeOf(seek_ctx)),
    amt: i64,
) seek_impl.SeekError!void {
    return @errorCast(seek_impl.seekBy(seek_ctx, amt));
}

pub fn getPos(
    seek_ctx: anytype,
    seek_impl: Impl(Seekable, @TypeOf(seek_ctx)),
) seek_impl.GetSeekPosError!u64 {
    return @errorCast(seek_impl.getPos(seek_ctx));
}

pub fn getEndPos(
    seek_ctx: anytype,
    seek_impl: Impl(Seekable, @TypeOf(seek_ctx)),
) seek_impl.GetSeekPosError!u64 {
    return @errorCast(seek_impl.getEndPos(seek_ctx));
}

test {
    std.testing.refAllDecls(@This());
}
