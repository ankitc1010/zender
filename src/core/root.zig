//! Data model: IDs, datablocks, the database, the property registry,
//! transactions and undo.

pub const ids = @import("ids.zig");
pub const types = @import("types.zig");
pub const registry = @import("registry.zig");
pub const database = @import("database.zig");
pub const document = @import("document.zig");
pub const edit = @import("edit.zig");
pub const canonical = @import("canonical.zig");

pub const Shared = @import("shared.zig").Shared;
pub const IdType = ids.IdType;
pub const IdHandle = ids.IdHandle;
pub const Name = ids.Name;
pub const Database = database.Database;
pub const Document = document.Document;
pub const Transaction = document.Transaction;

test {
    _ = ids;
    _ = types;
    _ = registry;
    _ = database;
    _ = document;
    _ = edit;
    _ = canonical;
    _ = @import("shared.zig");
}
