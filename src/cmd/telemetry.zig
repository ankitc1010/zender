//! Observability (NFR-10, FR-MCP-3). Every top-level tool call becomes one
//! OpenTelemetry span that continues the caller's W3C trace context from
//! `_meta` (traceparent, tracestate), plus one log line on stderr.
//!
//! Spans go to a file as OTLP/JSON, one ExportTraceServiceRequest per line:
//! the format the OpenTelemetry Collector's otlpjsonfile receiver reads.
//! An OTLP/HTTP exporter and Prometheus /metrics wait for HTTP mode (P3).
//!
//! Nothing here touches scene data, so trace and span ids may be random
//! without affecting determinism (G5).

const std = @import("std");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;

pub const LogFormat = enum { json, text, off };

/// W3C trace context received with a request.
pub const TraceContext = struct {
    trace_id: [16]u8,
    parent_span_id: [8]u8,
    flags: u8,
    /// Passed through unchanged; empty when absent.
    state: []const u8 = "",

    /// Parses a version-00 traceparent ("00-<32 hex>-<16 hex>-<2 hex>").
    /// Malformed values and all-zero ids yield null, so the call starts a
    /// new trace, as the W3C spec asks.
    pub fn parse(traceparent: []const u8, tracestate: []const u8) ?TraceContext {
        if (traceparent.len != 55) return null;
        if (!std.mem.eql(u8, traceparent[0..3], "00-") or traceparent[35] != '-' or traceparent[52] != '-') return null;
        var tc: TraceContext = .{ .trace_id = undefined, .parent_span_id = undefined, .flags = 0, .state = tracestate };
        hexDecode(&tc.trace_id, traceparent[3..35]) orelse return null;
        hexDecode(&tc.parent_span_id, traceparent[36..52]) orelse return null;
        var f: [1]u8 = undefined;
        hexDecode(&f, traceparent[53..55]) orelse return null;
        tc.flags = f[0];
        if (std.mem.allEqual(u8, &tc.trace_id, 0) or std.mem.allEqual(u8, &tc.parent_span_id, 0)) return null;
        // tracestate is at most 32 list members of ≤ 256 bytes; drop anything longer.
        if (tc.state.len > 8192) tc.state = "";
        return tc;
    }
};

/// Lowercase hex only, as traceparent requires.
fn hexDecode(out: []u8, hex: []const u8) ?void {
    for (out, 0..) |*b, i| {
        const hi = nibble(hex[2 * i]) orelse return null;
        const lo = nibble(hex[2 * i + 1]) orelse return null;
        b.* = hi << 4 | lo;
    }
}

fn nibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => null,
    };
}

/// What the command core reports about one finished call.
pub const CallRecord = struct {
    tool: []const u8,
    scene_id: ?[]const u8 = null,
    scene_rev: ?u64 = null,
    /// Unix epoch nanoseconds (real clock).
    start_ns: i96,
    end_ns: i96,
    /// Error code name, null on success.
    error_code: ?[]const u8 = null,
    error_message: []const u8 = "",
    parent: ?TraceContext = null,
};

pub const Span = struct {
    trace_id: [16]u8,
    span_id: [8]u8,
    parent: ?TraceContext,
};

pub const Telemetry = struct {
    io: Io,
    version: []const u8,
    log_format: LogFormat = .off,
    trace_file: ?Io.File = null,
    trace_offset: u64 = 0,

    /// Opens `path` for appending spans.
    pub fn openTraceFile(t: *Telemetry, path: []const u8) !void {
        // Read access too: on Windows, reading the length of a write-only
        // handle is refused (it lacks FILE_READ_ATTRIBUTES).
        const f = try Io.Dir.cwd().createFile(t.io, path, .{ .truncate = false, .read = true });
        t.trace_offset = try f.length(t.io);
        t.trace_file = f;
    }

    pub fn deinit(t: *Telemetry) void {
        if (t.trace_file) |f| f.close(t.io);
        t.trace_file = null;
    }

    pub fn now(t: *const Telemetry) i96 {
        return Io.Clock.real.now(t.io).nanoseconds;
    }

    /// Mints the span for a call, continuing `parent`'s trace if given.
    pub fn startSpan(t: *const Telemetry, parent: ?TraceContext) Span {
        var s: Span = .{ .trace_id = undefined, .span_id = undefined, .parent = parent };
        if (parent) |p| s.trace_id = p.trace_id else randomNonZero(t.io, &s.trace_id);
        randomNonZero(t.io, &s.span_id);
        return s;
    }

    /// Writes the call's log line and span. Telemetry must never fail a
    /// call, so write errors are dropped.
    pub fn recordCall(t: *Telemetry, arena: Allocator, span: Span, rec: CallRecord) void {
        if (t.log_format != .off) {
            const line = formatCallLog(arena, t.log_format, span, rec) catch return;
            Io.File.stderr().writeStreamingAll(t.io, line) catch {};
        }
        if (t.trace_file) |f| {
            var out: std.Io.Writer.Allocating = .init(arena);
            var w: Stringify = .{ .writer = &out.writer };
            writeSpanRequest(&w, t.version, span, rec) catch return;
            out.writer.writeByte('\n') catch return;
            f.writePositionalAll(t.io, out.written(), t.trace_offset) catch return;
            t.trace_offset += out.written().len;
        }
    }

    /// A free-form event: "server started" and the like.
    pub fn event(t: *Telemetry, arena: Allocator, level: []const u8, msg: []const u8, fields: anytype) void {
        if (t.log_format == .off) return;
        const line = formatEvent(arena, t.log_format, t.now(), level, msg, fields) catch return;
        Io.File.stderr().writeStreamingAll(t.io, line) catch {};
    }
};

fn randomNonZero(io: Io, buf: []u8) void {
    while (true) {
        io.random(buf);
        if (!std.mem.allEqual(u8, buf, 0)) return;
    }
}

/// RFC 3339 UTC with milliseconds, e.g. 2026-10-25T19:49:00.123Z.
pub fn formatTimestamp(buf: *[24]u8, unix_ns: i96) []const u8 {
    const ns: u96 = @intCast(@max(0, unix_ns));
    const secs: u64 = @intCast(ns / std.time.ns_per_s);
    const ms: u64 = @intCast(ns % std.time.ns_per_s / std.time.ns_per_ms);
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        yd.year,              md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        ms,
    }) catch unreachable;
}

fn durationMs(rec: CallRecord) f64 {
    return @as(f64, @floatFromInt(rec.end_ns - rec.start_ns)) / std.time.ns_per_ms;
}

pub fn formatCallLog(arena: Allocator, format: LogFormat, span: Span, rec: CallRecord) ![]const u8 {
    var ts_buf: [24]u8 = undefined;
    const ts = formatTimestamp(&ts_buf, rec.end_ns);
    const ms = @round(durationMs(rec) * 1000) / 1000;
    var out: std.Io.Writer.Allocating = .init(arena);
    switch (format) {
        .off => return "",
        .text => {
            try out.writer.print("{s} {s} {s}", .{ ts, if (rec.error_code == null) "info" else "warn", rec.tool });
            if (rec.scene_id) |id| try out.writer.print(" scene={s}", .{id});
            if (rec.scene_rev) |r| try out.writer.print(" rev={d}", .{r});
            if (rec.error_code) |code| try out.writer.print(" error={s}", .{code}) else try out.writer.writeAll(" ok");
            try out.writer.print(" {d} ms trace={x}\n", .{ ms, &span.trace_id });
        },
        .json => {
            var w: Stringify = .{ .writer = &out.writer };
            try w.beginObject();
            try w.objectField("ts");
            try w.write(ts);
            try w.objectField("level");
            try w.write(if (rec.error_code == null) "info" else "warn");
            try w.objectField("msg");
            try w.write("tool call");
            try w.objectField("tool");
            try w.write(rec.tool);
            if (rec.scene_id) |id| {
                try w.objectField("scene_id");
                try w.write(id);
            }
            if (rec.scene_rev) |r| {
                try w.objectField("scene_rev");
                try w.write(r);
            }
            try w.objectField("outcome");
            try w.write(if (rec.error_code == null) "ok" else "error");
            if (rec.error_code) |code| {
                try w.objectField("error_code");
                try w.write(code);
                try w.objectField("error");
                try w.write(rec.error_message);
            }
            try w.objectField("duration_ms");
            try w.print("{d}", .{ms});
            try w.objectField("trace_id");
            try w.print("\"{x}\"", .{&span.trace_id});
            try w.objectField("span_id");
            try w.print("\"{x}\"", .{&span.span_id});
            try w.endObject();
            try out.writer.writeByte('\n');
        },
    }
    return out.toOwnedSlice();
}

fn formatEvent(arena: Allocator, format: LogFormat, at_ns: i96, level: []const u8, msg: []const u8, fields: anytype) ![]const u8 {
    var ts_buf: [24]u8 = undefined;
    const ts = formatTimestamp(&ts_buf, at_ns);
    var out: std.Io.Writer.Allocating = .init(arena);
    switch (format) {
        .off => return "",
        .text => {
            try out.writer.print("{s} {s} {s}", .{ ts, level, msg });
            inline for (std.meta.fields(@TypeOf(fields))) |f| {
                try out.writer.print(" {s}=", .{f.name});
                var w: Stringify = .{ .writer = &out.writer };
                try w.write(@field(fields, f.name));
            }
            try out.writer.writeByte('\n');
        },
        .json => {
            var w: Stringify = .{ .writer = &out.writer };
            try w.beginObject();
            try w.objectField("ts");
            try w.write(ts);
            try w.objectField("level");
            try w.write(level);
            try w.objectField("msg");
            try w.write(msg);
            inline for (std.meta.fields(@TypeOf(fields))) |f| {
                try w.objectField(f.name);
                try w.write(@field(fields, f.name));
            }
            try w.endObject();
            try out.writer.writeByte('\n');
        },
    }
    return out.toOwnedSlice();
}

fn attr(w: *Stringify, key: []const u8, comptime kind: []const u8, value: anytype) Stringify.Error!void {
    try w.beginObject();
    try w.objectField("key");
    try w.write(key);
    try w.objectField("value");
    try w.beginObject();
    try w.objectField(kind);
    try w.write(value);
    try w.endObject();
    try w.endObject();
}

/// One OTLP/JSON ExportTraceServiceRequest holding the call's span. Ids are
/// lowercase hex and 64-bit integers are strings, per the OTLP JSON mapping.
/// Attribute names follow the OpenTelemetry MCP and GenAI conventions.
pub fn writeSpanRequest(w: *Stringify, version: []const u8, span: Span, rec: CallRecord) Stringify.Error!void {
    try w.beginObject();
    try w.objectField("resourceSpans");
    try w.beginArray();
    try w.beginObject();
    try w.objectField("resource");
    try w.beginObject();
    try w.objectField("attributes");
    try w.beginArray();
    try attr(w, "service.name", "stringValue", "zender");
    try attr(w, "service.version", "stringValue", version);
    try w.endArray();
    try w.endObject();
    try w.objectField("scopeSpans");
    try w.beginArray();
    try w.beginObject();
    try w.objectField("scope");
    try w.beginObject();
    try w.objectField("name");
    try w.write("zender.cmd");
    try w.objectField("version");
    try w.write(version);
    try w.endObject();
    try w.objectField("spans");
    try w.beginArray();

    try w.beginObject();
    try w.objectField("traceId");
    try w.print("\"{x}\"", .{&span.trace_id});
    try w.objectField("spanId");
    try w.print("\"{x}\"", .{&span.span_id});
    if (span.parent) |p| {
        try w.objectField("parentSpanId");
        try w.print("\"{x}\"", .{&p.parent_span_id});
        if (p.state.len > 0) {
            try w.objectField("traceState");
            try w.write(p.state);
        }
    }
    try w.objectField("name");
    try w.print("\"tools/call {s}\"", .{rec.tool});
    try w.objectField("kind");
    try w.write(2); // SPAN_KIND_SERVER
    try w.objectField("startTimeUnixNano");
    try w.print("\"{d}\"", .{@as(u96, @intCast(@max(0, rec.start_ns)))});
    try w.objectField("endTimeUnixNano");
    try w.print("\"{d}\"", .{@as(u96, @intCast(@max(0, rec.end_ns)))});
    try w.objectField("attributes");
    try w.beginArray();
    try attr(w, "mcp.method.name", "stringValue", "tools/call");
    try attr(w, "gen_ai.operation.name", "stringValue", "execute_tool");
    try attr(w, "gen_ai.tool.name", "stringValue", rec.tool);
    if (rec.scene_id) |id| try attr(w, "zender.scene_id", "stringValue", id);
    if (rec.scene_rev) |r| {
        var buf: [24]u8 = undefined;
        try attr(w, "zender.scene_rev", "intValue", std.fmt.bufPrint(&buf, "{d}", .{r}) catch unreachable);
    }
    if (rec.error_code) |code| try attr(w, "error.type", "stringValue", code);
    try w.endArray();
    try w.objectField("status");
    try w.beginObject();
    try w.objectField("code");
    try w.write(@as(u8, if (rec.error_code == null) 1 else 2)); // OK, ERROR
    if (rec.error_code != null) {
        try w.objectField("message");
        try w.write(rec.error_message);
    }
    try w.endObject();
    try w.endObject();

    try w.endArray();
    try w.endObject();
    try w.endArray();
    try w.endObject();
    try w.endArray();
    try w.endObject();
}

const testing = std.testing;

test "traceparent parsing follows W3C trace context" {
    const good = TraceContext.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "congo=t61rcWkgMzE").?;
    try testing.expectEqual(@as(u8, 0x4b), good.trace_id[0]);
    try testing.expectEqual(@as(u8, 0xb7), good.parent_span_id[7]);
    try testing.expectEqual(@as(u8, 1), good.flags);
    try testing.expectEqualStrings("congo=t61rcWkgMzE", good.state);
    // Wrong version, uppercase hex, zero ids and bad lengths start a new trace.
    try testing.expect(TraceContext.parse("ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "") == null);
    try testing.expect(TraceContext.parse("00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01", "") == null);
    try testing.expect(TraceContext.parse("00-00000000000000000000000000000000-00f067aa0ba902b7-01", "") == null);
    try testing.expect(TraceContext.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01", "") == null);
    try testing.expect(TraceContext.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7", "") == null);
}

test "timestamps are RFC 3339 UTC with milliseconds" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", formatTimestamp(&buf, 0));
    try testing.expectEqualStrings("2026-10-25T19:49:00.123Z", formatTimestamp(&buf, 1792957740_123_000_000));
}

test "span request is OTLP JSON that continues the parent trace" {
    const parent = TraceContext.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", "a=b").?;
    const span: Span = .{ .trace_id = parent.trace_id, .span_id = .{ 1, 2, 3, 4, 5, 6, 7, 8 }, .parent = parent };
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var w: Stringify = .{ .writer = &out.writer };
    try writeSpanRequest(&w, "0.1.0", span, .{ .tool = "object.delete", .scene_id = "scn_1", .scene_rev = 3, .start_ns = 1000, .end_ns = 2500, .error_code = "not_found", .error_message = "no object" });
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const s = parsed.value.object.get("resourceSpans").?.array.items[0].object.get("scopeSpans").?.array.items[0].object.get("spans").?.array.items[0].object;
    try testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", s.get("traceId").?.string);
    try testing.expectEqualStrings("00f067aa0ba902b7", s.get("parentSpanId").?.string);
    try testing.expectEqualStrings("0102030405060708", s.get("spanId").?.string);
    try testing.expectEqualStrings("a=b", s.get("traceState").?.string);
    try testing.expectEqualStrings("tools/call object.delete", s.get("name").?.string);
    try testing.expectEqualStrings("2500", s.get("endTimeUnixNano").?.string);
    try testing.expectEqual(@as(i64, 2), s.get("status").?.object.get("code").?.integer);
}

test "call log lines are one JSON object each" {
    const span: Span = .{ .trace_id = @splat(0xab), .span_id = @splat(0xcd), .parent = null };
    const line = try formatCallLog(testing.allocator, .json, span, .{ .tool = "scene.inspect", .scene_id = "scn_1", .start_ns = 0, .end_ns = 1_500_000 });
    defer testing.allocator.free(line);
    try testing.expect(line[line.len - 1] == '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("ok", parsed.value.object.get("outcome").?.string);
    try testing.expectEqualStrings("abababababababababababababababab", parsed.value.object.get("trace_id").?.string);
    try testing.expectEqual(@as(f64, 1.5), parsed.value.object.get("duration_ms").?.float);
}
