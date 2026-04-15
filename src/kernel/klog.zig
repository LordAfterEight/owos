/// Kernel log: routes output to both serial and the screen (ScrollingLog).
/// Color scheme per line:
///   "MODULE: "  prefix           → Grey
///   literal text / key labels    → White
///   format-argument values       → BrightBlue
/// err() uses BrightRed for both text and values.
/// Safe to call before GFB_VALID — screen output is silently skipped until then.
const std = @import("std");
const rendering = @import("rendering/rendering.zig");
const Color = rendering.Color;

pub const LoggingVerbosity = enum {
    /// Pass/fail results and summary only.
    quiet,
    /// Results, section headers, and high-level operation summaries.
    normal,
    /// Full diagnostic output (hex dumps, nonce details, etc.).
    verbose,
};

/// Current verbosity level.  Set before calling subsystems that produce
/// heavy log output (e.g. the crypto test suite) and restore afterwards.
pub var verbosity: LoggingVerbosity = .verbose;

fn get_log() *rendering.ScrollingLog {
    return &rendering.ScrollingLog.instance;
}

/// Returns the byte offset just past "TOKEN: " if fmt starts with a module
/// prefix (any text before ": " that contains no "{").  Returns 0 otherwise.
fn module_prefix_end(comptime fmt: []const u8) usize {
    for (fmt, 0..) |c, i| {
        if (c == '{') return 0;
        if (c == ':' and i + 1 < fmt.len and fmt[i + 1] == ' ') return i + 2;
    }
    return 0;
}

/// Walks `fmt` at comptime, printing literal segments in `text_color` and
/// each `{...}` format-argument value in `val_color`.  No trailing newline.
fn print_kv(
    comptime fmt: []const u8,
    args: anytype,
    comptime text_color: Color,
    comptime val_color: Color,
) void {
    @setEvalBranchQuota(1_000_000);
    const log = get_log();
    comptime var pos: usize = 0;
    comptime var arg_idx: usize = 0;

    inline while (pos < fmt.len) {
        // Scan forward to the next '{'.
        const next_open = comptime blk: {
            var j = pos;
            while (j < fmt.len and fmt[j] != '{') j += 1;
            break :blk j;
        };

        // Emit literal text before '{' in text_color.
        if (comptime next_open > pos) {
            log.print("{s}", .{fmt[pos..next_open]}, text_color);
        }

        if (comptime next_open >= fmt.len) {
            pos = fmt.len;
            break;
        }

        // Find the matching '}'.
        const next_close = comptime blk: {
            var j = next_open + 1;
            while (j < fmt.len and fmt[j] != '}') j += 1;
            break :blk j;
        };

        // Format the argument with its original spec and emit in val_color.
        // Static buffer avoids a 128-byte stack allocation inside interrupt context.
        const S = struct { var buf: [128]u8 = undefined; };
        const spec = fmt[next_open .. next_close + 1];
        const s = std.fmt.bufPrint(&S.buf, spec, .{args[arg_idx]}) catch S.buf[0..];
        log.print("{s}", .{s}, val_color);

        pos = next_close + 1;
        arg_idx += 1;
    }
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    const log = get_log();
    const pfx = comptime module_prefix_end(fmt);
    if (comptime pfx > 0) log.print("{s}", .{fmt[0..pfx]}, .Grey);
    print_kv(fmt[pfx..], args, .White, .BrightBlue);
    log.newline();
    rendering.swap();
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    const log = get_log();
    const pfx = comptime module_prefix_end(fmt);
    if (comptime pfx > 0) log.print("{s}", .{fmt[0..pfx]}, .Grey);
    print_kv(fmt[pfx..], args, .White, .BrightBlue);
    log.newline();
    rendering.swap();
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    const log = get_log();
    const pfx = comptime module_prefix_end(fmt);
    if (comptime pfx > 0) log.print("{s}", .{fmt[0..pfx]}, .Grey);
    print_kv(fmt[pfx..], args, .BrightRed, .BrightRed);
    log.newline();
    rendering.swap();
}
