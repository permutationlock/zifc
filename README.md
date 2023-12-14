# Zimpl Zig interfaces

A dead simple implementation of [static dispatch][2] interfaces in Zig
that emerged from a tiny subset of [ztrait][1]. See [here][3]
for some motivation.

Also included is a compatible implementation of [dynamic dispatch][4]
interfaces via `comptime` generated [vtables][5]. Inspired by
[`interface.zig`][6].

## Static dispatch

### `Impl`

```Zig
pub fn Impl(comptime Ifc: fn (type) type, comptime T: type) type { ... }
```

### Definitions

If `T` is a single-item pointer type, define `U` to be the child type, i.e.
`T = *U`. Otherwise, define `U` to be `T`.

### Arguments

The function `Ifc` must always return a struct type.
If `U` has a declaration matching the name of a field from
`Ifc(T)` that cannot coerce to the type of that field, then a
compile error will occur.

### Return value

The type `Impl(Ifc, T)` is a struct type with the same fields
as `Ifc(T)`, but with the default value of each field set equal to
the declaration of `U` of the same name, if such a declaration
exists.

### Example

```Zig
// An interface
pub fn Reader(comptime T: type) type {
    return struct {
        ReadError: type = anyerror,
        read: fn (reader_ctx: T, buffer: []u8) anyerror!usize,
    };
}

// A collection of functions using the interface
pub const io = struct {
    pub inline fn read(
        reader_ctx: anytype,
        reader_impl: Impl(Reader, @TypeOf(reader_ctx)),
        buffer: []u8,
    ) reader_impl.ReadError!usize {
        return @errorCast(reader_impl.read(reader_ctx, buffer));
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
};

test "define and use a reader" {
    const FixedBufferReader = struct {
        buffer: []const u8,
        pos: usize = 0,

        pub const ReadError = error{};

        pub fn read(self: *@This(), out_buffer: []u8) ReadError!usize {
            const len = @min(self.buffer[self.pos..].len, out_buffer.len);
            @memcpy(out_buffer[0..len], self.buffer[self.pos..][0..len]);
            self.pos += len;
            return len;
        }
    };
    const in_buf: []const u8 = "I really hope that this works!";
    var reader = FixedBufferReader{ .buffer = in_buf };

    var out_buf: [16]u8 = undefined;
    const len = try io.readAll(&reader, .{}, &out_buf);

    try testing.expectEqualStrings(in_buf[0..len], out_buf[0..len]);
}

test "use std.fs.File as a reader" {
    var buffer: [19]u8 = undefined;
    var file = try std.fs.cwd().openFile("my_file.txt", .{});
    try io.readAll(file, .{}, &buffer);

    try std.testing.expectEqualStrings("Hello, I am a file!", &buffer);
}

test "use std.os.fd_t as a reader via an explicitly defined interface" {
    var buffer: [19]u8 = undefined;
    const fd = try std.os.open("my_file.txt", std.os.O.RDONLY, 0);
    try io.readAll(
        fd,
        .{ .read = std.os.read, .ReadError = std.os.ReadError, },
        &buffer,
    );

    try std.testing.expectEqualStrings("Hello, I am a file!", &buffer);
}
```

## Dynamic dispatch

### `VIfc`

```Zig
pub fn VIfc(comptime Ifc: fn (type) type) type { ... }
```
### Arguments

The `Ifc` function must always return a struct type.

### Return value

Returns a struct of the following form:
```Zig
struct {
    ctx: *anyopaque,
    vtable: VTable(Ifc),
};
```
The struct type `VTable(Ifc)` contains one field for each field of
`Ifc(*anyopaque)` that is a (optional) function. The type
of each vtable field is converted to a (optional) function pointer
with the same signature.

### `makeVIfc`

```Zig
pub fn makeVIfc(
    comptime Ifc: fn (type) type,
    comptime access: CtxAccess,
) fn (ctx: anytype, impl: Impl(Ifc, CtxType(Ctx, access))) VIfc(Ifc) { ... }
```

### Arguments

The `Ifc` function must always return a struct type.

### Return value

Returns a function to construct a `VIfc(Ifc)` vtable interface from a
concrete runtime context and corresponding interface implementation.

Since vtable interfaces store
contexts as type-erased pointers, the `access` parameters allows for
vtables to work with non-pointer contexts by adding a layer
if indirection: the pointer to the context is dereferenced and passed
by value to the concrete interface function implementations.

### Example

```Zig
// An interface
pub fn Reader(comptime T: type) type {
    return struct {
        // non-function fields are fine, but vtable interfaces ignore them
        ReadError: type = anyerror,
        read: fn (reader_ctx: T, buffer: []u8) anyerror!usize,
    };
}

// Functions to construct virtual 'Reader' interface implementations
const makeReader = makeVIfc(Reader, .Direct);
const makeReaderI = makeVIfc(Reader, .Indirect);

// A collection of functions using virtual 'Reader' interfaces
pub const vio = struct {
    pub inline fn read(reader: VIfc(Reader), buffer: []u8) anyerror!usize {
        return reader.vtable.read(reader.ctx, buffer);
    }

    pub inline fn readAll(reader: VIfc(Reader), buffer: []u8) anyerror!usize {
        return readAtLeast(reader, buffer, buffer.len);
    }

    pub fn readAtLeast(
        reader: VIfc(Reader),
        buffer: []u8,
        len: usize,
    ) anyerror!usize {
        assert(len <= buffer.len);
        var index: usize = 0;
        while (index < len) {
            const amt = try read(reader, buffer[index..]);
            if (amt == 0) break;
            index += amt;
        }
        return index;
    }
};

test "define and use a reader" {
    const FixedBufferReader = struct {
        buffer: []const u8,
        pos: usize = 0,

        pub const ReadError = error{};

        pub fn read(self: *@This(), out_buffer: []u8) ReadError!usize {
            const len = @min(self.buffer[self.pos..].len, out_buffer.len);
            @memcpy(out_buffer[0..len], self.buffer[self.pos..][0..len]);
            self.pos += len;
            return len;
        }
    };
    const in_buf: []const u8 = "I really hope that this works!";
    var reader = FixedBufferReader{ .buffer = in_buf };

    var out_buf: [16]u8 = undefined;
    const len = try vio.readAll(makeReader(&reader, .{}), &out_buf);

    try testing.expectEqualStrings(in_buf[0..len], out_buf[0..len]);
}

test "use std.fs.File as a reader" {
    var buffer: [19]u8 = undefined;
    var file = try std.fs.cwd().openFile("my_file.txt", .{});
    try vio.readAll(makeReaderI(&file, .{}), &buffer);

    try std.testing.expectEqualStrings("Hello, I am a file!", &buffer);
}

test "use std.os.fd_t as a reader via an explicitly defined interface" {
    var buffer: [19]u8 = undefined;
    const fd = try std.os.open("my_file.txt", std.os.O.RDONLY, 0);
    try vio.readAll(
        makeReaderI(
            &fd,
            .{
                .read = std.os.read,
                .ReadError = std.os.ReadError,
            },
        ),
        &buffer,
    );

    try std.testing.expectEqualStrings("Hello, I am a file!", &buffer);
}
```

[1]: https://github.com/permutationlock/ztrait
[2]: https://en.wikipedia.org/wiki/Static_dispatch
[3]: https://github.com/permutationlock/zimpl/blob/main/why.md
[4]: https://en.wikipedia.org/wiki/Dynamic_dispatch
[5]: https://en.wikipedia.org/wiki/Virtual_method_table
[6]: https://github.com/alexnask/interface.zig
