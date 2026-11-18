# zig-hello-world

Checks that a Zig object links into IncludeOS and can use
`os::mem::raw_allocator()` through `std.mem.Allocator`. Section 6.6.
IncludeOS: tag `msc-zig` (`dbe3ecf1d`).

    cd src
    ./run.sh

A pass prints `zig_add(2, 40) = 42` and `zig_alloc_roundtrip() = 0`; there is no other result.
