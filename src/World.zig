//! Stores all the entities, archetypes, and components.
const World = @This();

// Imports
const std = @import("std");
const Allocator = std.mem.Allocator;

const Archetype = @import("Archetype.zig");

const View = @import("View.zig");

// Fields

/// The allocator used to allocate all the data in this world.
allocator: Allocator,

/// List of all archetypes, by their hash.
archetypes: std.AutoArrayHashMapUnmanaged(u64, Archetype) = .{},

/// Incremented to give each entity a unique ID.
entity_counter: EntityID = 0,

/// Map of external IDs -> internal indexes
entities: std.AutoHashMapUnmanaged(EntityID, EntityIndex) = .{},

empty_archetype_index: u16 = undefined,

// Methods

pub fn init(allocator: Allocator) !World {
    var world = World{
        .allocator = allocator,
    };

    try world.archetypes.ensureTotalCapacity(allocator, std.math.maxInt(u16));

    // Always explicitly create the empty archetype for the world.
    const emptyArchetype = try Archetype.initEmpty(allocator);
    const id = emptyArchetype.getId();
    try world.archetypes.put(allocator, id, emptyArchetype);
    world.empty_archetype_index = @intCast(world.archetypes.getIndex(id).?);

    return world;
}

pub fn deinit(self: *World) void {
    var iter = self.archetypes.iterator();
    while (iter.next()) |entry|
        entry.value_ptr.deinit();

    self.archetypes.deinit(self.allocator);
    self.entities.deinit(self.allocator);
}

// CREATE ENTITY //

/// Creates an empty entity.
pub fn createEntity(self: *World) !EntityID {
    const entity_id = self.entity_counter;
    self.entity_counter += 1;

    // Get empty archetype by default.
    var archetype = &self.archetypes.values()[self.empty_archetype_index];

    // Create new index pointing to archetype.
    const entity_index = EntityIndex{
        .archetype_index = self.empty_archetype_index,
        .entity_index = try archetype.addEntity(entity_id),
    };
    errdefer archetype.undoAdd();

    // Put entity in id -> index map.
    try self.entities.put(self.allocator, entity_id, entity_index);

    return entity_id;
}

/// Adds a new component, or overrides the value of an existing one.
/// Will move the entity to a new archetype, if needed.
pub fn addComponent(self: *World, entity_id: EntityID, component_id: u64, value: anytype) !void {
    try self.addComponents(entity_id, .{.{ component_id, value }});
}

// ADD COMPONENTS //

/// Adds multiple components at once, or overrides the value of existing ones.
/// Will move the entity to a new archetype, if needed.
///
/// The `components` variable should be a tuple where each entry is also a tuple of `{component_id, anytype}`, for the component's ID and value.
///
/// TODO - See if we can optimize this instead of calling setRaw a bunch of times. setRaw can be expensive when moving between lots of archetypes, or big archetypes
pub fn addComponents(self: *World, entity_id: EntityID, components: anytype) !void {
    // Find the entity's index and archetype.
    const entity_index = self.entities.getPtr(entity_id).?;
    var entity_archetype = &self.archetypes.values()[entity_index.archetype_index];

    // Find the indexes inside `components of all components not present in the existing archetype.
    var new_indexes = try std.ArrayList(u64).initCapacity(self.allocator, components.len);
    defer new_indexes.deinit();

    inline for (components, 0..) |component_tuple, i| {
        if (!entity_archetype.hasComponent(component_tuple[0]))
            new_indexes.appendAssumeCapacity(@intCast(i));
    }

    // If there are any new components, move to new archetype.
    if (new_indexes.items.len > 0) {
        // Generate new archetype
        const new_archetype_id = try entity_archetype.getIdWithComponents(new_indexes.items);
        var new_archetype: *Archetype = undefined;
        var new_archetype_index: u16 = undefined;

        if (self.archetypes.getPtr(new_archetype_id)) |found| {
            new_archetype = found;
            new_archetype_index = @intCast(self.archetypes.getIndex(new_archetype_id).?);
        } else {
            const tmp_arch = try entity_archetype.withComponentsSelected(new_indexes.items, components);
            const id = tmp_arch.getId();
            try self.archetypes.put(self.allocator, id, tmp_arch);

            new_archetype = self.archetypes.getPtr(id).?;
            new_archetype_index = @intCast(self.archetypes.getIndex(id).?);
        }

        // Reserve ID for entity in new archetype.
        const new_index = EntityIndex{
            .archetype_index = new_archetype_index,
            .entity_index = try new_archetype.addEntity(entity_id),
        };

        // Copy values from old archetype into new archetype.
        var iter = entity_archetype.component_storages.iterator();
        while (iter.next()) |entry| {
            var oldStorage = entry.value_ptr;
            const newStorage = new_archetype.component_storages.get(entry.key_ptr.*).?;

            oldStorage.copyTo(oldStorage, newStorage, entity_index.entity_index, new_index.entity_index);
        }

        // Remove from old archetype.
        entity_archetype.removeEntity(entity_index.entity_index);

        // Set values for entity.
        entity_index.* = new_index;
        entity_archetype = new_archetype;
    }

    // Set values on components
    inline for (components) |tuple| {
        entity_archetype.set(entity_index.entity_index, tuple[0], tuple[1]);
    }
}

// SET COMPONENTS //

/// Sets the value of a component.
/// Assumes the entity ID is valid, the component exists on that entity already, and that value is of the correct type.
pub fn setComponent(self: *World, entity_id: EntityID, component_id: u64, value: anytype) void {
    const entity_index = self.entities.getPtr(entity_id).?;
    const entity_archetype = &self.archetypes.values()[entity_index.archetype_index];

    entity_archetype.set(entity_index.entity_index, component_id, value);
}

/// Sets the value of multiple components.
/// Assumes the entity ID is valid, the components exists on that entity already, and that values are of the correct type.
///
/// The `components` variable should be a tuple where each entry is also a tuple of `{component_id, anytype}`, for the component's ID and value.
pub fn setComponents(self: *World, entity_id: EntityID, components: anytype) void {
    const entity_index = self.entities.getPtr(entity_id).?;
    const entity_archetype = &self.archetypes.values()[entity_index.archetype_index];

    inline for (components) |tuple| {
        entity_archetype.set(entity_index.entity_index, tuple[0], tuple[1]);
    }
}

// GET COMPONENTS //

pub fn getComponent(self: *World, entity_id: EntityID, component_id: u64, comptime T: type) ?T {
    const entity_index = self.entities.getPtr(entity_id).?;
    const entity_archetype = &self.archetypes.values()[entity_index.archetype_index];

    if (!entity_archetype.hasComponent(component_id))
        return null;

    return entity_archetype.get(entity_index.entity_index, component_id, T);
}

// VIEWS //

pub fn getView(self: *World, component_ids: []u64) !View {
    _ = self;
    _ = component_ids;
}

// OTHER //

/// Gets a pointer to a component.
/// Assumes the entity ID and component ID are correct.
/// Returns null if entity doesn't have that component.
pub fn getPtr(self: *World, entity_id: EntityID, component_id: u64, comptime T: type) ?*T {
    const entity_index = self.entities.getPtr(entity_id).?;
    const entity_archetype = &self.archetypes.values()[entity_index.archetype_index];

    if (!entity_archetype.hasComponent(component_id))
        return null;

    return entity_archetype.getPtr(entity_index.entity_index, component_id, T);
}

/// Canonical component ID for a string.
/// You can also use custom IDs if you want.
pub fn getComponentId(component_name: []const u8) u64 {
    return std.hash.Wyhash.hash(0, component_name);
}

// Nested

pub const EntityID = u64;

const EntityIndex = struct {
    archetype_index: u16,
    entity_index: u32,
};
