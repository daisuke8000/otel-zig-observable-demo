const std = @import("std");

pub const CacheStats = struct {
    ptr: *const anyopaque,
    vtable: *const VTable,

    const Self = @This();

    pub const VTable = struct {
        count: *const fn (*const anyopaque) usize,
        valueBytes: *const fn (*const anyopaque) usize,
    };

    /// The pointed-to source must outlive every use of the returned interface.
    pub fn from(pointer: anytype) Self {
        const Pointer = @TypeOf(pointer);
        const Source = switch (@typeInfo(Pointer)) {
            .pointer => |info| if (info.size == .one)
                info.child
            else
                @compileError("CacheStats source must be a single-item pointer"),
            else => @compileError("CacheStats source must be a pointer"),
        };

        const Adapter = struct {
            fn count(ptr: *const anyopaque) usize {
                const source: *const Source = @ptrCast(@alignCast(ptr));
                return source.count();
            }

            fn valueBytes(ptr: *const anyopaque) usize {
                const source: *const Source = @ptrCast(@alignCast(ptr));
                return source.valueBytes();
            }
        };

        return .{
            .ptr = @ptrCast(pointer),
            .vtable = &.{
                .count = Adapter.count,
                .valueBytes = Adapter.valueBytes,
            },
        };
    }

    pub fn count(self: Self) usize {
        return self.vtable.count(self.ptr);
    }

    pub fn valueBytes(self: Self) usize {
        return self.vtable.valueBytes(self.ptr);
    }
};

test "adapt a cache statistics source" {
    const Stub = struct {
        entries: usize,
        bytes: usize,

        fn count(self: *const @This()) usize {
            return self.entries;
        }

        fn valueBytes(self: *const @This()) usize {
            return self.bytes;
        }
    };

    var stub = Stub{ .entries = 2, .bytes = 7 };
    const stats = CacheStats.from(&stub);

    try std.testing.expectEqual(@as(usize, 2), stats.count());
    try std.testing.expectEqual(@as(usize, 7), stats.valueBytes());
}
