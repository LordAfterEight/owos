const std = @import("std");
const owos = @import("../root.zig");

const MAX_PROCESSES: usize = 16;

extern fn enter_user(ctx: *const owos.process.CpuContext) noreturn;

extern fn tss_set_rsp0(rsp0: u64) void;

pub const Scheduler = struct {
    processes: [MAX_PROCESSES]?*owos.process.Process = [_]?*owos.process.Process{null} ** MAX_PROCESSES,
    next_pid: usize = 0,
    current: ?usize = null,

    pub fn init() *Scheduler {
        owos.serial.println("Initialized userland scheduler");
        return &global_scheduler;
    }

    pub fn spawn_user_process(self: *Scheduler, name: [:0]const u8, code: []const u8) !usize {
        owos.serial.println("Creating Process to spawn...");
        const p = try owos.process.Process.create_user_process(owos.allocator.global_alloc, name, code);

        owos.serial.println("Searching for free slot");
        for (0..MAX_PROCESSES) |slot| {
            if (self.processes[slot] == null) {
                p.pid = slot;
                self.processes[slot] = p;
                owos.serial.print("Spawned user process ");
                owos.serial.print(name);
                owos.serial.print(" pid=");
                owos.serial.print_dec_usize(slot);
                owos.serial.println("");
                return slot;
            }
        }

        p.destroy();
        return error.NoFreeSlot;
    }

    pub fn reap_zombies(self: *Scheduler) void {
        for (0..MAX_PROCESSES) |i| {
            if (self.processes[i]) |p| {
                if (p.state == .zombie) {
                    owos.serial.print("Reaping pid=");
                    owos.serial.print_dec_usize(p.pid);
                    owos.serial.println("");
                    p.destroy();
                    self.processes[i] = null;
                }
            }
        }
    }

    fn pick_next(self: *Scheduler) ?*owos.process.Process {
        const start: usize = if (self.current) |c| (c + 1) % MAX_PROCESSES else 0;

        var i: usize = 0;
        while (i < MAX_PROCESSES) : (i += 1) {
            const idx = (start + i) % MAX_PROCESSES;
            if (self.processes[idx]) |p| {
                if (p.state == .ready) {
                    self.current = idx;
                    return p;
                }
            }
        }
        return null;
    }

    pub fn run(self: *Scheduler) noreturn {
        owos.serial.println("Started userland scheduler");

        while (true) {
            self.reap_zombies();

            const next = self.pick_next() orelse {
                asm volatile ("hlt");
                continue;
            };

            next.state = .running;

            owos.serial.println("about to enter user");
            owos.serial.print("user rip=");
            owos.serial.print_hex_u64(next.user_ctx.rip);
            owos.serial.println("");
            owos.serial.print("user rsp=");
            owos.serial.print_hex_u64(next.user_ctx.rsp);
            owos.serial.println("");
            owos.serial.print("user cs=");
            owos.serial.print_hex_u64(next.user_ctx.cs);
            owos.serial.println("");
            owos.serial.print("user ss=");
            owos.serial.print_hex_u64(next.user_ctx.ss);
            owos.serial.println("");
            owos.serial.println("tss_set_rsp0 next");
            tss_set_rsp0(@intFromPtr(next.kernel_stack.ptr) + next.kernel_stack.len);
            owos.serial.println("calling enter_user");
            enter_user(&next.user_ctx);
        }
    }

    pub fn on_yield(self: *Scheduler) void {
        if (self.current) |idx| {
            if (self.processes[idx]) |p| {
                if (p.state == .running) p.state = .ready;
            }
        }
    }

    pub fn on_exit(self: *Scheduler, code: u8) void {
        if (self.current) |idx| {
            if (self.processes[idx]) |p| {
                p.markZombie(code);
            }
        }
    }
};

pub var global_scheduler: Scheduler = .{};
