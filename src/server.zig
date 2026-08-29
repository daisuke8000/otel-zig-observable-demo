const std = @import("std");
const httpz = @import("httpz");
const Cache = @import("cache.zig").Cache;
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
        if (!validKey(key)) {
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
        if (!validKey(key)) {
            return respondText(response, .bad_request, "invalid key\n");
        }

        response.body = self.cache.get(key) orelse {
            return respondText(response, .not_found, "key not found\n");
        };
        response.content_type = .BINARY;
    }

    fn deleteItem(self: *Server, request: *httpz.Request, response: *httpz.Response) !void {
        const key = request.param("key").?;
        if (!validKey(key)) {
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
};

fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > (Cache.Limits{}).max_key_bytes) return false;
    for (key) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') {
            return false;
        }
    }
    return true;
}

fn respondText(response: *httpz.Response, status: std.http.Status, body: []const u8) void {
    response.setStatus(status);
    response.content_type = .TEXT;
    response.body = body;
}

test "cache keys are deliberately simple" {
    try std.testing.expect(validKey("language"));
    try std.testing.expect(validKey("user_42"));
    try std.testing.expect(!validKey(""));
    try std.testing.expect(!validKey("a/b"));
    try std.testing.expect(!validKey("hello world"));
    try std.testing.expect(!validKey("a" ** 65));
}
