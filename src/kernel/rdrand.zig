/// Hardware random number generation via x86 RDRAND, with TSC-based fallback.
const owos = @import("root.zig");

var has_rdrand: bool = false;
var fallback_state: u64 = 0;

pub fn init() void {
    // CPUID leaf 1, ECX bit 30 = RDRAND support
    var ecx: u32 = undefined;
    asm volatile ("cpuid"
        : [ecx] "={ecx}" (ecx),
        : [eax] "{eax}" (@as(u32, 1)),
        : .{ .ebx = true, .edx = true }
    );
    has_rdrand = (ecx & (1 << 30)) != 0;

    if (has_rdrand) {
        owos.klog.info("RNG: RDRAND available", .{});
    } else {
        // Seed fallback PRNG from TSC
        var lo: u32 = undefined;
        var hi: u32 = undefined;
        asm volatile ("rdtsc"
            : [lo] "={eax}" (lo),
              [hi] "={edx}" (hi),
        );
        fallback_state = (@as(u64, hi) << 32) | lo;
        owos.klog.warn("RNG: no RDRAND, using TSC-seeded PRNG (reduced entropy)", .{});
    }
}

fn rdrand64() u64 {
    var val: u64 = undefined;
    asm volatile (
        \\1: rdrand %[out]
        \\   jnc 1b
        : [out] "=r" (val),
    );
    return val;
}

/// xorshift64* PRNG — not cryptographically secure, but better than nothing.
fn xorshift64() u64 {
    var s = fallback_state;
    s ^= s << 13;
    s ^= s >> 7;
    s ^= s << 17;
    fallback_state = s;
    return s *% 0x2545F4914F6CDD1D;
}

fn next_u64() u64 {
    if (has_rdrand) return rdrand64();
    return xorshift64();
}

/// Fill a buffer with random bytes.
pub fn fill(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) {
        const r = next_u64();
        const bytes: [8]u8 = @bitCast(r);
        const remaining = buf.len - i;
        const n = if (remaining < 8) remaining else 8;
        @memcpy(buf[i..][0..n], bytes[0..n]);
        i += n;
    }
}
