const owos = @import("../root.zig");

pub fn get_process_as(comptime T: type, pid: usize) ?*T {
    const proc_opt = owos.scheduler.global_scheduler.processes[pid];
    if (proc_opt) |proc| {
        // WARNING: This assumes you are correct about what T is at this PID!
        const ret: *T = @ptrCast(@alignCast(@constCast(proc.ctx)));
        return ret;
    }
    return null;
}
