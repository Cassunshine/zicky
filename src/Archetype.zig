//!
const Archetype = @This();

// Imports
const std = @import("std");
const Allocator = std.mem.Allocator;

const ComponentStorage = @import("ComponentStorage.zig");

// Fields

/// The allocator this archetype will use, where all its data is stored, etc.
allocator: Allocator,

/// Sorted list of component IDs stored in this archetype.
component_ids: []u64,

/// Map of component ID -> component storage
component_storages: std.AutoArrayHashMapUnmanaged(u64, ComponentStorage) = .{},

/// Map of internal IDs -> global IDs
/// TODO - Why not just use a counter? These are never used anywhere....
entity_ids: std.ArrayListUnmanaged(u64) = .{},

// Methods

/// Initializes an empty archetype with no components contained in it.
pub fn initEmpty(allocator: Allocator) !Archetype {
    const archetype = Archetype{
        .allocator = allocator,
        .component_ids = try allocator.alloc(u64, 0),
    };

    return archetype;
}

/// Creates a copy of this archetype, but without any storage duplicated.
/// That is, the new archetype will match exactly, but be empty of any entities.
fn shallowDupe(self: *Archetype) !Archetype {
    // Duplicate the archetype itself.
    var archetype = Archetype{
        .allocator = self.allocator,
        .component_ids = self.component_ids,
    };

    // Iterate self's storages
    var iter = self.component_storages.iterator();
    while (iter.next()) |entry| {
        // Create a new storage that matches the type, but is empty.
        const newComponent = try entry.value_ptr.emptyCopy(archetype.allocator);
        // Put it in the new storage at the same ID.
        try archetype.component_storages.put(self.allocator, entry.key_ptr.*, newComponent);
    }

    return archetype;
}

/// Initializes a new archetype except with the given components present.
/// Calling this with ids that already exist in the archetype is undefined behaviour.
pub fn withComponents(self: *Archetype, comptime types: []type, ids: [types.len]u64) !Archetype {
    // Create shallow copy of self to start with.
    var archetype = try self.shallowDupe();
    errdefer archetype.deinit();

    // Concat old IDs with new IDs, then sort them.
    const newIds = try std.mem.concat(archetype.allocator, u64, &.{ archetype.component_ids, ids });
    archetype.allocator.free(archetype.component_ids);
    archetype.component_ids = newIds;

    std.mem.sort(u64, archetype.component_ids, {}, std.sort.asc(u64));

    // Create new components with the new types
    inline for (0..types.len) |i| {
        const t = types[i];
        const id = ids[i];

        try archetype.component_storages.put(id, self.allocator, try ComponentStorage.create(archetype.allocator, t));
    }

    return archetype;
}

/// Same as withComponents, but instead adds only the types at the indexes present in a given slice.
pub fn withComponentsSelected(self: *Archetype, ids: []const u64, selected: []const u64, values: anytype) !Archetype {
    // Create shallow copy of self to start with.
    var archetype = try self.shallowDupe();
    errdefer archetype.deinit();

    // Generate list of selected component IDs.
    const selected_ids = try self.allocator.alloc(u64, selected.len);
    {
        var index: usize = 0;
        // Iterate all ids.
        for (0..ids.len) |i| {
            for (selected) |s| {
                // If index isn't a selected index, ignore it.
                if (i != s)
                    continue;

                // If index IS selected, record it, then move to the next index.
                selected_ids[index] = ids[i];
                index += 1;
                break;
            }
        }
    }

    // Concat old IDs with new IDs, then sort them.
    const ids_concat = try std.mem.concat(archetype.allocator, u64, &.{ archetype.component_ids, selected_ids });
    archetype.allocator.free(archetype.component_ids);
    archetype.component_ids = ids_concat;

    std.mem.sort(u64, archetype.component_ids, {}, std.sort.asc(u64));

    // Create new components with the selected new types.
    inline for (0..values.len) |i| {
        const t = @TypeOf(values[i]);
        const id = ids[i];

        for (0..selected.len) |s| {
            // If index isn't selected, ignore it.
            if (s != i)
                continue;

            // If index IS selected, add new component to this archetype.
            try archetype.component_storages.put(self.allocator, id, try ComponentStorage.create(archetype.allocator, t));
            break;
        }
    }

    return archetype;
}

/// Initializes a new archetype based on this one, except with the given components removed.
pub fn withoutComponents(self: *Archetype, removed_ids: []u64) !Archetype {
    // Create shallow copy of self to start with
    var archetype = try self.shallowDupe();
    errdefer archetype.deinit();

    // Create a temporary list for easier use
    var tmp_newIds = std.ArrayListUnmanaged(u64){};
    try tmp_newIds.appendSlice(archetype.allocator, archetype.component_ids);
    defer tmp_newIds.deinit(archetype.allocator);

    // Iterate over old archetype components
    for (0..self.component_ids.len) |old_index| {
        const old_id = self.component_ids[old_index];
        for (removed_ids) |removed_id| {
            if (old_id != removed_id)
                continue;

            //If removed ID is found, remove it from the new archetype.
            if (archetype.component_storages.fetchSwapRemove(removed_id)) |storage|
                storage.value.deinit(storage.value, archetype.allocator);

            // Remove from IDs.
            tmp_newIds.orderedRemove(old_index);

            break;
        }
    }

    // Convert temp IDs into new IDs
    archetype.allocator.free(archetype.component_ids);
    archetype.component_ids = try tmp_newIds.toOwnedSlice();
}

pub fn deinit(self: *Archetype) void {

    // Deinit each component storage
    var iter = self.component_storages.iterator();
    while (iter.next()) |entry| {
        entry.value_ptr.deinit(entry.value_ptr, self.allocator);
    }

    // Deinit IDs and component map
    self.allocator.free(self.component_ids);
    self.component_storages.deinit(self.allocator);
}

/// Checks if the archetype contains a component by ID.
pub fn hasComponent(self: *Archetype, id: u64) bool {
    return self.component_storages.contains(id);
}

/// Checks if the archetype contains all of the component IDs in a set.
pub fn hasComponents(self: *Archetype, ids: []u64) bool {
    for (ids) |id|
        if (!self.hasComponent(id))
            return false;
    return true;
}

/// Creates a new entity and returns its index.
/// Also ensures that every component storage is capable of holding the new entity.
pub fn addEntity(self: *Archetype, entity_id: u64) !u32 {
    // Add ID to ID list.
    const new_id = self.entity_ids.items.len;
    try self.entity_ids.append(self.allocator, entity_id);
    errdefer _ = self.entity_ids.pop();

    // Ensure all component storages have entries for the new entity.
    var iter = self.component_storages.iterator();
    while (iter.next()) |entry|
        try entry.value_ptr.ensureSize(entry.value_ptr, self.allocator, @intCast(new_id));

    return @intCast(new_id);
}

pub fn undoAdd(self: *Archetype) void {
    _ = self.entity_ids.pop();
}

/// Removes an entity from the archetype. The used index will now be used by something else.
pub fn removeEntity(self: *Archetype, destroyed_index: u32) void {
    _ = self.entity_ids.swapRemove(destroyed_index);

    // swapremove entity from every component storage
    var iter = self.component_storages.iterator();
    while (iter.next()) |entry|
        entry.value_ptr.swapRemove(entry.value_ptr, destroyed_index);
}

/// Sets the data in a component for a specified entity.
/// Assumes the entity ID and component ID is valid.
pub fn set(self: *Archetype, entity_id: u32, component_id: u64, value: anytype) void {
    self.getPtr(entity_id, component_id, @TypeOf(value)).* = value;
}

/// Gets the data in a component for a specific entity.
/// Assumes the entity ID and component ID are valid.
pub fn get(self: *Archetype, entity_id: u32, component_id: u64, comptime T: type) T {
    const storage = self.component_storages.get(component_id).?.toTyped(T);
    return storage.data.items[entity_id];
}

/// Gets a pointer to the data for some entity's component.
/// Assumes the entity ID and component are valid.
/// This pointer will be invalidated when adding new entities.
pub fn getPtr(self: *Archetype, entity_id: u32, component_id: u64, comptime T: type) *T {
    const storage = self.component_storages.get(component_id).?.toTyped(T);
    return &storage.data.items[entity_id];
}

/// Gets the ID of this archetype.
pub fn getId(self: *const Archetype) u64 {
    return componentIdsToArchetypeID(self.component_ids);
}

/// Gets the ID for this archetype, if it had the given components present as well.
/// Assumes the new IDs are unique.
pub fn getIdWithComponents(self: *Archetype, ids: []u64) !u64 {
    // Concat old IDs with new IDs, then sort them.
    const newIds = try std.mem.concat(self.allocator, u64, &.{ self.component_ids, ids });
    self.allocator.free(self.component_ids);
    std.mem.sort(u64, newIds, {}, std.sort.asc(u64));

    return componentIdsToArchetypeID(newIds);
}

/// Turns a list of component IDs into an archetype ID.
/// Assumes list is sorted.
pub fn componentIdsToArchetypeID(ids: []u64) u64 {
    var hash = std.hash.Wyhash.init(0);

    for (ids) |*id|
        hash.update(std.mem.asBytes(id));

    return hash.final();
}
