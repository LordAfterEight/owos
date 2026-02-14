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
                var shell = owos.std.get_process_as(owos.shell.Shell, 0).?;
                shell.print("[PROC: ", 0x7777FF, false, &owos.c.OwOSFont_8x16);
                shell.print(self.processes[proc.id].?.name, 0xFFFFFF, false, &owos.c.OwOSFont_8x16);
                shell.print("]", 0x7777FF, false, &owos.c.OwOSFont_8x16);
                shell.println(" -> Initialized", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
                break;
            }
        }
    }

    pub fn kill_process(self: *CooperativeScheduler, pid: usize) void {
        var shell = owos.std.get_process_as(owos.shell.Shell, 0).?;
        if (self.processes[pid] != null) {
            const proc_name = self.processes[pid].?.name;
            self.processes[pid] = null;
            shell.print("Killed process: ", 0xFF7777, false, &owos.c.OwOSFont_8x16);
            shell.println(proc_name, 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
        } else {
            shell.print("No process with id: ", 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
            var buf = [_:0]u8{0} ** 5;
            owos.c.format(@ptrCast(&buf), "%d", pid);
            shell.println(&buf, 0xAAAAAA, false, &owos.c.OwOSFont_8x16);
        }
    }

    pub fn tick(self: *CooperativeScheduler) Result {
        for (0..MAX_PROCESSES) |slot| {
            if (self.processes[slot] != null and self.processes[slot].?.running == true) {
                const proc_result = self.processes[slot].?.tick();
                if (proc_result == 1 or proc_result == 0) {
                    const id = self.processes[slot].?.id;
                    self.processes[self.processes[slot].?.id] = null;
                    self.process_counter -= 1;
                    return Result {.exit_code = proc_result, .pid = id};
                }
            }
        }
        return Result {.exit_code = 2, .pid = 255};
    }

    pub fn run(self: *CooperativeScheduler) noreturn {
        owos.serial.println("Started cooperative scheduler");
        var result: Result = Result {.exit_code = 2, .pid = 255};
        while (result.exit_code == 2) {
            asm volatile ("hlt");
            result = self.tick();
            if (result.pid != 255) {
                owos.serial.print("Process PID:");
                owos.serial.print_dec_usize(result.pid);
                owos.serial.println(" stopped");
            }
        }
        while (true) asm volatile ("hlt");
    }
};
