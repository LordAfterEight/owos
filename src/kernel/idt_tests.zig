const owos = @import("root.zig");
const idt = @import("idt.zig");

// ---------------------------------------------------------------------------
// Test state — written by test handlers, read by assertions
// ---------------------------------------------------------------------------

var test_vector: u64 = 0xDEAD;
var test_rip: u64 = 0;
var test_error_code: u64 = 0;
var test_handler_called: bool = false;

fn reset() void {
    test_vector = 0xDEAD;
    test_rip = 0;
    test_error_code = 0;
    test_handler_called = false;
}

// ---------------------------------------------------------------------------
// Reusable handlers
// ---------------------------------------------------------------------------

/// Records the frame and returns normally (suitable for traps / software INTs).
fn record_handler(frame: *idt.InterruptFrame) void {
    test_vector = frame.vector;
    test_rip = frame.rip;
    test_error_code = frame.error_code;
    test_handler_called = true;
}

/// Like record_handler but also advances RIP by 2 to skip a faulting
/// `div %ecx` instruction (opcode F7 F1, exactly 2 bytes).
fn de_skip_handler(frame: *idt.InterruptFrame) void {
    test_vector = frame.vector;
    test_rip = frame.rip;
    test_error_code = frame.error_code;
    test_handler_called = true;
    frame.rip += 2; // skip past `div %ecx`
}

/// Second handler used to verify handler replacement.
fn alternate_handler(frame: *idt.InterruptFrame) void {
    test_vector = frame.vector;
    test_handler_called = true;
    // Set a marker so we can distinguish from record_handler.
    test_error_code = 0xABCD;
}

// ---------------------------------------------------------------------------
// Test reporting (mirrors crypto_tests.zig)
// ---------------------------------------------------------------------------

var pass_count: usize = 0;
var total_count: usize = 0;

fn report(name: []const u8, ok: bool) void {
    const log = &owos.fb.rendering.ScrollingLog.instance;
    total_count += 1;
    if (ok) pass_count += 1;
    log.print("TESTS: ", .{}, .Grey);
    if (ok) {
        log.print("[PASS] ", .{}, .BrightGreen);
    } else {
        log.print("[FAIL] ", .{}, .BrightRed);
    }
    log.println("{s}", .{name}, .White);
    if (owos.klog.verbosity == .verbose) {
        log.print("TESTS: ", .{}, .Grey);
        log.println("       vec=0x{X:0>4}  err=0x{X:0>4}  rip=0x{X:0>16}  called={}", .{
            test_vector, test_error_code, test_rip, test_handler_called,
        }, .BrightBlue);
    }
}

fn section(name: []const u8) void {
    if (owos.klog.verbosity == .quiet) return;
    owos.klog.info("TESTS: --- {s} ---", .{name});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// INT3 (breakpoint) is a trap — the handler runs and iret resumes at the
/// next instruction.  Verify the handler is called with vector 3.
fn test_int3_trap() bool {
    reset();
    const prev = idt.get_handler(3);
    idt.set_handler(3, record_handler);
    defer idt.set_handler(3, prev);

    asm volatile ("int3");

    return test_handler_called and test_vector == 3;
}

/// A software interrupt via `int $N` dispatches to the correct vector.
fn test_software_int() bool {
    reset();
    const prev = idt.get_handler(0x80);
    idt.set_handler(0x80, record_handler);
    defer idt.set_handler(0x80, prev);

    asm volatile ("int $0x80");

    return test_handler_called and test_vector == 0x80;
}

/// Division by zero (#DE, vector 0) is a fault — the CPU pushes the
/// faulting RIP.  The handler skips the 2-byte `div %ecx` instruction
/// so execution continues normally.
fn test_div_by_zero() bool {
    reset();
    const prev = idt.get_handler(0);
    idt.set_handler(0, de_skip_handler);
    defer idt.set_handler(0, prev);

    // Trigger #DE with a known 2-byte instruction: div %ecx (F7 F1).
    asm volatile (
        \\xor %%ecx, %%ecx
        \\mov $1, %%eax
        \\xor %%edx, %%edx
        \\.byte 0xf7, 0xf1
        :
        :
        : .{ .eax = true, .ecx = true, .edx = true }
    );

    return test_handler_called and test_vector == 0;
}

/// After set_handler replaces a handler, the new one runs instead of the old.
fn test_handler_replacement() bool {
    reset();
    const prev = idt.get_handler(0x81);
    defer idt.set_handler(0x81, prev);

    // First handler
    idt.set_handler(0x81, record_handler);
    asm volatile ("int $0x81");
    if (!test_handler_called or test_vector != 0x81) return false;
    if (test_error_code == 0xABCD) return false; // should NOT be alternate

    // Replace and re-trigger
    reset();
    idt.set_handler(0x81, alternate_handler);
    asm volatile ("int $0x81");
    return test_handler_called and test_vector == 0x81 and test_error_code == 0xABCD;
}

/// get_handler returns the currently installed handler (or null).
fn test_get_handler() bool {
    const prev = idt.get_handler(0x82);
    defer idt.set_handler(0x82, prev);

    if (idt.get_handler(0x82) != null) return false; // initially null
    idt.set_handler(0x82, record_handler);
    if (idt.get_handler(0x82) != @as(?idt.Handler, record_handler)) return false;
    idt.set_handler(0x82, null);
    return idt.get_handler(0x82) == null;
}

/// The handler for a software INT receives error_code == 0 (pushed by the
/// ISR stub as a dummy) and vector matches the INT number.
fn test_frame_fields() bool {
    reset();
    const prev = idt.get_handler(0x83);
    idt.set_handler(0x83, record_handler);
    defer idt.set_handler(0x83, prev);

    asm volatile ("int $0x83");

    if (!test_handler_called) return false;
    if (test_vector != 0x83) return false;
    if (test_error_code != 0) return false; // stub pushes 0 for non-error vectors
    return test_rip != 0; // RIP must be a valid kernel address
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run_all(verbosity: owos.klog.LoggingVerbosity) void {
    const prev_verbosity = owos.klog.verbosity;
    owos.klog.verbosity = verbosity;
    defer owos.klog.verbosity = prev_verbosity;

    pass_count = 0;
    total_count = 0;

    owos.klog.info("TESTS: ========== idt fault handler suite ==========", .{});

    section("trap / software INT");
    report("INT3 breakpoint trap dispatches to vector 3", test_int3_trap());
    report("software int $0x80 dispatches correctly", test_software_int());
    report("frame fields (vector, error_code, rip) are correct", test_frame_fields());

    section("fault handling");
    report("division by zero (#DE) handled and skipped", test_div_by_zero());

    section("handler management");
    report("handler replacement takes effect immediately", test_handler_replacement());
    report("get_handler returns current handler or null", test_get_handler());

    // Summary
    const log = &owos.fb.rendering.ScrollingLog.instance;
    log.print("TESTS: ", .{}, .Grey);
    const all_pass = pass_count == total_count;
    if (all_pass) {
        log.print("{d}/{d} passed --", .{ pass_count, total_count }, .BrightGreen);
        log.println("ALL OK", .{}, .BrightGreen);
    } else {
        log.print("{d}/{d} passed --", .{ pass_count, total_count }, .BrightRed);
        log.println("{d} FAILED", .{ total_count - pass_count }, .BrightRed);
    }
    owos.klog.info("TESTS: ==============================================", .{});
}
