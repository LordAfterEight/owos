const owos = @import("owos");

pub const Process = struct {
    id: usize,
    name: [:0]const u8,
    running: bool,
    ctx: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        tick: *const fn (ctx: *const anyopaque) u8,
        deinit: ?*const fn (ctx: *const anyopaque) void,
        once: *const fn (ctx: *const anyopaque) void,
    };

    pub fn tick(self: *const Process) u8 {
        return self.vtable.tick(self.ctx);
    }

    pub fn init_mut(app_ptr: anytype) Process {
        const T = @TypeOf(app_ptr.*);

        const vt = comptime VTable{
            .tick = struct {
                fn thunk(ctx: *const anyopaque) u8 {
                    const self_t: *T = @ptrCast(@alignCast(@constCast(ctx)));
                    return self_t.tick();
                }
            }.thunk,
            .deinit = if (@hasDecl(T, "deinit")) struct {
                fn thunk(ctx: *const anyopaque) void {
                    const self_t: *T = @ptrCast(@alignCast(@constCast(ctx)));
                    self_t.deinit();
                }
            }.thunk else null,
            .once = struct {
                fn thunk(ctx: *const anyopaque) void {
                    const self_t: *T = @ptrCast(@alignCast(@constCast(ctx)));
                    self_t.once();
                }
            }.thunk
        };

        vt.once(app_ptr);

        return .{
            .id = undefined,
            .name = app_ptr.name,
            .running = true,
            .ctx = @ptrCast(app_ptr),
            .vtable = &vt,
        };
    }

    pub fn init_const(name: []const u8, app_ptr: anytype) Process {
        const T = @TypeOf(app_ptr.*);

        const vt = comptime VTable{
            .tick = struct {
                fn thunk(ctx: *const anyopaque) u8 {
                    const self_t: *const T = @ptrCast(@alignCast(ctx));
                    return self_t.tick();
                }
            }.thunk,
            .deinit = if (@hasDecl(T, "deinit")) struct {
                fn thunk(ctx: *const anyopaque) void {
                    const self_t: *T = @ptrCast(@alignCast(@constCast(ctx)));
                    self_t.deinit();
                }
            }.thunk else null,
            .once = struct {
                fn thunk(ctx: *const anyopaque) void {
                    const self_t: *T = @ptrCast(@alignCast(@constCast(ctx)));
                    self_t.once();
                }
            }.thunk
        };

        vt.once(app_ptr);

        return .{
            .id = undefined,
            .name = name,
            .running = true,
            .ctx = @ptrCast(app_ptr),
            .vtable = &vt,
        };
    }
};
