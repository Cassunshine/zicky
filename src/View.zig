//! The primary way to interact with the world and iterate over its entities.
const View = @This();

// Imports
const std = @import("std");
const Allocator = std.mem.Allocator;

const World = @import("World.zig");

// Fields

// Methods

/// Calls a function on each entity matching this view.
pub fn each(self: *View, func: anytype) void {
    const funcType = @TypeOf(func);

    _ = self;
    _ = funcType;
}

pub fn iterator(self: *View) Iterator {}

// Nested

pub const Iterator = struct {


    pub fn next() anytype {
        
    }
};
