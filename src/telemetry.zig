const std = @import("std");
const otel = @import("otel_types.zig");
const CacheStats = @import("cache_stats.zig").CacheStats;

const entries_metric = "cache.entries";
const bytes_metric = "cache.bytes";
const requests_metric = "http.requests";

const lookups_metric = "cache.lookups";
const lookup_result_attribute = "cache.result";
const hit_result = "hit";
const miss_result = "miss";

pub const Snapshot = struct {
    cache_entries: i64 = 0,
    cache_bytes: i64 = 0,
    requests_total: i64 = 0,
    cache_hits_total: i64 = 0,
    cache_misses_total: i64 = 0,
};

pub const Telemetry = struct {
    allocator: std.mem.Allocator,
    meter_provider: *otel.metrics.MeterProvider,
    metric_reader: *otel.metrics.MetricReader,
    in_memory_exporter: *otel.metrics.InMemoryExporter,
    request_counter: *otel.metrics.Counter(u64),
    lookup_counter: *otel.metrics.Counter(u64),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cache_stats: *CacheStats) !Telemetry {
        const meter_provider = try otel.metrics.MeterProvider.init(allocator, io);
        errdefer meter_provider.shutdown();

        const exporter_pair = try otel.metrics.MetricExporter.InMemory(
            allocator,
            io,
            null,
            null,
        );
        var metric_reader: ?*otel.metrics.MetricReader = null;
        errdefer {
            if (metric_reader) |reader| {
                reader.shutdown();
            } else {
                exporter_pair.exporter.shutdown();
            }
            exporter_pair.in_memory.deinit();
        }

        metric_reader = try otel.metrics.MetricReader.init(
            allocator,
            io,
            exporter_pair.exporter,
        );
        try meter_provider.addReader(metric_reader.?);

        const meter = try meter_provider.getMeter(.{ .name = "example.cache-api" });
        const entries = try meter.createObservableGauge(
            .{
                .name = entries_metric,
                .description = "Number of cached values",
            },
            otel.ObservedContext.from(cache_stats),
            null,
        );
        try entries.registerCallback(observeEntries);

        const bytes = try meter.createObservableGauge(
            .{
                .name = bytes_metric,
                .description = "Bytes stored in cached values",
                .unit = "By",
            },
            otel.ObservedContext.from(cache_stats),
            null,
        );
        try bytes.registerCallback(observeBytes);

        return .{
            .allocator = allocator,
            .meter_provider = meter_provider,
            .metric_reader = metric_reader.?,
            .in_memory_exporter = exporter_pair.in_memory,
            .request_counter = try meter.createCounter(u64, .{
                .name = requests_metric,
                .description = "HTTP requests handled by the API",
            }),
            .lookup_counter = try meter.createCounter(u64, .{
                .name = lookups_metric,
                .description = "Cache lookups",
            }),
        };
    }

    pub fn deinit(self: *Telemetry) void {
        self.metric_reader.shutdown();
        self.in_memory_exporter.deinit();
        self.meter_provider.shutdown();
    }

    pub fn recordRequest(self: *Telemetry) !void {
        try self.request_counter.add(1, .{});
    }

    pub fn recordCacheLookup(self: *Telemetry, hit: bool) !void {
        const result: []const u8 = if (hit) hit_result else miss_result;
        try self.lookup_counter.add(1, .{
            lookup_result_attribute,
            result,
        });
    }

    pub fn collectSnapshot(self: *Telemetry) !Snapshot {
        try self.metric_reader.collect();

        const exported = try self.in_memory_exporter.fetch(self.allocator);
        defer {
            for (exported) |*measurement| measurement.deinit(self.allocator);
            self.allocator.free(exported);
        }

        var snapshot = Snapshot{};
        for (exported) |measurement| {
            const name = measurement.instrumentOptions.name;

            if (std.mem.eql(u8, name, lookups_metric)) {
                collectLookupCounts(&snapshot, measurement);
                continue;
            }

            const value = firstIntegerValue(measurement) orelse continue;
            if (std.mem.eql(u8, name, entries_metric)) {
                snapshot.cache_entries = value;
            } else if (std.mem.eql(u8, name, bytes_metric)) {
                snapshot.cache_bytes = value;
            } else if (std.mem.eql(u8, name, requests_metric)) {
                snapshot.requests_total = value;
            }
        }
        return snapshot;
    }
};

fn collectLookupCounts(snapshot: *Snapshot, measurement: anytype) void {
    switch (measurement.data) {
        .int => |points| {
            for (points) |point| {
                const result = stringAttribute(point.attributes, lookup_result_attribute) orelse continue;

                if (std.mem.eql(u8, result, hit_result)) {
                    snapshot.cache_hits_total += point.value;
                } else if (std.mem.eql(u8, result, miss_result)) {
                    snapshot.cache_misses_total += point.value;
                }
            }
        },
        else => {},
    }
}

fn stringAttribute(
    attributes: anytype,
    key: []const u8,
) ?[]const u8 {
    const items = attributes orelse return null;
    for (items) |attribute| {
        if (!std.mem.eql(u8, attribute.key, key)) continue;
        return switch (attribute.value) {
            .string => |value| value,
            else => null,
        };
    }
    return null;
}

fn observeEntries(
    context: otel.ObservedContext,
    allocator: std.mem.Allocator,
) otel.ObserveResult {
    const stats = context.into(CacheStats) orelse return error.CallbackExecutionFailed;
    return integerMeasurement(allocator, @intCast(stats.count()));
}

fn observeBytes(
    context: otel.ObservedContext,
    allocator: std.mem.Allocator,
) otel.ObserveResult {
    const stats = context.into(CacheStats) orelse return error.CallbackExecutionFailed;
    return integerMeasurement(allocator, @intCast(stats.valueBytes()));
}

fn integerMeasurement(allocator: std.mem.Allocator, value: i64) !otel.MeasurementsData {
    const points = try allocator.alloc(otel.IntegerDataPoint, 1);
    points[0] = .{ .value = value };
    return @unionInit(otel.MeasurementsData, "int", points);
}

fn firstIntegerValue(measurement: anytype) ?i64 {
    return switch (measurement.data) {
        .int => |points| if (points.len == 0) null else points[0].value,
        else => null,
    };
}

test "collect current cache state and cumulative request count" {
    const Cache = @import("cache.zig").Cache;

    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    var cache_stats = CacheStats.from(&cache);
    var telemetry = try Telemetry.init(std.testing.allocator, std.testing.io, &cache_stats);
    defer telemetry.deinit();

    try cache.put("language", "zig");
    try telemetry.recordRequest();

    const first = try telemetry.collectSnapshot();
    try std.testing.expectEqual(@as(i64, 1), first.cache_entries);
    try std.testing.expectEqual(@as(i64, 3), first.cache_bytes);
    try std.testing.expectEqual(@as(i64, 1), first.requests_total);

    try cache.put("project", "otel");
    try telemetry.recordRequest();

    const second = try telemetry.collectSnapshot();
    try std.testing.expectEqual(@as(i64, 2), second.cache_entries);
    try std.testing.expectEqual(@as(i64, 7), second.cache_bytes);
    try std.testing.expectEqual(@as(i64, 2), second.requests_total);
}

test "collect cumulative cache lookup counts" {
    const Cache = @import("cache.zig").Cache;

    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();

    var cache_stats = CacheStats.from(&cache);
    var telemetry = try Telemetry.init(
        std.testing.allocator,
        std.testing.io,
        &cache_stats,
    );
    defer telemetry.deinit();

    try telemetry.recordCacheLookup(true);

    const first = try telemetry.collectSnapshot();
    try std.testing.expectEqual(@as(i64, 1), first.cache_hits_total);
    try std.testing.expectEqual(@as(i64, 0), first.cache_misses_total);

    try telemetry.recordCacheLookup(true);
    try telemetry.recordCacheLookup(false);

    const second = try telemetry.collectSnapshot();
    try std.testing.expectEqual(@as(i64, 2), second.cache_hits_total);
    try std.testing.expectEqual(@as(i64, 1), second.cache_misses_total);
}
