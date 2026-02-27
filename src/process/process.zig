const std = @import("std");
const owos = @import("../root.zig");

pub const kcode_sel: u16 = 0x08;
pub const kdata_sel: u16 = 0x10;

pub const ucode_sel: u16 = 0x18;
pub const udata_sel: u16 = 0x20;

pub const rpl3: u16 = 3;

pub const CpuContext = extern struct {
    r15: u64 = 0,
    r14: u64 = 0,
    r13: u64 = 0,
    r12: u64 = 0,
    rbp: u64 = 0,
    rbx: u64 = 0,

    rip: u64 = 0,
    cs: u64 = 0,
    rflags: u64 = 0x202,
    rsp: u64 = 0,
    ss: u64 = 0,
};

pub const ProcState = enum {
    ready,
    running,
    blocked,
    zombie,
};

pub const Process = struct {
    name: [:0]const u8,
    pid: usize,
    allocator: std.mem.Allocator,

    state: ProcState = .ready,
    exit_code: u8 = 0,

    user_ctx: CpuContext,

    kernel_stack: []u8,

    user_code: []u8,
    user_stack: []u8,

    pub fn create_user_process(
        allocator: std.mem.Allocator,
        name: [:0]const u8,
        code: []const u8,
    ) !*Process {
        const p = try allocator.create(Process);
        owos.serial.println("Created Proces");
        errdefer allocator.destroy(p);

        const code_page = try owos.vmm.alloc_user_pages(allocator, code.len);
        owos.serial.println("Allocated user page");
        errdefer owos.vmm.free_user_pages(allocator, code_page);

        @memcpy(code_page, code);

        const ustack = try owos.vmm.alloc_user_pages(allocator, 64 * 1024);
        errdefer owos.vmm.free_user_pages(allocator, ustack);

        const user_rsp: u64 = @intFromPtr(ustack.ptr) + ustack.len;

        const kstack = try allocator.alignedAlloc(u8, .@"16", 16 * 1024);
        errdefer allocator.free(kstack);

        p.* = .{
            .name = name,
            .pid = undefined,
            .allocator = allocator,
            .state = .ready,
            .exit_code = 0,

            .user_ctx = .{
            .rip = @intFromPtr(code_page.ptr),
            .cs = @as(u64, ucode_sel | rpl3),
            .rflags = 0x202,
            .rsp = user_rsp,
            .ss = @as(u64, udata_sel | rpl3),
        },

            .kernel_stack = kstack,
            .user_code = code_page,
            .user_stack = ustack,
        };
        return p;
    }

    pub fn destroy(self: *Process) void {
        owos.vmm.free_user_pages(self.allocator, self.user_code);
        owos.vmm.free_user_pages(self.allocator, self.user_stack);
        self.allocator.free(self.kernel_stack);

        self.allocator.destroy(self);
    }

    pub inline fn kernel_stack_top(self: *const Process) u64 {
        return @intFromPtr(self.kernel_stack.ptr) + self.kernel_stack.len;
    }

    pub fn mark_zombie(self: *Process, code: u8) void {
        self.exit_code = code;
        self.state = .zombie;
    }
};
