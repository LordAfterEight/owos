pub const Process = struct {
    id: u32,
    name: []const u8,

    ctx: *const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        tick: *const fn (ctx: *const anyopaque) u8,
        deinit: ?*const fn (ctx: *const anyopaque) void,
    };

    pub fn tick(self: *const Process) u8 {
        return self.vtable.tick(self.ctx);
    }

    /// For mutable apps: `pub fn run(self: *T) void`
    pub fn init_mut(app_ptr: anytype) Process {
        const T = @TypeOf(app_ptr.*);

        const vt = comptime VTable{
            .tick = struct {
                fn thunk(ctx: *const anyopaque) u8 {
                    // ctx is const-erased, but the concrete pointer is mutable.
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
        };

        return .{
            .id = undefined,
            .name = app_ptr.name,
            .ctx = @ptrCast(app_ptr), // *T -> *const anyopaque is allowed
            .vtable = &vt,
        };
    }

    /// For const apps: `pub fn run(self: *const T) void`
    pub fn init_const(name: []const u8, app_ptr: anytype) Process {
        const T = @TypeOf(app_ptr.*);

        const vt = comptime VTable{
            .run = struct {
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
        };

        return .{
            .id = undefined,
            .name = name,
            .ctx = @ptrCast(app_ptr), // *const T -> *const anyopaque is allowed
            .vtable = &vt,
        };
    }
};

