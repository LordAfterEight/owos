const std = @import("std");
const owos = @import("../root.zig");

pub var global_scheduler: CooperativeScheduler = .{
    .processes = [_]?*owos.process.Process{null} ** MAX_PROCESSES,
    .process_counter = 0,
};

const MAX_PROCESSES: usize = 16;

const Result = struct {
    exit_code: u8,
    pid: usize
};

pub const CooperativeScheduler = struct {
    processes: [MAX_PROCESSES]?*owos.process.Process,
    process_counter: u8,

    pub fn init() *CooperativeScheduler {
        owos.serial.println("Initialized cooperative scheduler");

        return &global_scheduler;
    }

    pub fn add_process(self: *CooperativeScheduler, proc: *owos.process.Process) void {
        for (0..MAX_PROCESSES) |slot| {
            owos.serial.print("Checking slot: ");
            owos.serial.print_dec_usize(slot);
                owos.serial.print("... ");
            if (self.processes[slot] != null) {
                owos.serial.print("Occupied by process: ");
                owos.serial.println(self.processes[slot].?.name);
            } else {
                owos.serial.println("Free");
                proc.id = slot;
                self.processes[slot] = proc;
                self.process_counter += 1;
                owos.serial.print("Added process \"");
                owos.serial.print(proc.name);
                owos.serial.print("\" with PID:");
                owos.serial.print_dec_usize(proc.id);
                owos.serial.println(" to cooperative scheduler");
                break;
            }
        }
    }

    pub fn kill_process(self: *CooperativeScheduler, pid: usize) void {
        if (self.processes[pid] != null) {
            self.processes[pid] = null;
        } else {
        }
    }

    pub fn tick(self: *CooperativeScheduler) u8 {
        for (0..MAX_PROCESSES) |slot| {
            if (self.processes[slot]) |proc| {
                if (proc.running) {
                    const proc_result = proc.tick() catch |err| {
                        owos.serial.print("Process crashed with error: ");
                        owos.serial.print(@errorName(err));
                        self.kill_process(slot);
                        continue;
                    };

                    if (proc_result == 0 or proc_result == 1) {
                        self.kill_process(slot);
                        self.process_counter -= 1;
                        return proc_result;
                    }
                }
            }
        }
        return 2;
    }


    pub fn scheduler_run(self: *CooperativeScheduler) callconv(.withStackAlign(.c, 16)) noreturn {
        owos.serial.println("Started cooperative scheduler");
        var exit_code: u8 = 2;
        while (exit_code == 2) {
            asm volatile ("hlt;");
            exit_code = self.tick();
        }
        while (true) asm volatile ("cli; hlt");
    }

    pub fn run(self: *CooperativeScheduler) noreturn {
        scheduler_run(self);
    }
};
