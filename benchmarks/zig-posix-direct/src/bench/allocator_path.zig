export fn zig_add(a: i32, b: i32) callconv(.c) i32 {
    return a + b;
}

const std = @import("std");
const includeos_allocator = @import("includeos-allocator.zig");
const posix_allocator = @import("posix-allocator.zig");
const tsc = @import("tsc.zig");

// force static analysis
comptime {
    _ = @import("jq_bench.zig");
}

extern fn randomizer_next_float(state: *u64) f64;
extern fn randomizer_next_less_than(state: *u64, bound: usize) usize;

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

    // the 64 values must survive realloc's alloc+copy+free.
    for (buf[0..64], 0..) |slot, i| {
        if (slot != i * i) {
            allocator.free(buf);
            return -4;
        }
    }

    allocator.free(buf);
    return 0;
}

fn benchAllocFreeBatched(
    comptime allocator: std.mem.Allocator,
    total_ops: usize,
    batch_size: usize,
    size: usize,
    alloc_avg_out: *f64,
    free_avg_out: *f64,
) void {
    const buffers = includeos_allocator.allocator.alloc([]u8, batch_size) catch {
        alloc_avg_out.* = -1;
        free_avg_out.* = -1;
        return;
    };
    defer includeos_allocator.allocator.free(buffers);

    var alloc_total: u64 = 0;
    var free_total: u64 = 0;
    var done: usize = 0;
    while (done < total_ops) : (done += batch_size) {
        for (buffers) |*buf| {
            const t0 = tsc.start();
            buf.* = allocator.alloc(u8, size) catch &[_]u8{};
            const t1 = tsc.end();
            alloc_total += t1 - t0;
        }
        for (buffers) |buf| {
            const t0 = tsc.start();
            allocator.free(buf);
            const t1 = tsc.end();
            free_total += t1 - t0;
        }
    }

    const ops_f: f64 = @floatFromInt(done);
    alloc_avg_out.* = @as(f64, @floatFromInt(alloc_total)) / ops_f;
    free_avg_out.* = @as(f64, @floatFromInt(free_total)) / ops_f;
}

export fn bench_posix_mmap(total_ops: usize, batch_size: usize, size: usize, alloc_avg_out: *f64, free_avg_out: *f64) callconv(.c) void {
    benchAllocFreeBatched(posix_allocator.allocator, total_ops, batch_size, size, alloc_avg_out, free_avg_out);
}

export fn bench_includeos_direct(total_ops: usize, batch_size: usize, size: usize, alloc_avg_out: *f64, free_avg_out: *f64) callconv(.c) void {
    benchAllocFreeBatched(includeos_allocator.allocator, total_ops, batch_size, size, alloc_avg_out, free_avg_out);
}

// at each step, one of three things happens:
//   allocate `size` (70%),
//   allocate `size2` (10%),
//   or free a uniformly random allocation (20%)
fn benchInterleaved(
    comptime allocator: std.mem.Allocator,
    total_ops: usize,
    max_live: usize,
    size: usize,
    seed: u64,
    alloc_avg_out: *f64,
    free_avg_out: *f64,
) void {
    const size2: usize = 17;
    const size1_prob: f64 = 0.7;
    const size2_prob: f64 = 0.1;

    const live = includeos_allocator.allocator.alloc([]u8, max_live) catch {
        alloc_avg_out.* = -1;
        free_avg_out.* = -1;
        return;
    };
    defer includeos_allocator.allocator.free(live);
    var live_count: usize = 0;

    var rng_state: u64 = seed;

    var alloc_total: u64 = 0;
    var alloc_n: u64 = 0;
    var free_total: u64 = 0;
    var free_n: u64 = 0;

    var done: usize = 0;
    while (done < total_ops) : (done += 1) {
        const r = randomizer_next_float(&rng_state);

        var want_free = r >= size1_prob + size2_prob;
        if (live_count == 0) want_free = false;
        if (live_count >= max_live) want_free = true;

        if (want_free) {
            const idx = randomizer_next_less_than(&rng_state, live_count);
            const buf = live[idx];
            live_count -= 1;
            live[idx] = live[live_count];

            const t0 = tsc.start();
            allocator.free(buf);
            const t1 = tsc.end();
            if (buf.len == size) {
                free_total += t1 - t0;
                free_n += 1;
            }
        } else {
            const use_size2 = r >= size1_prob and r < size1_prob + size2_prob;
            const alloc_size: usize = if (use_size2) size2 else size;

            const t0 = tsc.start();
            const buf: []u8 = allocator.alloc(u8, alloc_size) catch &[_]u8{};
            const t1 = tsc.end();
            if (!use_size2) {
                alloc_total += t1 - t0;
                alloc_n += 1;
            }
            live[live_count] = buf;
            live_count += 1;
        }
    }

    for (live[0..live_count]) |buf| allocator.free(buf);

    alloc_avg_out.* = if (alloc_n > 0) @as(f64, @floatFromInt(alloc_total)) / @as(f64, @floatFromInt(alloc_n)) else 0;
    free_avg_out.* = if (free_n > 0) @as(f64, @floatFromInt(free_total)) / @as(f64, @floatFromInt(free_n)) else 0;
}

export fn bench_posix_interleaved(total_ops: usize, max_live: usize, size: usize, seed: u64, alloc_avg_out: *f64, free_avg_out: *f64) callconv(.c) void {
    benchInterleaved(posix_allocator.allocator, total_ops, max_live, size, seed, alloc_avg_out, free_avg_out);
}

export fn bench_includeos_interleaved(total_ops: usize, max_live: usize, size: usize, seed: u64, alloc_avg_out: *f64, free_avg_out: *f64) callconv(.c) void {
    benchInterleaved(includeos_allocator.allocator, total_ops, max_live, size, seed, alloc_avg_out, free_avg_out);
}

// allocates `size` in a loop until the allocator fails 
fn benchFill(
    comptime allocator: std.mem.Allocator,
    size: usize,
    alloc_costs_out: [*]f64,
    free_costs_out: [*]f64,
    capacity: usize,
    count_out: *usize,
    capped_out: *bool,
) void {
    const live = includeos_allocator.allocator.alloc([]u8, capacity) catch {
        count_out.* = 0;
        capped_out.* = false;
        return;
    };
    defer includeos_allocator.allocator.free(live);

    var count: usize = 0;
    while (count < capacity) {
        const t0 = tsc.start();
        const buf = allocator.alloc(u8, size) catch break; // genuine failure -- stop
        const t1 = tsc.end();
        alloc_costs_out[count] = @as(f64, @floatFromInt(t1 - t0));
        live[count] = buf;
        count += 1;
    }
    count_out.* = count;
    capped_out.* = (count == capacity);

    var i: usize = count;
    while (i > 0) {
        i -= 1;
        const t0 = tsc.start();
        allocator.free(live[i]);
        const t1 = tsc.end();
        free_costs_out[i] = @as(f64, @floatFromInt(t1 - t0));
    }
}

export fn bench_posix_fill(size: usize, alloc_costs_out: [*]f64, free_costs_out: [*]f64, capacity: usize, count_out: *usize, capped_out: *bool) callconv(.c) void {
    benchFill(posix_allocator.allocator, size, alloc_costs_out, free_costs_out, capacity, count_out, capped_out);
}

export fn bench_includeos_fill(size: usize, alloc_costs_out: [*]f64, free_costs_out: [*]f64, capacity: usize, count_out: *usize, capped_out: *bool) callconv(.c) void {
    benchFill(includeos_allocator.allocator, size, alloc_costs_out, free_costs_out, capacity, count_out, capped_out);
}

// same 70/10/20 size1/size2/free as benchInterleaved, but with no fixed operation count
fn benchInterleavedFill(
    comptime allocator: std.mem.Allocator,
    size: usize,
    seed: u64,
    alloc_costs_out: [*]f64,
    free_costs_out: [*]f64,
    live_capacity: usize,
    cost_capacity: usize,
    alloc_count_out: *usize,
    free_count_out: *usize,
    capped_out: *bool,
) void {
    const size2: usize = 17;
    const size1_prob: f64 = 0.7;
    const size2_prob: f64 = 0.1;

    const live = includeos_allocator.allocator.alloc([]u8, live_capacity) catch {
        alloc_count_out.* = 0;
        free_count_out.* = 0;
        capped_out.* = false;
        return;
    };
    defer includeos_allocator.allocator.free(live);
    var live_count: usize = 0;

    var rng_state: u64 = seed;

    var alloc_count: usize = 0;
    var free_count: usize = 0;
    var capped = false;

    while (true) {
        const r = randomizer_next_float(&rng_state);

        var want_free = r >= size1_prob + size2_prob;
        if (live_count == 0) want_free = false;
        if (live_count >= live_capacity) want_free = true;

        if (want_free) {
            const idx = randomizer_next_less_than(&rng_state, live_count);
            const buf = live[idx];
            live_count -= 1;
            live[idx] = live[live_count];

            const t0 = tsc.start();
            allocator.free(buf);
            const t1 = tsc.end();
            if (buf.len == size) {
                if (free_count >= cost_capacity) { capped = true; break; } // safety stop
                free_costs_out[free_count] = @as(f64, @floatFromInt(t1 - t0));
                free_count += 1;
            }
        } else {
            const use_size2 = r >= size1_prob and r < size1_prob + size2_prob;
            const alloc_size: usize = if (use_size2) size2 else size;

            if (!use_size2 and alloc_count >= cost_capacity) { capped = true; break; } // safety stop

            const t0 = tsc.start();
            const buf: []u8 = allocator.alloc(u8, alloc_size) catch break; // genuine failure -- stop
            const t1 = tsc.end();
            if (!use_size2) {
                alloc_costs_out[alloc_count] = @as(f64, @floatFromInt(t1 - t0));
                alloc_count += 1;
            }
            live[live_count] = buf;
            live_count += 1;
        }
    }
    alloc_count_out.* = alloc_count;
    capped_out.* = capped;

    var i: usize = live_count;
    while (i > 0) {
        i -= 1;
        const buf = live[i];
        const t0 = tsc.start();
        allocator.free(buf);
        const t1 = tsc.end();
        if (buf.len == size and free_count < cost_capacity) {
            free_costs_out[free_count] = @as(f64, @floatFromInt(t1 - t0));
            free_count += 1;
        }
    }
    free_count_out.* = free_count;
}

export fn bench_posix_interleaved_fill(size: usize, seed: u64, alloc_costs_out: [*]f64, free_costs_out: [*]f64, live_capacity: usize, cost_capacity: usize, alloc_count_out: *usize, free_count_out: *usize, capped_out: *bool) callconv(.c) void {
    benchInterleavedFill(posix_allocator.allocator, size, seed, alloc_costs_out, free_costs_out, live_capacity, cost_capacity, alloc_count_out, free_count_out, capped_out);
}

export fn bench_includeos_interleaved_fill(size: usize, seed: u64, alloc_costs_out: [*]f64, free_costs_out: [*]f64, live_capacity: usize, cost_capacity: usize, alloc_count_out: *usize, free_count_out: *usize, capped_out: *bool) callconv(.c) void {
    benchInterleavedFill(includeos_allocator.allocator, size, seed, alloc_costs_out, free_costs_out, live_capacity, cost_capacity, alloc_count_out, free_count_out, capped_out);
}
