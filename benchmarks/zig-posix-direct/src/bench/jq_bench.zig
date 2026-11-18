const std = @import("std");
const Jq = @import("jq/root.zig");
const tsc = @import("tsc.zig");
const posix_allocator = @import("posix-allocator.zig");
const includeos_allocator = @import("includeos-allocator.zig");

const string_count = 1_000;
const out = includeos_allocator.allocator;

const Temp = struct {
    arena: std.heap.ArenaAllocator,

    fn init(self: *Temp, child: std.mem.Allocator) void {
        self.arena = .init(child);
    }

    fn deinit(self: *Temp) void {
        self.arena.deinit();
    }

    fn allocator(self: *Temp) std.mem.Allocator {
        return self.arena.allocator();
    }

    // frees everything allocated since init
    fn teardown(self: *Temp) u64 {
        const start = tsc.start();
        _ = self.arena.reset(.free_all);
        return tsc.end() - start;
    }
};

const CountResult = struct { apply_avg: f64, alloc_avg: f64, reset_cycles: f64 };
const SizeResult = struct { apply_avg: f64, byte_avg: f64, reset_cycles: f64 };

fn benchCountImpl(child: std.mem.Allocator, n: usize, iterations: usize) !CountResult {
    var gen_arena: std.heap.ArenaAllocator = .init(out);
    defer gen_arena.deinit();
    const json_text = try buildNumberArrayJson(gen_arena.allocator(), n);

    var parse_arena: std.heap.ArenaAllocator = .init(out);
    defer parse_arena.deinit();
    const value = try Jq.parser.parse(out, parse_arena.allocator(), json_text);
    defer value.deinit(out);

    var query_arena: std.heap.ArenaAllocator = .init(out);
    defer query_arena.deinit();
    const q = try Jq.query.parse(query_arena.allocator(), "map(tostring)");

    var temp_backing: Temp = undefined;
    temp_backing.init(child);
    defer temp_backing.deinit();
    const temp = temp_backing.allocator();

    const start = tsc.start();
    for (0..iterations) |_| {
        const stream = try Jq.query.apply(out, temp, q, value);
        for (stream) |v| v.deinit(out);
        out.free(stream);
    }
    const apply_cycles = tsc.end() - start;
    const reset_cycles = temp_backing.teardown();

    return .{
        .apply_avg = avg(apply_cycles, iterations),
        .alloc_avg = avg(apply_cycles, iterations * n),
        .reset_cycles = @floatFromInt(reset_cycles),
    };
}

fn benchSizeImpl(child: std.mem.Allocator, len: usize, iterations: usize) !SizeResult {
    var gen_arena: std.heap.ArenaAllocator = .init(out);
    defer gen_arena.deinit();
    const json_text = try buildStringArrayJson(gen_arena.allocator(), string_count, len);

    var parse_arena: std.heap.ArenaAllocator = .init(out);
    defer parse_arena.deinit();
    const value = try Jq.parser.parse(out, parse_arena.allocator(), json_text);
    defer value.deinit(out);

    var query_arena: std.heap.ArenaAllocator = .init(out);
    defer query_arena.deinit();
    const q = try Jq.query.parse(query_arena.allocator(), "join(\",\")");

    var temp_backing: Temp = undefined;
    temp_backing.init(child);
    defer temp_backing.deinit();
    const temp = temp_backing.allocator();

    const start = tsc.start();
    for (0..iterations) |_| {
        const stream = try Jq.query.apply(out, temp, q, value);
        for (stream) |v| v.deinit(out);
        out.free(stream);
    }
    const apply_cycles = tsc.end() - start;
    const reset_cycles = temp_backing.teardown();

    return .{
        .apply_avg = avg(apply_cycles, iterations),
        .byte_avg = avg(apply_cycles, iterations * string_count * len),
        .reset_cycles = @floatFromInt(reset_cycles),
    };
}

fn runCount(child: std.mem.Allocator, n: usize, iterations: usize, apply_avg_out: *f64, alloc_avg_out: *f64, reset_cycles_out: *f64) void {
    const result = benchCountImpl(child, n, iterations) catch {
        apply_avg_out.* = -1;
        alloc_avg_out.* = -1;
        reset_cycles_out.* = -1;
        return;
    };
    apply_avg_out.* = result.apply_avg;
    alloc_avg_out.* = result.alloc_avg;
    reset_cycles_out.* = result.reset_cycles;
}

fn runSize(child: std.mem.Allocator, len: usize, iterations: usize, apply_avg_out: *f64, byte_avg_out: *f64, reset_cycles_out: *f64) void {
    const result = benchSizeImpl(child, len, iterations) catch {
        apply_avg_out.* = -1;
        byte_avg_out.* = -1;
        reset_cycles_out.* = -1;
        return;
    };
    apply_avg_out.* = result.apply_avg;
    byte_avg_out.* = result.byte_avg;
    reset_cycles_out.* = result.reset_cycles;
}

export fn bench_posix_jq_count(n: usize, iterations: usize, apply_avg_out: *f64, alloc_avg_out: *f64, reset_cycles_out: *f64) callconv(.c) void {
    runCount(posix_allocator.allocator, n, iterations, apply_avg_out, alloc_avg_out, reset_cycles_out);
}

export fn bench_includeos_jq_count(n: usize, iterations: usize, apply_avg_out: *f64, alloc_avg_out: *f64, reset_cycles_out: *f64) callconv(.c) void {
    runCount(includeos_allocator.allocator, n, iterations, apply_avg_out, alloc_avg_out, reset_cycles_out);
}

export fn bench_posix_jq_size(len: usize, iterations: usize, apply_avg_out: *f64, byte_avg_out: *f64, reset_cycles_out: *f64) callconv(.c) void {
    runSize(posix_allocator.allocator, len, iterations, apply_avg_out, byte_avg_out, reset_cycles_out);
}

export fn bench_includeos_jq_size(len: usize, iterations: usize, apply_avg_out: *f64, byte_avg_out: *f64, reset_cycles_out: *f64) callconv(.c) void {
    runSize(includeos_allocator.allocator, len, iterations, apply_avg_out, byte_avg_out, reset_cycles_out);
}

fn avg(total: u64, count: usize) f64 {
    return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(count));
}

fn buildNumberArrayJson(allocator: std.mem.Allocator, n: usize) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeByte('[');
    for (0..n) |i| {
        if (i != 0) try buf.writer.writeByte(',');
        try buf.writer.print("{d}", .{i});
    }
    try buf.writer.writeByte(']');
    return buf.toOwnedSlice();
}

fn buildStringArrayJson(allocator: std.mem.Allocator, n: usize, len: usize) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    try buf.writer.writeByte('[');
    for (0..n) |i| {
        if (i != 0) try buf.writer.writeByte(',');
        try buf.writer.writeByte('"');
        for (0..len) |_| try buf.writer.writeByte('x');
        try buf.writer.writeByte('"');
    }
    try buf.writer.writeByte(']');
    return buf.toOwnedSlice();
}
