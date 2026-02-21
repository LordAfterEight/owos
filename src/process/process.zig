const owos = @import("../root.zig");
const std = @import("std");

pub const CpuContext = extern struct {
    r15: u64 = 0, r14: u64 = 0, r13: u64 = 0, r12: u64 = 0,
    rbp: u64 = 0, rbx: u64 = 0,
    rip: u64 = 0,
    cs:  u64 = 0,
    rflags: u64 = 0x202,
    rsp: u64 = 0,
    ss:  u64 = 0,
};

pub const ProcessKind = enum { kernel, user };

pub const Process = struct {
    name: [:0]const u8,
    id: usize,
    allocator: std.mem.Allocator,
    running: bool,

    kind: ProcessKind,
    cpu_ctx: CpuContext = .{},
    kernel_stack: []u8 = &.{},

    ctx: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
        once:   *const fn (ctx: *anyopaque) anyerror!void,
        tick:   *const fn (ctx: *anyopaque) anyerror!u8,
    };

    fn assertApp(comptime App: type) void {
        if (!@hasDecl(App, "init"))   @compileError("App must declare pub fn init() !App (or compatible)");
        if (!@hasDecl(App, "deinit")) @compileError("App must declare pub fn deinit(self: *App) void");
        if (!@hasDecl(App, "once"))   @compileError("App must declare pub fn once(self: *App) !void");
        if (!@hasDecl(App, "tick"))   @compileError("App must declare pub fn tick(self: *App) !void");
    }

    fn appVTable(comptime App: type) *const VTable {
        return &struct {
            fn deinitErased(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                const app: *App = @alignCast(@ptrCast(ctx));
                app.deinit();
                allocator.destroy(app);
            }

            fn onceErased(ctx: *anyopaque) anyerror!void {
                const app: *App = @alignCast(@ptrCast(ctx));
                return app.once();
            }

            fn tickErased(ctx: *anyopaque) anyerror!u8 {
                const app: *App = @alignCast(@ptrCast(ctx));
                return app.tick();
            }

            const vt = VTable{
                .deinit = deinitErased,
                .once = onceErased,
                .tick = tickErased,
            };
        }.vt;
    }

    pub fn init(
        comptime App: type,
        allocator: std.mem.Allocator,
        args: anytype,
    ) !Process {
        comptime assertApp(App);

        const app_ptr = try allocator.create(App);
        errdefer allocator.destroy(app_ptr);

        app_ptr.* = @call(.auto, App.init, args);
        app_ptr.*.once();

        return .{
            .name = app_ptr.name,
            .id = undefined,
            .allocator = allocator,
            .running = true,
            .kind = .kernel,
            .ctx = @constCast(app_ptr),
            .vtable = appVTable(App),
        };
    }

    pub fn init_user(
        name: [:0]const u8,
        code: []const u8,
        allocator: std.mem.Allocator,
    ) !Process {
        const code_page = try owos.vmm.alloc_user_pages(allocator, code.len);
        @memcpy(code_page, code);

        const user_stack = try owos.vmm.alloc_user_pages(allocator, 64 * 1024);
        const user_rsp = @intFromPtr(user_stack.ptr) + user_stack.len;

        const kstack = try allocator.alignedAlloc(u8, 16, 8 * 1024);

        return Process{
            .name = name,
            .id = undefined,
            .allocator = allocator,
            .running = true,
            .kind = .user,
            .cpu_ctx = .{
                .rip    = @intFromPtr(code_page.ptr),
                .cs     = owos.gdt.USER_CODE | 3,
                .rflags = 0x202,
                .rsp    = user_rsp,
                .ss     = owos.gdt.USER_DATA | 3,
            },
            .kernel_stack = kstack,
            .ctx    = undefined,
            .vtable = undefined,
        };
    }

    pub fn deinit(self: *Process) void {
        self.vtable.deinit(self.ctx, self.allocator);
        self.* = undefined;
    }

    pub fn once(self: *Process) !void {
        return self.vtable.once(self.ctx);
    }

    pub fn tick(self: *Process) anyerror!u8 {
        return self.vtable.tick(self.ctx);
    }
};

