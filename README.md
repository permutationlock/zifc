# Zimpl Zig interfaces

A dead simple implementation of [static dispatch][2] interfaces in Zig.
This library is a simplified tiny subset of [ztrait][1].

The `zimpl` module exposes two declarations.

## `Impl`

```Zig
pub fn Impl(comptime Type: type, comptime Ifc: fn (type) type) type { ... }
```

### Arguments

There are no special requirements for the arguments of `Impl`.

### Return value

A call to `Impl(Type, Ifc)` returns a struct type.
For each declaration `Ifc(Type).decl` that is a type,
a field of the same name
`decl` is added to `Impl(Type, Ifc)` with type `Ifc(Type).decl`.

If the declaration `Type.decl` exists and `@TypeOf(Type.decl)`
is `Ifc(Type).decl`,
then `Type.decl` is set as the default value for the field
`decl` in `Impl(Type, Ifc)`.

### Intent

The `Ifc` parameter is an interface: given
a type `Type`, the namespace of `Ifc(Type)` defines a set of
declarations that must be implemented for `Type`.
The struct type `Impl(Type, Ifc)` represents a specific
implementation of the interface `Ifc` for `Type`.

The struct `Impl(Type, Ifc)` will be
default constructable if `Type` naturally implements the
interface, i.e. if `Type` has declarations matching
`Ifc(Type)`.

```Zig
// An interface
fn Iterator(comptime Type: type) type {
    return struct {
        pub const next = fn (*Type) ?u32;
    };
}

// A generic function using the interface
fn sum(iter: anytype, impl: Impl(@TypeOf(iter), Iterator)) u32 {
    var mut_iter = iter;
    var sum: u32 = 0;
    while (impl.next(&mut_iter)) |n| {
        sum += n;
    }
    return sum;
}

test {
    const SliceIter = struct {
        slice: []const u32,

        pub fn init(s: []u32) @This() {
            return .{ .slice = s, };
        }

        pub fn next(self: *@This()) ?u32 {
            if (self.slice.len == 0) {
                return null;
            }
            const head = self.slice[0];
            self.slice = self.slice[1..];
            return head;
        }
    };
    const nums = [_]u32{ 1, 2, 3, 4, 5, };
    const total = sum(SliceIter.init(&nums), .{});
    testing.expectEqual(@as(u32, 15), total);
}
```

There is a simlar [full example][4].

## `PtrChild`

```Zig
pub fn PtrChild(comptime Type: type) type { ... }
```

### Arguments

A compile error is thrown unless `Type` is a single item pointer.

### Return value

Returns the child type of a single item pointer.

### Intent

Often one will want to have generic function take a pointer as an `anytype`
argument. Using
`PtrChild` it is simple to specify interface requirements
for the type that the pointer dereferences to.

```Zig
fn Incrementable(comptime Type: type) type {
    return struct {
        pub const increment = fn (*Type) void;
        pub const read = fn (*const Type) usize;
    };
}

// Accepting a pointer with an interface
pub fn countToTen(
    ctr: anytype,
    impl: Impl(PtrChild(@TypeOf(ctr)), Incrementable)
) void {
    while (impl.read(ctr) < 10) {
        impl.increment(ctr);
    }
}

test {
    const MyCounter = struct {
        count: usize,

        pub fn increment(self: *@This()) void {
            self.count += 1;
        }
     
        pub fn read(self: *const @This()) usize {
            return self.count;
        }
    };
    var counter: MyCounter = .{ .count = 0 };
    countToTen(&counter, .{});
    try testing.expectEqual(@as(usize, 10), counter.count);
}
```
There is a similar [full example][3].

[1]: https://github.com/permutationlock/ztrait
[2]: https://en.wikipedia.org/wiki/Static_dispatch
[3]: https://github.com/permutationlock/zimpl/blob/main/examples/count.zig
[4]: https://github.com/permutationlock/zimpl/blob/main/examples/iterator.zig
