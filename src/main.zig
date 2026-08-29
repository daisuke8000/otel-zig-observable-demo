const std = @import("std");
const Cache = @import("cache.zig").Cache;
const CacheStats = @import("cache_stats.zig").CacheStats;
const Server = @import("server.zig").Server;
const Telemetry = @import("telemetry.zig").Telemetry;

pub fn main(init: std.process.Init) !void {
    var cache = Cache.init(init.gpa);
    defer cache.deinit();

    var cache_stats = CacheStats.from(&cache);
    var telemetry = try Telemetry.init(init.gpa, init.io, &cache_stats);
    defer telemetry.deinit();

    var server = Server{
        .allocator = init.gpa,
        .io = init.io,
        .cache = &cache,
        .telemetry = &telemetry,
    };
    try server.run("127.0.0.1", 8080);
}

test {
    _ = @import("cache.zig");
    _ = @import("cache_stats.zig");
    _ = @import("server.zig");
    _ = @import("telemetry.zig");
}
