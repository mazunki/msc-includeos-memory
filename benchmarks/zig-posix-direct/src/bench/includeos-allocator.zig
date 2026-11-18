const std = @import("std");
const Allocator = std.mem.Allocator;

extern fn includeos_zig_alloc(len: usize, alignment: usize) ?[*]u8;
extern fn includeos_zig_free(ptr: [*]u8, len: usize, alignment: usize) void;

fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = context;
    _ = ret_addr;
    return includeos_zig_alloc(len, alignment.toByteUnits());
}

fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = context;
    _ = ret_addr;
    includeos_zig_free(memory.ptr, memory.len, alignment.toByteUnits());
}

const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = Allocator.noResize,
    .remap = Allocator.noRemap,
    .free = free,
};

pub const allocator: Allocator = .{
    .ptr = undefined,
    .vtable = &vtable,
};
