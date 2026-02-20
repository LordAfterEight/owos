const owos = @import("../root.zig");
const std = @import("std");

pub const Process = struct {
    name: [:0]const u8,
    id: usize,
    allocator: std.mem.Allocator,
    running: bool,

    // Type-erased app instance.
    ctx: *anyopaque,
    vtable: *const VTable,

    // Optional: whatever your window type is.
    // window: ?owos.window.Window = null,

    const VTable = struct {
        deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
        once:   *const fn (ctx: *anyopaque) anyerror!void,
        tick:   *const fn (ctx: *anyopaque) anyerror!u8,
    };

    fn assertApp(comptime App: type) void {
        // Existence checks (signature mismatches will still error at the call sites).
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
            .ctx = @constCast(app_ptr),
            .vtable = appVTable(App),
        };
    }

    pub fn init_with_window(
        comptime App: type,
        allocator: std.mem.Allocator,
        args: anytype,
    ) !Process {
        return Process.init(App, allocator, args);
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

