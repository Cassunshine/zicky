//! Type-erased component stroage
const ComponentStorage = @This();

// Imports
const std = @import("std");
const Allocator = std.mem.Allocator;

// Fields

ptr: *anyopaque,

deinit: *const fn (self: *ComponentStorage, allocator: Allocator) void,
emptyCopy: *const fn (allocator: Allocator) Allocator.Error!ComponentStorage,

copyTo: *const fn (src: *ComponentStorage, dst: ComponentStorage, src_index: u32, dst_index: u32) void,
ensureSize: *const fn (self: *ComponentStorage, allocator: Allocator, max_entry: u32) Allocator.Error!void,

swapRemove: *const fn (self: *ComponentStorage, index: u32) void,

// Methods

pub fn create(allocator: Allocator, comptime T: type) !ComponentStorage {
    const typed = try allocator.create(TypedComponentStorage(T));
    typed.* = .{};

    const funcs = struct {
        pub fn deinit(self: *ComponentStorage, alloc: Allocator) void {
            self.toTyped(T).deinit(alloc);
        }
        pub fn emptyCopy(alloc: Allocator) Allocator.Error!ComponentStorage {
            return try create(alloc, T);
        }
        pub fn copyTo(src: *ComponentStorage, dst: ComponentStorage, src_index: u32, dst_index: u32) void {
            dst.toTyped(T).data.items[dst_index] = src.toTyped(T).data.items[src_index];
        }
        pub fn ensureSize(self: *ComponentStorage, alloc: Allocator, max_entry: u32) Allocator.Error!void {
            var typedData = &self.toTyped(T).data;

            if (max_entry + 1 > typedData.items.len)
                try typedData.resize(alloc, max_entry + 1);
        }
        pub fn swapRemove(self: *ComponentStorage, index: u32) void {
            _ = self.toTyped(T).data.swapRemove(index);
        }
    };

    return ComponentStorage{
        .ptr = typed,
        .deinit = funcs.deinit,
        .emptyCopy = funcs.emptyCopy,
        .copyTo = funcs.copyTo,
        .ensureSize = funcs.ensureSize,
        .swapRemove = funcs.swapRemove,
    };
}

pub fn toTyped(self: *const ComponentStorage, comptime T: type) *TypedComponentStorage(T) {
    return @ptrCast(@alignCast(self.ptr));
}

// Nested

pub fn TypedComponentStorage(comptime T: type) type {
    return struct {
        //!
        const Storage = @This();

        // Fields

        data: std.ArrayListUnmanaged(T) = .{},

        // Methods

        pub fn deinit(self: *Storage, allocator: Allocator) void {
            self.data.deinit(allocator);
        }
    };
}
