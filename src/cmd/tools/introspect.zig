//! schema.describe and ops.list.

const std = @import("std");
const engine = @import("engine");
const server = @import("../server.zig");

const core = engine.core;
const Call = server.Call;
const Tool = server.Tool;
const HandlerError = server.HandlerError;

pub const tools = [_]Tool{
    .{
        .name = "schema.describe",
        .title = "Describe properties",
        .description = "List every property of a datablock type with its kind, unit, range, default and meaning, as accepted by set_properties, material.create and friends. Angles are degrees at this boundary. Example: {\"type\":\"light\"}.",
        .params = &.{
            .{ .name = "type", .type = .{ .enumeration = &.{ "object", "collection", "camera", "light", "material", "world", "scene" } }, .doc = "Datablock type", .required = true },
        },
        .kind = .global,
        .idempotent = true,
        .handler = describe,
    },
    .{
        .name = "ops.list",
        .title = "List tools",
        .description = "List all tools with a one-line purpose and whether each reads, changes or destroys data. Example: {}.",
        .params = &.{},
        .kind = .global,
        .idempotent = true,
        .handler = list,
    },
};

fn describe(c: *Call) HandlerError!void {
    const t = c.args.str("type").?;
    try c.field("type");
    try c.out.write(t);
    try c.field("conventions");
    try c.out.write("right-handed, Z up, metres, angles in degrees at the tool boundary, colours scene-linear Rec.709 in 0..1");
    try c.field("properties");
    if (std.mem.eql(u8, t, "object")) {
        try core.registry.writeDescription(core.types.Object, &c.out);
    } else if (std.mem.eql(u8, t, "collection")) {
        try core.registry.writeDescription(core.types.Collection, &c.out);
    } else if (std.mem.eql(u8, t, "camera")) {
        try core.registry.writeDescription(core.types.Camera, &c.out);
    } else if (std.mem.eql(u8, t, "light")) {
        try core.registry.writeDescription(core.types.Light, &c.out);
    } else if (std.mem.eql(u8, t, "material")) {
        try core.registry.writeDescription(core.types.Material, &c.out);
    } else if (std.mem.eql(u8, t, "world")) {
        try core.registry.writeDescription(core.types.World, &c.out);
    } else {
        try core.registry.writeDescription(core.types.Scene, &c.out);
    }
    try c.say("Properties of {s}.", .{t});
}

fn list(c: *Call) HandlerError!void {
    try c.field("tools");
    try c.out.beginArray();
    for (c.server.tools) |t| {
        try c.out.beginObject();
        try c.out.objectField("name");
        try c.out.write(t.name);
        try c.out.objectField("title");
        try c.out.write(t.title);
        try c.out.objectField("effect");
        try c.out.write(if (t.destructive) "destructive" else switch (t.kind) {
            .global, .read_only => "read-only",
            .mutating, .lifecycle => "changes scene",
        });
        try c.out.endObject();
    }
    try c.out.endArray();
    try c.say("{d} tools.", .{c.server.tools.len});
}
