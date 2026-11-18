pub fn start() u64 {
    var hi: u32 = undefined;
    var lo: u32 = undefined;
    asm volatile (
        \\cpuid
        \\rdtsc
        \\mov %%edx, %[hi]
        \\mov %%eax, %[lo]
        : [hi] "=r" (hi),
          [lo] "=r" (lo),
        :
        : .{ .rax = true, .rbx = true, .rcx = true, .rdx = true, .memory = true }
    );
    return (@as(u64, hi) << 32) | lo;
}

pub fn end() u64 {
    var hi: u32 = undefined;
    var lo: u32 = undefined;
    asm volatile (
        \\lfence
        \\rdtsc
        \\mov %%edx, %[hi]
        \\mov %%eax, %[lo]
        \\cpuid
        : [hi] "=r" (hi),
          [lo] "=r" (lo),
        :
        : .{ .rax = true, .rbx = true, .rcx = true, .rdx = true, .memory = true }
    );
    return (@as(u64, hi) << 32) | lo;
}
