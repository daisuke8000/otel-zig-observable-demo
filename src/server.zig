const std = @import("std");
const httpz = @import("httpz");
const Cache = @import("cache.zig").Cache;
const CacheStats = @import("cache_stats.zig").CacheStats;
const Telemetry = @import("telemetry.zig").Telemetry;

const max_value_size = 4096;

pub const Server = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cache: *Cache,
    telemetry: *Telemetry,

    pub fn run(self: *Server, address: []const u8, port: u16) !void {
        var server = try httpz.Server(*Server).init(
            self.io,
            self.allocator,
            .{
                .address = .{ .ip = try std.Io.net.IpAddress.parse(address, port) },
                .request = .{ .max_body_size = max_value_size },
                // Cache is not thread-safe.
                .thread_pool = .{ .count = 1 },
            },
            self,
        );
        defer {
            server.stop();
            server.deinit();
        }

        var router = try server.router(.{});
        router.get("/", index, .{});
        router.put("/items/:key", putItem, .{});
        router.get("/items/:key", getItem, .{});
        router.delete("/items/:key", deleteItem, .{});
        router.get("/debug/metrics", getMetrics, .{});

        std.debug.print("Cache API listening on http://{s}:{d}\n", .{ address, port });
        try server.listen();
    }

    pub fn dispatch(
        self: *Server,
        action: httpz.Action(*Server),
        request: *httpz.Request,
        response: *httpz.Response,
    ) !void {
        try self.telemetry.recordRequest();
        const start_time = std.Io.Timestamp.now(self.io, .awake);
        defer {
            const end_time = std.Io.Timestamp.now(self.io, .awake);
            const elapsed = start_time.durationTo(end_time);
            const duration_seconds = @as(f64, @floatFromInt(elapsed.toNanoseconds())) / 1e9;
            self.telemetry.recordRequestDuration(duration_seconds) catch |err| {
                std.log.warn("failed to record request duration: {s}", .{@errorName(err)});
            };
        }
        try action(self, request, response);
    }

    pub fn notFound(
        _: *Server,
        _: *httpz.Request,
        response: *httpz.Response,
    ) !void {
        respondText(response, .not_found, "route not found\n");
    }

    fn index(_: *Server, _: *httpz.Request, response: *httpz.Response) !void {
        respondText(response, .ok,
            \\Local in-memory cache API
            \\PUT    /items/{key}
            \\GET    /items/{key}
            \\DELETE /items/{key}
            \\GET    /debug/metrics
            \\
        );
    }

    fn putItem(self: *Server, request: *httpz.Request, response: *httpz.Response) !void {
        const key = request.param("key").?;
        if (!self.validKey(key)) {
            return respondText(response, .bad_request, "key must be 1-64 bytes using letters, numbers, - or _\n");
        }

        self.cache.put(key, request.body() orelse "") catch |err| switch (err) {
            error.KeyTooLong => return respondText(response, .bad_request, "key is too long\n"),
            error.CapacityExceeded => return respondText(response, .insufficient_storage, "cache capacity reached\n"),
            else => return err,
        };
        respondText(response, .created, "stored\n");
    }

    fn getItem(self: *Server, request: *httpz.Request, response: *httpz.Response) !void {
        const key = request.param("key").?;
        if (!self.validKey(key)) {
            return respondText(response, .bad_request, "invalid key\n");
        }

        const cached_value = self.cache.get(key);
        try self.telemetry.recordCacheLookup(cached_value != null);
        const value = cached_value orelse {
            return respondText(response, .not_found, "key not found\n");
        };

        // Copy so the response never aliases cache memory that a later
        // request could free or replace.
        response.body = try response.arena.dupe(u8, value);
        response.content_type = .BINARY;
    }

    fn deleteItem(self: *Server, request: *httpz.Request, response: *httpz.Response) !void {
        const key = request.param("key").?;
        if (!self.validKey(key)) {
            return respondText(response, .bad_request, "invalid key\n");
        }
        if (!self.cache.remove(key)) {
            return respondText(response, .not_found, "key not found\n");
        }
        response.setStatus(.no_content);
    }

    fn getMetrics(self: *Server, _: *httpz.Request, response: *httpz.Response) !void {
        try response.json(try self.telemetry.collectSnapshot(), .{});
    }

    fn validKey(self: *const Server, key: []const u8) bool {
        if (key.len == 0 or key.len > self.cache.limits.max_key_bytes) return false;
        for (key) |character| {
            if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') {
                return false;
            }
        }
        return true;
    }
};

fn respondText(response: *httpz.Response, status: std.http.Status, body: []const u8) void {
    response.setStatus(status);
    response.content_type = .TEXT;
    response.body = body;
}

const TestStack = struct {
    cache: Cache,
    cache_stats: CacheStats,
    telemetry: Telemetry,
    server: Server,

    fn init(self: *TestStack, limits: Cache.Limits) !void {
        self.cache = Cache.initWithLimits(std.testing.allocator, limits);
        errdefer self.cache.deinit();
        self.cache_stats = CacheStats.from(&self.cache);
        self.telemetry = try Telemetry.init(std.testing.allocator, std.testing.io, &self.cache_stats);
        self.server = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .cache = &self.cache,
            .telemetry = &self.telemetry,
        };
    }

    fn deinit(self: *TestStack) void {
        self.telemetry.deinit();
        self.cache.deinit();
    }
};

test "cache keys are deliberately simple" {
    var stack: TestStack = undefined;
    try stack.init(.{});
    defer stack.deinit();
    const server = &stack.server;

    try std.testing.expect(server.validKey("language"));
    try std.testing.expect(server.validKey("user_42"));
    try std.testing.expect(!server.validKey(""));
    try std.testing.expect(!server.validKey("a/b"));
    try std.testing.expect(!server.validKey("hello world"));
    try std.testing.expect(!server.validKey("a" ** 65));
}

test "key validation follows the active cache limits" {
    var stack: TestStack = undefined;
    try stack.init(.{ .max_key_bytes = 4 });
    defer stack.deinit();

    try std.testing.expect(stack.server.validKey("user"));
    try std.testing.expect(!stack.server.validKey("user2"));
}

test "store, read, and delete an item over HTTP" {
    var stack: TestStack = undefined;
    try stack.init(.{});
    defer stack.deinit();
    const server = &stack.server;

    {
        var wt = httpz.testing.init(.{});
        defer wt.deinit();
        wt.param("key", "language");
        wt.body("zig");
        try server.dispatch(Server.putItem, wt.req, wt.res);
        try wt.expectStatusCode(.created);
        try wt.expectBody("stored\n");
    }
    {
        var wt = httpz.testing.init(.{});
        defer wt.deinit();
        wt.param("key", "language");
        try server.dispatch(Server.getItem, wt.req, wt.res);
        try wt.expectStatusCode(.ok);
        try wt.expectBody("zig");
    }
    {
        var wt = httpz.testing.init(.{});
        defer wt.deinit();
        wt.param("key", "language");
        try server.dispatch(Server.deleteItem, wt.req, wt.res);
        try wt.expectStatusCode(.no_content);
    }
    {
        var wt = httpz.testing.init(.{});
        defer wt.deinit();
        wt.param("key", "language");
        try server.dispatch(Server.getItem, wt.req, wt.res);
        try wt.expectStatusCode(.not_found);
    }
}

test "reject an invalid key over HTTP" {
    var stack: TestStack = undefined;
    try stack.init(.{});
    defer stack.deinit();

    var wt = httpz.testing.init(.{});
    defer wt.deinit();
    wt.param("key", "a/b");
    try stack.server.dispatch(Server.putItem, wt.req, wt.res);
    try wt.expectStatusCode(.bad_request);
}

test "report handled requests and cache state over HTTP" {
    var stack: TestStack = undefined;
    try stack.init(.{});
    defer stack.deinit();
    const server = &stack.server;

    {
        var wt = httpz.testing.init(.{});
        defer wt.deinit();
        wt.param("key", "language");
        wt.body("zig");
        try server.dispatch(Server.putItem, wt.req, wt.res);
    }

    var wt = httpz.testing.init(.{});
    defer wt.deinit();
    try server.dispatch(Server.getMetrics, wt.req, wt.res);
    try wt.expectStatusCode(.ok);
    try wt.expectJson(.{ .cache_entries = 1, .cache_bytes = 3, .requests_total = 2 });
}

test "record one duration measurement per handled request" {
    var stack: TestStack = undefined;
    try stack.init(.{});
    defer stack.deinit();
    const server = &stack.server;

    {
        var wt = httpz.testing.init(.{});
        defer wt.deinit();
        wt.param("key", "language");
        wt.body("zig");
        try server.dispatch(Server.putItem, wt.req, wt.res);
        try wt.expectStatusCode(.created);
    }

    const snapshot = try stack.telemetry.collectSnapshot();
    try std.testing.expectEqual(@as(u64, 1), snapshot.request_duration_count);
}

test "report cache hits and misses over HTTP" {
    var stack: TestStack = undefined;
    try stack.init(.{});
    defer stack.deinit();
    const server = &stack.server;

    {
        var wt = httpz.testing.init(.{});
        defer wt.deinit();
        wt.param("key", "language");
        wt.body("zig");

        try server.dispatch(Server.putItem, wt.req, wt.res);
        try wt.expectStatusCode(.created);
    }

    {
        var wt = httpz.testing.init(.{});
        defer wt.deinit();
        wt.param("key", "language");

        try server.dispatch(Server.getItem, wt.req, wt.res);
        try wt.expectStatusCode(.ok);
        try wt.expectBody("zig");
    }

    {
        var wt = httpz.testing.init(.{});
        defer wt.deinit();
        wt.param("key", "missing");

        try server.dispatch(Server.getItem, wt.req, wt.res);
        try wt.expectStatusCode(.not_found);
    }

    {
        var wt = httpz.testing.init(.{});
        defer wt.deinit();
        try server.dispatch(Server.getMetrics, wt.req, wt.res);
        try wt.expectStatusCode(.ok);
        try wt.expectJson(.{
            .cache_entries = 1,
            .cache_bytes = 3,
            .requests_total = 4,
            .cache_hits_total = 1,
            .cache_misses_total = 1,
        });
    }
}
