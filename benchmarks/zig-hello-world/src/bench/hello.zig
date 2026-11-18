const std = @import("std");
const includeos_allocator = @import("includeos-allocator.zig");

export fn zig_add(a: i32, b: i32) callconv(.c) i32 {
    return a + b;
}

export fn zig_alloc_roundtrip() callconv(.c) i32 {
    const allocator = includeos_allocator.allocator;

    var buf = allocator.alloc(u32, 64) catch return -1;
    for (buf, 0..) |*slot, i| slot.* = @intCast(i * i);
    for (buf, 0..) |slot, i| {
        if (slot != i * i) {
            allocator.free(buf);
            return -2;
        }
    }

    const grown = allocator.realloc(buf, 256) catch {
        allocator.free(buf);
        return -3;
    };
    buf = grown;

    for (buf[0..64], 0..) |slot, i| {
        if (slot != i * i) {
            allocator.free(buf);
            return -4;
        }
    }

    allocator.free(buf);
    return 0;
}
