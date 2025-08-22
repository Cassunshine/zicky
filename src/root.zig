const std = @import("std");

const World = @import("World.zig");

const Vec3 = @Vector(3, f32);

test "Test Basic ECS" {
    const Position = World.getComponentId("Position");
    const Velocity = World.getComponentId("Velocity");

    var world = try World.init(std.heap.smp_allocator);

    const entity = try world.createEntity();

    try world.addComponents(entity, .{
        .{ Position, Vec3{ 0, 15, 0 } },
        .{ Velocity, Vec3{ 20, 0, 5 } },
    });

    try world.addComponent(entity, Position, Vec3{ 0, 30, 0 });
    try world.addComponent(entity, Velocity, Vec3{ -10, 0, 0 });

    world.setComponent(entity, Position, Vec3{ 1, 1, 1 });

    world.setComponents(entity, .{
        .{ Position, Vec3{ 1000, 1000, 1000 } },
        .{ Velocity, Vec3{ 0, 0, 0 } },
    });

    var view = try world.getView(&.{ Velocity, Position });
    view.each(doThings);

    var iter = view.iterator();
    while (iter.next()) |entity| {
        _ = entity;
    }
}

fn doThings(vel: *Vec3, pos: *Vec3) void {
    _ = vel;
    _ = pos;
}
