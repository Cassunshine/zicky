const std = @import("std");

const World = @import("World.zig");

const Vec3 = @Vector(3, f32);

test "Test Basic ECS" {
    const Position: u64 = World.getComponentId("Position");
    const Velocity: u64 = World.getComponentId("Velocity");

    var world = try World.init(std.heap.smp_allocator);

    const entity = try world.createEntity();

    try world.addComponents(entity, &.{ Position, Velocity }, .{ Vec3{ 0, 15, 0 }, Vec3{ 13, 0, 0 } });

    try world.addComponent(entity, Position, Vec3{ 0, 30, 0 });
    try world.addComponent(entity, Velocity, Vec3{ -10, 0, 0 });

    world.setComponent(entity, Position, Vec3{ 1, 1, 1 });
}
