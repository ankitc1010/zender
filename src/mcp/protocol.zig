//! MCP 2026-07-28 message handling (TRD §10), with the 2025-11-25
//! `initialize` handshake accepted for clients that lag (FR-MCP-1).
//!
//! The protocol is stateless: every modern request carries its version and
//! client capabilities in `_meta`, and scenes are addressed by server-minted
//! scene_id arguments, never by connection. The only per-connection state is
//! whether a legacy client opened with `initialize`.
//!
//! Not implemented, by design (FR-MCP-2): the HTTP+SSE transport, Sampling,
//! Roots and Logging. Server-to-client input uses MRTR `input_required`.

const std = @import("std");
const cmd = @import("cmd");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Stringify = std.json.Stringify;
const Server = cmd.Server;

pub const modern_version = "2026-07-28";
pub const supported_versions = [_][]const u8{ modern_version, "2025-11-25" };
const legacy_versions = [_][]const u8{ "2025-11-25", "2025-06-18", "2025-03-26" };

const meta_version = "io.modelcontextprotocol/protocolVersion";
const meta_caps = "io.modelcontextprotocol/clientCapabilities";
const meta_server_info = "io.modelcontextprotocol/serverInfo";

pub const instructions =
    \\Zender builds, edits, renders and exports 3D scenes. Units: metres, Z up, angles in degrees, colours scene-linear 0..1.
    \\Start with scene.create and pass its scene_id to every other tool. Use render.preview to look at your work and scene.inspect for exact positions and bounds.
    \\Group related edits in scene.apply so they succeed or fail together; scene.undo reverts a step. Export with io.export (.glb or .gltf).
;

pub const ContentMode = enum {
    /// Summary line plus the structured result as JSON text (spec SHOULD).
    full,
    /// Summary line only; structuredContent carries the data.
    summary,
};

pub const Session = struct {
    server: *Server,
    /// Set by a legacy `initialize`; requests without `_meta` are then
    /// served under that version.
    legacy_version: ?[]const u8 = null,
    legacy_elicitation: bool = false,
    content: ContentMode = .full,

    /// Handles one JSON-RPC message. Returns the response line (without the
    /// newline) or null for notifications. `arena` owns the result.
    pub fn handle(s: *Session, arena: Allocator, line: []const u8) Allocator.Error!?[]const u8 {
        const msg = std.json.parseFromSliceLeaky(Value, arena, line, .{}) catch {
            return try errorResponse(arena, .null, -32700, "Parse error", null);
        };
        if (msg != .object) return try errorResponse(arena, .null, -32600, "Invalid Request: expected a JSON-RPC object (batches are not supported)", null);
        const obj = msg.object;
        const id: ?Value = obj.get("id");
        const method_v = obj.get("method") orelse {
            // A response from the client; servers send no requests, so ignore.
            return null;
        };
        const rpc = obj.get("jsonrpc");
        if (method_v != .string or rpc == null or rpc.? != .string or !std.mem.eql(u8, rpc.?.string, "2.0")) {
            return try errorResponse(arena, id orelse .null, -32600, "Invalid Request", null);
        }
        const method = method_v.string;
        const params: Value = obj.get("params") orelse .{ .object = .empty };
        if (id == null) {
            // Notifications: initialized, cancelled. Calls run synchronously,
            // so there is nothing in flight to cancel.
            return null;
        }
        return try s.request(arena, id.?, method, params);
    }

    fn request(s: *Session, arena: Allocator, id: Value, method: []const u8, params: Value) Allocator.Error![]const u8 {
        if (params != .object) return errorResponse(arena, id, -32602, "params must be an object", null);

        if (std.mem.eql(u8, method, "initialize")) return s.initialize(arena, id, params);
        if (std.mem.eql(u8, method, "ping")) return resultRaw(arena, id, "{}");

        // Modern requests declare their version; legacy sessions may omit it.
        const meta: ?Value = params.object.get("_meta");
        var elicitation = s.legacy_elicitation;
        const version: ?[]const u8 = if (meta) |m| if (m == .object) if (m.object.get(meta_version)) |v| if (v == .string) v.string else null else null else null else null;
        if (version) |v| {
            var ok = false;
            for (supported_versions) |sv| if (std.mem.eql(u8, sv, v)) {
                ok = true;
            };
            if (!ok) return unsupportedVersion(arena, id, v);
            const caps = meta.?.object.get(meta_caps) orelse
                return errorResponse(arena, id, -32602, "Invalid params: _meta is missing io.modelcontextprotocol/clientCapabilities", null);
            elicitation = caps == .object and caps.object.get("elicitation") != null;
        } else if (s.legacy_version == null and !std.mem.eql(u8, method, "server/discover")) {
            return errorResponse(arena, id, -32602, "Invalid params: _meta is missing io.modelcontextprotocol/protocolVersion (this server speaks MCP 2026-07-28, or 2025-11-25 after initialize)", null);
        }
        const modern = version != null;

        if (std.mem.eql(u8, method, "server/discover")) return s.discover(arena, id);
        if (std.mem.eql(u8, method, "tools/list")) return s.toolsList(arena, id, modern);
        if (std.mem.eql(u8, method, "tools/call")) return s.toolsCall(arena, id, params, modern, elicitation);
        if (std.mem.eql(u8, method, "resources/list")) return s.resourcesList(arena, id, modern);
        if (std.mem.eql(u8, method, "resources/templates/list")) return s.templatesList(arena, id, modern);
        if (std.mem.eql(u8, method, "resources/read")) return s.resourcesRead(arena, id, params, modern);
        if (std.mem.eql(u8, method, "prompts/list")) return s.promptsList(arena, id, modern);
        if (std.mem.eql(u8, method, "prompts/get")) return s.promptsGet(arena, id, params, modern);
        return errorResponse(arena, id, -32601, try std.fmt.allocPrint(arena, "Method not found: {s}", .{method}), null);
    }

    fn initialize(s: *Session, arena: Allocator, id: Value, params: Value) Allocator.Error![]const u8 {
        const requested: []const u8 = if (params.object.get("protocolVersion")) |v| if (v == .string) v.string else "" else "";
        var chosen: []const u8 = legacy_versions[0];
        for (legacy_versions) |lv| if (std.mem.eql(u8, lv, requested)) {
            chosen = lv;
        };
        s.legacy_version = chosen;
        if (params.object.get("capabilities")) |caps| {
            s.legacy_elicitation = caps == .object and caps.object.get("elicitation") != null;
        }
        var out: std.Io.Writer.Allocating = .init(arena);
        var w: Stringify = .{ .writer = &out.writer };
        writeInitialize(&w, id, chosen) catch return error.OutOfMemory;
        return out.written();
    }

    fn discover(s: *Session, arena: Allocator, id: Value) Allocator.Error![]const u8 {
        _ = s;
        var out: std.Io.Writer.Allocating = .init(arena);
        var w: Stringify = .{ .writer = &out.writer };
        writeDiscover(&w, id) catch return error.OutOfMemory;
        return out.written();
    }

    fn toolsList(s: *Session, arena: Allocator, id: Value, modern: bool) Allocator.Error![]const u8 {
        const srv = s.server;
        if (srv.tools_json == null) {
            var out: std.Io.Writer.Allocating = .init(srv.gpa);
            errdefer out.deinit();
            var w: Stringify = .{ .writer = &out.writer };
            writeTools(&w, srv.tools) catch return error.OutOfMemory;
            srv.tools_json = try out.toOwnedSlice();
        }
        var out: std.Io.Writer.Allocating = .init(arena);
        var w: Stringify = .{ .writer = &out.writer };
        writeResultWith(&w, id, modern, struct {
            json: []const u8,
            fn body(ctx: @This(), wr: *Stringify) Stringify.Error!void {
                try wr.objectField("tools");
                try wr.beginWriteRaw();
                try wr.writer.writeAll(ctx.json);
                wr.endWriteRaw();
                try wr.objectField("ttlMs");
                try wr.write(3600000);
                try wr.objectField("cacheScope");
                try wr.write("public");
            }
        }{ .json = srv.tools_json.? }) catch return error.OutOfMemory;
        return out.written();
    }

    fn toolsCall(s: *Session, arena: Allocator, id: Value, params: Value, modern: bool, elicitation: bool) Allocator.Error![]const u8 {
        const name_v = params.object.get("name") orelse return errorResponse(arena, id, -32602, "Invalid params: tools/call needs a tool name", null);
        if (name_v != .string) return errorResponse(arena, id, -32602, "Invalid params: name must be a string", null);
        var args: ?Value = params.object.get("arguments");

        // MRTR retry carrying the user's confirmation.
        if (params.object.get("inputResponses")) |ir| if (ir == .object) if (ir.object.get("confirm")) |resp| {
            const accepted = resp == .object and resp.object.get("action") != null and resp.object.get("action").? == .string and
                std.mem.eql(u8, resp.object.get("action").?.string, "accept");
            const content_ok = accepted and resp.object.get("content") != null and resp.object.get("content").? == .object and
                (resp.object.get("content").?.object.get("confirm") orelse Value{ .bool = false }) == .bool and
                resp.object.get("content").?.object.get("confirm").?.bool;
            if (!content_ok) {
                return toolErrorResponse(arena, id, modern, .{ .code = .confirmation_required, .message = "the user did not confirm; nothing was changed" });
            }
            var a: std.json.ObjectMap = if (args) |x| if (x == .object) try x.object.clone(arena) else .empty else .empty;
            try a.put(arena, "confirm", .{ .bool = true });
            args = .{ .object = a };
        };

        const outcome = try s.server.call(arena, name_v.string, args);
        switch (outcome) {
            .unknown_tool => return errorResponse(arena, id, -32602, try std.fmt.allocPrint(arena, "Unknown tool: {s}", .{name_v.string}), null),
            .tool_error => |te| {
                if (te.code == .confirmation_required and elicitation and modern) {
                    return inputRequired(arena, id, te.message);
                }
                return toolErrorResponse(arena, id, modern, te);
            },
            .ok => |ok| {
                var out: std.Io.Writer.Allocating = .init(arena);
                var w: Stringify = .{ .writer = &out.writer };
                writeResultWith(&w, id, modern, CallBody{ .ok = ok, .mode = s.content }) catch return error.OutOfMemory;
                return out.written();
            },
        }
    }

    fn resourcesList(s: *Session, arena: Allocator, id: Value, modern: bool) Allocator.Error![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        var w: Stringify = .{ .writer = &out.writer };
        writeResultWith(&w, id, modern, ResourceList{ .server = s.server, .arena = arena }) catch return error.OutOfMemory;
        return out.written();
    }

    fn templatesList(s: *Session, arena: Allocator, id: Value, modern: bool) Allocator.Error![]const u8 {
        _ = s;
        var out: std.Io.Writer.Allocating = .init(arena);
        var w: Stringify = .{ .writer = &out.writer };
        writeResultWith(&w, id, modern, struct {
            fn body(_: @This(), wr: *Stringify) Stringify.Error!void {
                const T = struct { uri: []const u8, name: []const u8, desc: []const u8, mime: []const u8 };
                const list = [_]T{
                    .{ .uri = "zender://scene/{scene_id}/outline", .name = "Scene outline", .desc = "Objects with type, transform and bounds", .mime = "application/json" },
                    .{ .uri = "zender://scene/{scene_id}/object/{name}", .name = "Object", .desc = "Full properties of one object", .mime = "application/json" },
                    .{ .uri = "zender://scene/{scene_id}/render/{job_id}", .name = "Render", .desc = "Full-resolution PNG of a render.preview result", .mime = "image/png" },
                    .{ .uri = "zender://scene/{scene_id}/log", .name = "Command log", .desc = "Replayable JSONL log of every change", .mime = "application/x-ndjson" },
                    .{ .uri = "zender://docs/{topic}", .name = "Docs", .desc = "Reference: conventions, or properties of object, camera, light, material, world, scene", .mime = "text/markdown" },
                };
                try wr.objectField("resourceTemplates");
                try wr.beginArray();
                for (list) |t| {
                    try wr.beginObject();
                    try wr.objectField("uriTemplate");
                    try wr.write(t.uri);
                    try wr.objectField("name");
                    try wr.write(t.name);
                    try wr.objectField("description");
                    try wr.write(t.desc);
                    try wr.objectField("mimeType");
                    try wr.write(t.mime);
                    try wr.endObject();
                }
                try wr.endArray();
                try wr.objectField("ttlMs");
                try wr.write(86400000);
                try wr.objectField("cacheScope");
                try wr.write("public");
            }
        }{}) catch return error.OutOfMemory;
        return out.written();
    }

    fn resourcesRead(s: *Session, arena: Allocator, id: Value, params: Value, modern: bool) Allocator.Error![]const u8 {
        const uri_v = params.object.get("uri") orelse return errorResponse(arena, id, -32602, "Invalid params: resources/read needs a uri", null);
        if (uri_v != .string) return errorResponse(arena, id, -32602, "Invalid params: uri must be a string", null);
        const uri = uri_v.string;
        const content = (try readResource(s.server, arena, uri)) orelse {
            return errorResponse(arena, id, -32602, try std.fmt.allocPrint(arena, "Resource not found: {s}", .{uri}), uri);
        };
        var out: std.Io.Writer.Allocating = .init(arena);
        var w: Stringify = .{ .writer = &out.writer };
        writeResultWith(&w, id, modern, ReadBody{ .uri = uri, .c = content }) catch return error.OutOfMemory;
        return out.written();
    }

    fn promptsList(s: *Session, arena: Allocator, id: Value, modern: bool) Allocator.Error![]const u8 {
        _ = s;
        var out: std.Io.Writer.Allocating = .init(arena);
        var w: Stringify = .{ .writer = &out.writer };
        writeResultWith(&w, id, modern, struct {
            fn body(_: @This(), wr: *Stringify) Stringify.Error!void {
                try wr.objectField("prompts");
                try wr.beginArray();
                for (prompts) |p| {
                    try wr.beginObject();
                    try wr.objectField("name");
                    try wr.write(p.name);
                    try wr.objectField("description");
                    try wr.write(p.description);
                    try wr.objectField("arguments");
                    try wr.beginArray();
                    for (p.args) |a| {
                        try wr.beginObject();
                        try wr.objectField("name");
                        try wr.write(a.name);
                        try wr.objectField("description");
                        try wr.write(a.description);
                        try wr.objectField("required");
                        try wr.write(a.required);
                        try wr.endObject();
                    }
                    try wr.endArray();
                    try wr.endObject();
                }
                try wr.endArray();
                try wr.objectField("ttlMs");
                try wr.write(86400000);
                try wr.objectField("cacheScope");
                try wr.write("public");
            }
        }{}) catch return error.OutOfMemory;
        return out.written();
    }

    fn promptsGet(s: *Session, arena: Allocator, id: Value, params: Value, modern: bool) Allocator.Error![]const u8 {
        _ = s;
        const name = params.object.get("name") orelse return errorResponse(arena, id, -32602, "Invalid params: prompts/get needs a name", null);
        if (name != .string) return errorResponse(arena, id, -32602, "Invalid params: name must be a string", null);
        const p = for (prompts) |p| {
            if (std.mem.eql(u8, p.name, name.string)) break p;
        } else return errorResponse(arena, id, -32602, try std.fmt.allocPrint(arena, "Unknown prompt: {s}", .{name.string}), null);
        const args: ?std.json.ObjectMap = if (params.object.get("arguments")) |a| if (a == .object) a.object else null else null;
        var text: std.Io.Writer.Allocating = .init(arena);
        // Fill {arg} placeholders.
        var i: usize = 0;
        while (i < p.template.len) {
            if (p.template[i] == '{') {
                if (std.mem.indexOfScalarPos(u8, p.template, i, '}')) |end| {
                    const key = p.template[i + 1 .. end];
                    const val: []const u8 = if (args) |a| if (a.get(key)) |v| if (v == .string) v.string else "" else "" else "";
                    text.writer.writeAll(if (val.len > 0) val else "(not given)") catch return error.OutOfMemory;
                    i = end + 1;
                    continue;
                }
            }
            text.writer.writeByte(p.template[i]) catch return error.OutOfMemory;
            i += 1;
        }
        var out: std.Io.Writer.Allocating = .init(arena);
        var w: Stringify = .{ .writer = &out.writer };
        writeResultWith(&w, id, modern, struct {
            desc: []const u8,
            text: []const u8,
            fn body(ctx: @This(), wr: *Stringify) Stringify.Error!void {
                try wr.objectField("description");
                try wr.write(ctx.desc);
                try wr.objectField("messages");
                try wr.beginArray();
                try wr.beginObject();
                try wr.objectField("role");
                try wr.write("user");
                try wr.objectField("content");
                try wr.beginObject();
                try wr.objectField("type");
                try wr.write("text");
                try wr.objectField("text");
                try wr.write(ctx.text);
                try wr.endObject();
                try wr.endObject();
                try wr.endArray();
            }
        }{ .desc = p.description, .text = text.written() }) catch return error.OutOfMemory;
        return out.written();
    }
};

const PromptArg = struct { name: []const u8, description: []const u8, required: bool };
const Prompt = struct { name: []const u8, description: []const u8, args: []const PromptArg, template: []const u8 };

const prompts = [_]Prompt{
    .{
        .name = "build_scene_from_description",
        .description = "Build a 3D scene from a natural-language description, checking it with previews",
        .args = &.{
            .{ .name = "description", .description = "What the scene should contain", .required = true },
            .{ .name = "output", .description = "Optional .glb path to export to", .required = false },
        },
        .template =
        \\Build this 3D scene with the Zender tools: {description}
        \\
        \\Work in metres with Z up; a table top is about 0.75 m high and a door 2 m. Create the scene with scene.create, block out large shapes first with object.add_primitive (group related edits in scene.apply), then add materials, a camera (camera.frame_objects frames everything) and lights.
        \\After each group of changes call render.preview and compare the image with the description; fix what looks wrong before moving on. Finish with scene.validate, then export with io.export if an output path was given: {output}
        ,
    },
    .{
        .name = "product_shot",
        .description = "Set up a clean studio shot of an object: backdrop, three-point lighting, framed camera",
        .args = &.{
            .{ .name = "scene_id", .description = "Scene that holds the object", .required = true },
            .{ .name = "object", .description = "Object to feature", .required = true },
        },
        .template =
        \\In scene {scene_id}, make a studio product shot of '{object}'.
        \\Read its bounds with scene.inspect. Add a large plane under it as a floor and backdrop, a key area light (front-left, above), a fill (front-right, weaker) and a rim light (behind). Use a 50-85 mm camera, camera.look_at on the object and camera.frame_objects with margin 1.2.
        \\Check with render.preview and adjust until the object is well lit, centred and fills most of the frame.
        ,
    },
};

const CallBody = struct {
    ok: cmd.server.Success,
    mode: ContentMode,

    fn body(ctx: CallBody, w: *Stringify) Stringify.Error!void {
        try w.objectField("content");
        try w.beginArray();
        try textItem(w, ctx.ok.summary);
        if (ctx.mode == .full) try textItem(w, ctx.ok.structured);
        if (ctx.ok.image) |img| {
            try w.beginObject();
            try w.objectField("type");
            try w.write("image");
            try w.objectField("data");
            try w.beginWriteRaw();
            try w.writer.writeByte('"');
            try std.base64.standard.Encoder.encodeWriter(w.writer, img.bytes);
            try w.writer.writeByte('"');
            w.endWriteRaw();
            try w.objectField("mimeType");
            try w.write(img.mime);
            try w.endObject();
        }
        for (ctx.ok.links) |l| {
            try w.beginObject();
            try w.objectField("type");
            try w.write("resource_link");
            try w.objectField("uri");
            try w.write(l.uri);
            try w.objectField("name");
            try w.write(l.name);
            try w.objectField("mimeType");
            try w.write(l.mime);
            try w.endObject();
        }
        try w.endArray();
        try w.objectField("structuredContent");
        try w.beginWriteRaw();
        try w.writer.writeAll(ctx.ok.structured);
        w.endWriteRaw();
        try w.objectField("isError");
        try w.write(false);
    }
};

fn textItem(w: *Stringify, text: []const u8) Stringify.Error!void {
    try w.beginObject();
    try w.objectField("type");
    try w.write("text");
    try w.objectField("text");
    try w.write(text);
    try w.endObject();
}

const ResourceList = struct {
    server: *Server,
    arena: Allocator,

    fn body(ctx: ResourceList, w: *Stringify) Stringify.Error!void {
        try w.objectField("resources");
        try w.beginArray();
        try resource(w, "zender://scenes", "Open scenes", "application/json");
        for (ctx.server.scenes.values()) |e| {
            var buf: [128]u8 = undefined;
            try resource(w, std.fmt.bufPrint(&buf, "zender://scene/{s}/outline", .{e.id}) catch unreachable, "Scene outline", "application/json");
            try resource(w, std.fmt.bufPrint(&buf, "zender://scene/{s}/log", .{e.id}) catch unreachable, "Command log", "application/x-ndjson");
            for (e.renders.items) |r| {
                try resource(w, std.fmt.bufPrint(&buf, "zender://scene/{s}/render/{d}", .{ e.id, r.job }) catch unreachable, "Render", "image/png");
            }
        }
        try w.endArray();
        try w.objectField("ttlMs");
        try w.write(0);
        try w.objectField("cacheScope");
        try w.write("private");
    }

    fn resource(w: *Stringify, uri: []const u8, name: []const u8, mime: []const u8) Stringify.Error!void {
        try w.beginObject();
        try w.objectField("uri");
        try w.write(uri);
        try w.objectField("name");
        try w.write(name);
        try w.objectField("mimeType");
        try w.write(mime);
        try w.endObject();
    }
};

const Content = struct {
    mime: []const u8,
    text: ?[]const u8 = null,
    blob: ?[]const u8 = null,
    ttl_ms: u64 = 0,
    public: bool = false,
};

const ReadBody = struct {
    uri: []const u8,
    c: Content,

    fn body(ctx: ReadBody, w: *Stringify) Stringify.Error!void {
        try w.objectField("contents");
        try w.beginArray();
        try w.beginObject();
        try w.objectField("uri");
        try w.write(ctx.uri);
        try w.objectField("mimeType");
        try w.write(ctx.c.mime);
        if (ctx.c.text) |t| {
            try w.objectField("text");
            try w.write(t);
        }
        if (ctx.c.blob) |b| {
            try w.objectField("blob");
            try w.beginWriteRaw();
            try w.writer.writeByte('"');
            try std.base64.standard.Encoder.encodeWriter(w.writer, b);
            try w.writer.writeByte('"');
            w.endWriteRaw();
        }
        try w.endObject();
        try w.endArray();
        try w.objectField("ttlMs");
        try w.write(ctx.c.ttl_ms);
        try w.objectField("cacheScope");
        try w.write(if (ctx.c.public) "public" else "private");
    }
};

fn percentDecode(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                try out.append(arena, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(arena, s[i]);
    }
    return out.items;
}

/// Resolves a zender:// URI through the command core.
fn readResource(srv: *Server, arena: Allocator, uri: []const u8) Allocator.Error!?Content {
    const prefix = "zender://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const rest = uri[prefix.len..];
    if (std.mem.eql(u8, rest, "scenes")) {
        var out: std.Io.Writer.Allocating = .init(arena);
        var w: Stringify = .{ .writer = &out.writer };
        writeScenes(&w, srv) catch return error.OutOfMemory;
        return .{ .mime = "application/json", .text = out.written() };
    }
    if (std.mem.startsWith(u8, rest, "docs/")) {
        const topic = rest["docs/".len..];
        if (std.mem.eql(u8, topic, "conventions")) {
            return .{ .mime = "text/markdown", .text = instructions, .ttl_ms = 86400000, .public = true };
        }
        var args: std.json.ObjectMap = .empty;
        try args.put(arena, "type", .{ .string = topic });
        const out = try srv.call(arena, "schema.describe", .{ .object = args });
        return switch (out) {
            .ok => |ok| .{ .mime = "application/json", .text = ok.structured, .ttl_ms = 86400000, .public = true },
            else => null,
        };
    }
    if (!std.mem.startsWith(u8, rest, "scene/")) return null;
    const after = rest["scene/".len..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null;
    const scene_id = after[0..slash];
    const what = after[slash + 1 ..];
    const e = srv.scenes.get(scene_id) orelse return null;
    if (std.mem.eql(u8, what, "log")) {
        var out: std.ArrayList(u8) = .empty;
        for (e.log.items) |l| {
            try out.appendSlice(arena, l);
            try out.append(arena, '\n');
        }
        return .{ .mime = "application/x-ndjson", .text = out.items };
    }
    if (std.mem.startsWith(u8, what, "render/")) {
        const job = std.fmt.parseInt(u64, what["render/".len..], 10) catch return null;
        for (e.renders.items) |r| if (r.job == job) return .{ .mime = "image/png", .blob = r.png, .ttl_ms = 3600000 };
        return null;
    }
    var args: std.json.ObjectMap = .empty;
    try args.put(arena, "scene_id", .{ .string = scene_id });
    if (std.mem.eql(u8, what, "outline")) {
        // Use the inspect tool so the front end holds no scene logic.
    } else if (std.mem.startsWith(u8, what, "object/")) {
        try args.put(arena, "object", .{ .string = try percentDecode(arena, what["object/".len..]) });
    } else return null;
    const out = try srv.call(arena, "scene.inspect", .{ .object = args });
    return switch (out) {
        .ok => |ok| .{ .mime = "application/json", .text = ok.structured },
        else => null,
    };
}

fn writeScenes(w: *Stringify, srv: *Server) Stringify.Error!void {
    try w.beginArray();
    for (srv.scenes.values()) |e| {
        try w.beginObject();
        try w.objectField("scene_id");
        try w.write(e.id);
        try w.objectField("name");
        try w.write(e.doc.db.getConst(.scene, e.doc.scene).?.name.slice());
        try w.objectField("scene_rev");
        try w.write(e.doc.rev);
        try w.objectField("dirty");
        try w.write(e.doc.dirty > 0);
        try w.objectField("objects");
        try w.write(e.doc.db.object.live);
        try w.endObject();
    }
    try w.endArray();
}

fn writeServerMeta(w: *Stringify) Stringify.Error!void {
    try w.objectField("_meta");
    try w.beginObject();
    try w.objectField(meta_server_info);
    try writeServerInfo(w);
    try w.endObject();
}

fn writeServerInfo(w: *Stringify) Stringify.Error!void {
    try w.beginObject();
    try w.objectField("name");
    try w.write("zender");
    try w.objectField("title");
    try w.write("Zender 3D engine");
    try w.objectField("version");
    try w.write(cmd.version);
    try w.endObject();
}

fn writeCapabilities(w: *Stringify) Stringify.Error!void {
    try w.beginObject();
    try w.objectField("tools");
    try w.beginObject();
    try w.objectField("listChanged");
    try w.write(false);
    try w.endObject();
    try w.objectField("resources");
    try w.beginObject();
    try w.endObject();
    try w.objectField("prompts");
    try w.beginObject();
    try w.endObject();
    try w.endObject();
}

fn writeDiscover(w: *Stringify, id: Value) Stringify.Error!void {
    try w.beginObject();
    try w.objectField("jsonrpc");
    try w.write("2.0");
    try w.objectField("id");
    try w.write(id);
    try w.objectField("result");
    try w.beginObject();
    try w.objectField("resultType");
    try w.write("complete");
    try w.objectField("supportedVersions");
    try w.write(supported_versions);
    try w.objectField("capabilities");
    try writeCapabilities(w);
    try w.objectField("instructions");
    try w.write(instructions);
    try w.objectField("ttlMs");
    try w.write(3600000);
    try w.objectField("cacheScope");
    try w.write("public");
    try writeServerMeta(w);
    try w.endObject();
    try w.endObject();
}

fn writeInitialize(w: *Stringify, id: Value, version: []const u8) Stringify.Error!void {
    try w.beginObject();
    try w.objectField("jsonrpc");
    try w.write("2.0");
    try w.objectField("id");
    try w.write(id);
    try w.objectField("result");
    try w.beginObject();
    try w.objectField("protocolVersion");
    try w.write(version);
    try w.objectField("capabilities");
    try writeCapabilities(w);
    try w.objectField("serverInfo");
    try writeServerInfo(w);
    try w.objectField("instructions");
    try w.write(instructions);
    try w.endObject();
    try w.endObject();
}

fn writeTools(w: *Stringify, tools: []const cmd.server.Tool) Stringify.Error!void {
    try w.beginArray();
    for (tools) |t| {
        try w.beginObject();
        try w.objectField("name");
        try w.write(t.name);
        try w.objectField("title");
        try w.write(t.title);
        try w.objectField("description");
        try w.write(t.description);
        try w.objectField("inputSchema");
        try cmd.schema.writeInputSchema(t.params, w);
        try w.objectField("annotations");
        try w.beginObject();
        try w.objectField("readOnlyHint");
        try w.write(t.kind == .read_only or t.kind == .global);
        try w.objectField("destructiveHint");
        try w.write(t.destructive);
        try w.objectField("idempotentHint");
        try w.write(t.idempotent);
        try w.objectField("openWorldHint");
        try w.write(t.open_world);
        try w.endObject();
        try w.endObject();
    }
    try w.endArray();
}

/// Writes {"jsonrpc","id","result":{resultType?, <body>, _meta?}}.
fn writeResultWith(w: *Stringify, id: Value, modern: bool, body: anytype) Stringify.Error!void {
    try w.beginObject();
    try w.objectField("jsonrpc");
    try w.write("2.0");
    try w.objectField("id");
    try w.write(id);
    try w.objectField("result");
    try w.beginObject();
    try w.objectField("resultType");
    try w.write("complete");
    try body.body(w);
    if (modern) try writeServerMeta(w);
    try w.endObject();
    try w.endObject();
}

fn resultRaw(arena: Allocator, id: Value, raw: []const u8) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var w: Stringify = .{ .writer = &out.writer };
    (struct {
        fn f(wr: *Stringify, i: Value, r: []const u8) Stringify.Error!void {
            try wr.beginObject();
            try wr.objectField("jsonrpc");
            try wr.write("2.0");
            try wr.objectField("id");
            try wr.write(i);
            try wr.objectField("result");
            try wr.beginWriteRaw();
            try wr.writer.writeAll(r);
            wr.endWriteRaw();
            try wr.endObject();
        }
    }).f(&w, id, raw) catch return error.OutOfMemory;
    return out.written();
}

pub fn errorResponse(arena: Allocator, id: Value, code: i64, message: []const u8, uri: ?[]const u8) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var w: Stringify = .{ .writer = &out.writer };
    (struct {
        fn f(wr: *Stringify, i: Value, c: i64, m: []const u8, u: ?[]const u8) Stringify.Error!void {
            try wr.beginObject();
            try wr.objectField("jsonrpc");
            try wr.write("2.0");
            try wr.objectField("id");
            try wr.write(i);
            try wr.objectField("error");
            try wr.beginObject();
            try wr.objectField("code");
            try wr.write(c);
            try wr.objectField("message");
            try wr.write(m);
            if (u) |x| {
                try wr.objectField("data");
                try wr.beginObject();
                try wr.objectField("uri");
                try wr.write(x);
                try wr.endObject();
            }
            try wr.endObject();
            try wr.endObject();
        }
    }).f(&w, id, code, message, uri) catch return error.OutOfMemory;
    return out.written();
}

fn unsupportedVersion(arena: Allocator, id: Value, requested: []const u8) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var w: Stringify = .{ .writer = &out.writer };
    (struct {
        fn f(wr: *Stringify, i: Value, r: []const u8) Stringify.Error!void {
            try wr.beginObject();
            try wr.objectField("jsonrpc");
            try wr.write("2.0");
            try wr.objectField("id");
            try wr.write(i);
            try wr.objectField("error");
            try wr.beginObject();
            try wr.objectField("code");
            try wr.write(-32022);
            try wr.objectField("message");
            try wr.write("Unsupported protocol version");
            try wr.objectField("data");
            try wr.beginObject();
            try wr.objectField("supported");
            try wr.write(supported_versions);
            try wr.objectField("requested");
            try wr.write(r);
            try wr.endObject();
            try wr.endObject();
            try wr.endObject();
        }
    }).f(&w, id, requested) catch return error.OutOfMemory;
    return out.written();
}

fn toolErrorResponse(arena: Allocator, id: Value, modern: bool, te: cmd.server.ToolError) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var w: Stringify = .{ .writer = &out.writer };
    const text = if (te.hint.len > 0)
        try std.fmt.allocPrint(arena, "Error ({s}): {s}. Hint: {s}", .{ @tagName(te.code), te.message, te.hint })
    else
        try std.fmt.allocPrint(arena, "Error ({s}): {s}", .{ @tagName(te.code), te.message });
    writeResultWith(&w, id, modern, struct {
        te: cmd.server.ToolError,
        text: []const u8,
        fn body(ctx: @This(), wr: *Stringify) Stringify.Error!void {
            try wr.objectField("content");
            try wr.beginArray();
            try textItem(wr, ctx.text);
            if (ctx.te.valid_values.len > 0) {
                var buf: [4096]u8 = undefined;
                var fw: std.Io.Writer = .fixed(&buf);
                fw.writeAll("valid_values: ") catch {};
                for (ctx.te.valid_values, 0..) |vv, k| {
                    if (k > 0) fw.writeAll(", ") catch break;
                    fw.writeAll(vv) catch break;
                }
                try textItem(wr, fw.buffered());
            }
            try wr.endArray();
            try wr.objectField("structuredContent");
            try wr.beginObject();
            try wr.objectField("error");
            try wr.beginObject();
            try wr.objectField("code");
            try wr.write(@tagName(ctx.te.code));
            try wr.objectField("message");
            try wr.write(ctx.te.message);
            try wr.objectField("path");
            try wr.write(ctx.te.path);
            try wr.objectField("hint");
            try wr.write(ctx.te.hint);
            if (ctx.te.valid_values.len > 0) {
                try wr.objectField("valid_values");
                try wr.write(ctx.te.valid_values);
            }
            try wr.endObject();
            try wr.endObject();
            try wr.objectField("isError");
            try wr.write(true);
        }
    }{ .te = te, .text = text }) catch return error.OutOfMemory;
    return out.written();
}

/// MRTR: ask the client to confirm a destructive call (FR-MCP-7).
fn inputRequired(arena: Allocator, id: Value, message: []const u8) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var w: Stringify = .{ .writer = &out.writer };
    (struct {
        fn f(wr: *Stringify, i: Value, m: []const u8) Stringify.Error!void {
            try wr.beginObject();
            try wr.objectField("jsonrpc");
            try wr.write("2.0");
            try wr.objectField("id");
            try wr.write(i);
            try wr.objectField("result");
            try wr.beginObject();
            try wr.objectField("resultType");
            try wr.write("input_required");
            try wr.objectField("inputRequests");
            try wr.beginObject();
            try wr.objectField("confirm");
            try wr.beginObject();
            try wr.objectField("method");
            try wr.write("elicitation/create");
            try wr.objectField("params");
            try wr.beginObject();
            try wr.objectField("mode");
            try wr.write("form");
            try wr.objectField("message");
            try wr.write(m);
            try wr.objectField("requestedSchema");
            try wr.beginObject();
            try wr.objectField("type");
            try wr.write("object");
            try wr.objectField("properties");
            try wr.beginObject();
            try wr.objectField("confirm");
            try wr.beginObject();
            try wr.objectField("type");
            try wr.write("boolean");
            try wr.objectField("title");
            try wr.write("Go ahead?");
            try wr.endObject();
            try wr.endObject();
            try wr.objectField("required");
            try wr.write(&[_][]const u8{"confirm"});
            try wr.endObject();
            try wr.endObject();
            try wr.endObject();
            try wr.endObject();
            try writeServerMeta(wr);
            try wr.endObject();
            try wr.endObject();
        }
    }).f(&w, id, message) catch return error.OutOfMemory;
    return out.written();
}
