const std = @import("std");
const owos = @import("../root.zig");

pub var global_scheduler: CooperativeScheduler = .{
    .processes = [_]?*owos.process.Process{null} ** MAX_PROCESSES,
    .process_counter = 0,
};

const MAX_PROCESSES: usize = 16;

const Result = struct { exit_code: u8, pid: usize };

pub const CooperativeScheduler = struct {
    processes: [MAX_PROCESSES]?*owos.process.Process,
    process_counter: u8,

    pub fn init() *CooperativeScheduler {
        owos.serial.println("Initialized cooperative scheduler");

        return &global_scheduler;
    }

    pub fn add_process(self: *CooperativeScheduler, prog: type, name: [:0]const u8) anyerror!void {
        const proc_ptr = try owos.allocator.global_alloc.create(owos.process.Process);
        proc_ptr.* = try owos.process.Process.init(prog, owos.allocator.global_alloc, .{name});

        for (0..MAX_PROCESSES) |slot| {
            owos.serial.print("Checking slot: ");
            owos.serial.print_dec_usize(slot);
            owos.serial.print("... ");
            if (self.processes[slot] != null) {
                owos.serial.print("Occupied by process: ");
                owos.serial.println(self.processes[slot].?.name);
            } else {
                owos.serial.println("Free");
                proc_ptr.id = slot;
                self.processes[slot] = proc_ptr;
                self.process_counter += 1;
                owos.serial.print("Added process \"");
                owos.serial.print(proc_ptr.name);
                owos.serial.print("\" with PID:");
                owos.serial.print_dec_usize(proc_ptr.id);
                owos.serial.println(" to cooperative scheduler");
                return;
            }
        }
        owos.allocator.global_alloc.destroy(proc_ptr);
        return error.NoFreeSlot;
    }

    pub fn kill_process(self: *CooperativeScheduler, pid: usize) void {
        if (self.processes[pid] != null) {
            self.processes[pid] = null;
        } else {}
    }

    pub fn scheduler_run(self: *CooperativeScheduler) noreturn {
        owos.serial.println("Started cooperative scheduler");
        var exit_code: u8 = 2;
        var last_tick: u64 = owos.c.ticks;

        while (exit_code == 2) {
            for (0..MAX_PROCESSES) |slot| {
                if (self.processes[slot]) |proc| {
                    if (proc.running) {
                        const proc_result = proc.tick() catch |err| {
                            owos.serial.print("Error ocurred: ");
                            owos.serial.println(@errorName(err));
                            continue;
                        };
                        if (proc_result == 0 or proc_result == 1) {
                            exit_code = proc_result;
                        }
                    }
                }
            }
            while (owos.c.ticks == last_tick) {
                asm volatile ("hlt" ::: .{ .memory = true });
            }
            last_tick = owos.c.ticks;
        }
        while (true) asm volatile ("cli; hlt");
    }

    pub fn run(self: *CooperativeScheduler) noreturn {
        scheduler_run(self);
    }
};
