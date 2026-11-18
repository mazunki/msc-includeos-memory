const std = @import("std");

const posix = struct {
    extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) callconv(.c) ?*anyopaque;
    extern "c" fn munmap(addr: ?*anyopaque, len: usize) callconv(.c) c_int;
};
const PROT_READ: c_int = 1;
const PROT_WRITE: c_int = 2;
const MAP_PRIVATE: c_int = 0x02;
const MAP_ANONYMOUS: c_int = 0x20;
const MAP_FAILED: usize = std.math.maxInt(usize);

fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = context;
    _ = alignment;
    _ = ret_addr;
    const result = posix.mmap(null, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (@intFromPtr(result) == MAP_FAILED) return null;
    return @ptrCast(result);
}

fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = context;
    _ = alignment;
    _ = ret_addr;
    _ = posix.munmap(memory.ptr, memory.len);
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = free,
};

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &vtable,
};
