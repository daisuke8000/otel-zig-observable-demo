const std = @import("std");

pub const Cache = struct {
    pub const Limits = struct {
        max_key_bytes: usize = 64,
        max_entries: usize = 1024,
        max_total_bytes: usize = 4 * 1024 * 1024,
    };

    allocator: std.mem.Allocator,
    limits: Limits,
    items: std.StringHashMapUnmanaged([]u8) = .empty,
    value_bytes: usize = 0,
    retained_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return initWithLimits(allocator, .{});
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, limits: Limits) Cache {
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *Cache) void {
        var iterator = self.items.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.items.deinit(self.allocator);
    }

    pub fn put(self: *Cache, key: []const u8, value: []const u8) !void {
        if (key.len > self.limits.max_key_bytes) return error.KeyTooLong;

        if (self.items.getPtr(key)) |stored_value| {
            const retained_without_value = self.retained_bytes - stored_value.*.len;
            if (exceedsLimit(retained_without_value, value.len, self.limits.max_total_bytes)) {
                return error.CapacityExceeded;
            }

            const value_copy = try self.allocator.dupe(u8, value);
            self.value_bytes -= stored_value.*.len;
            self.allocator.free(stored_value.*);
            stored_value.* = value_copy;
            self.value_bytes += value_copy.len;
            self.retained_bytes = retained_without_value + value_copy.len;
            return;
        }

        if (self.items.count() >= self.limits.max_entries) return error.CapacityExceeded;
        if (exceedsLimit(self.retained_bytes, key.len, self.limits.max_total_bytes)) {
            return error.CapacityExceeded;
        }
        const retained_with_key = self.retained_bytes + key.len;
        if (exceedsLimit(retained_with_key, value.len, self.limits.max_total_bytes)) {
            return error.CapacityExceeded;
        }

        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        try self.items.put(self.allocator, key_copy, value_copy);
        self.value_bytes += value_copy.len;
        self.retained_bytes = retained_with_key + value_copy.len;
    }

    pub fn get(self: *const Cache, key: []const u8) ?[]const u8 {
        return self.items.get(key);
    }

    pub fn remove(self: *Cache, key: []const u8) bool {
        const removed = self.items.fetchRemove(key) orelse return false;
        self.value_bytes -= removed.value.len;
        self.retained_bytes -= removed.key.len + removed.value.len;
        self.allocator.free(removed.key);
        self.allocator.free(removed.value);
        return true;
    }

    pub fn count(self: *const Cache) usize {
        return self.items.count();
    }

    pub fn valueBytes(self: *const Cache) usize {
        return self.value_bytes;
    }
};

fn exceedsLimit(current: usize, added: usize, limit: usize) bool {
    return current > limit or added > limit - current;
}

test "store, replace, and remove cache entries" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    try cache.put("language", "zig");
    try std.testing.expectEqualStrings("zig", cache.get("language").?);
    try std.testing.expectEqual(@as(usize, 1), cache.count());
    try std.testing.expectEqual(@as(usize, 3), cache.valueBytes());

    try cache.put("language", "Zig");
    try std.testing.expectEqualStrings("Zig", cache.get("language").?);
    try std.testing.expectEqual(@as(usize, 3), cache.valueBytes());

    try std.testing.expect(cache.remove("language"));
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(usize, 0), cache.valueBytes());
}

test "enforce cache limits without changing stored data" {
    var cache = Cache.initWithLimits(std.testing.allocator, .{
        .max_key_bytes = 4,
        .max_entries = 1,
        .max_total_bytes = 7,
    });
    defer cache.deinit();

    try std.testing.expectError(error.KeyTooLong, cache.put("longer", ""));
    try std.testing.expectEqual(@as(usize, 0), cache.count());

    try cache.put("key", "1234");
    try std.testing.expectError(error.CapacityExceeded, cache.put("next", ""));
    try std.testing.expectError(error.CapacityExceeded, cache.put("key", "12345"));
    try std.testing.expectEqualStrings("1234", cache.get("key").?);
    try std.testing.expectEqual(@as(usize, 4), cache.valueBytes());

    try cache.put("key", "12");
    try std.testing.expectEqualStrings("12", cache.get("key").?);
    try std.testing.expect(cache.remove("key"));

    try cache.put("next", "abc");
    try std.testing.expectEqualStrings("abc", cache.get("next").?);
}
