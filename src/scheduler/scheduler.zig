const owos = @import("../root.zig");

const Result = struct {
    exit_code: u8,
    pid: u32
};

pub const CooperativeScheduler = struct {
    processes: [4]?owos.process.Process,
    process_counter: u8,

    pub fn init() CooperativeScheduler {
        const scheduler = CooperativeScheduler {
            .processes = undefined,
            .process_counter = 0,
        };

        owos.serial.println("Initialized preemptive scheduler");

        return scheduler;
    }

    pub fn add_process(self: *CooperativeScheduler, proc: owos.process.Process) void {
        self.processes[self.process_counter] = proc;
        self.process_counter += 1;
        owos.serial.print("Added process \"");
        owos.serial.print(proc.name);
        owos.serial.print("\" with PID:");
        owos.serial.println_dec_usize(proc.id);
    }

    pub fn tick(self: *CooperativeScheduler) Result {
        for (self.processes) |process| {
            if (process != null) {
                const proc_result = process.?.tick();
                if (proc_result == 1 or proc_result == 0) {
                    const id = process.?.id;
                    self.processes[process.?.id] = null;
                    return Result {.exit_code = proc_result, .pid = id};
                }
            }
        }
        return Result {.exit_code = 2, .pid = 255};
    }

    pub fn run(self: *CooperativeScheduler) noreturn {
        var result: Result = Result {.exit_code = 2, .pid = 255};
        while (result.exit_code == 2) {
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
