use core::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};

use super::fd::FdTable;
use super::output;

#[repr(C)]
pub struct OwosApi {
    pub write: extern "C" fn(i32, *const u8, usize) -> isize,
    pub exit: extern "C" fn(i32) -> !,
    pub alloc: extern "C" fn(usize) -> *mut u8,
    pub open: extern "C" fn(*const u8, i32) -> i32,
    pub read: extern "C" fn(i32, *mut u8, usize) -> isize,
    pub close: extern "C" fn(i32) -> i32,
    pub lseek: extern "C" fn(i32, isize, i32) -> isize,
}

struct ProgramRun {
    arena_base: usize,
    arena_size: usize,
    arena_used: usize,
    kernel_rsp: u64,
    fds: FdTable,
}

static PROG_ACTIVE: AtomicBool = AtomicBool::new(false);
static PROG_EXITED: AtomicBool = AtomicBool::new(false);
static PROG_PREEMPTED: AtomicBool = AtomicBool::new(false);
static PROG_EXIT_CODE: AtomicI32 = AtomicI32::new(0);

pub static PROGRAM_RUN: spin::Mutex<ProgramRun> = spin::Mutex::new(ProgramRun {
    arena_base: 0,
    arena_size: 0,
    arena_used: 0,
    kernel_rsp: 0,
    fds: FdTable::new(),
});

pub static API_TABLE: OwosApi = OwosApi {
    write: tramp_write,
    exit: tramp_exit,
    alloc: tramp_alloc,
    open: tramp_open,
    read: tramp_read,
    close: tramp_close,
    lseek: tramp_lseek,
};

unsafe extern "C" {
    fn owos_tramp_write(fd: i32, buf: *const u8, count: usize) -> isize;
    fn owos_tramp_alloc(size: usize) -> *mut u8;
    fn owos_tramp_open(path: *const u8, flags: i32) -> i32;
    fn owos_tramp_read(fd: i32, buf: *mut u8, count: usize) -> isize;
    fn owos_tramp_close(fd: i32) -> i32;
    fn owos_tramp_lseek(fd: i32, offset: isize, whence: i32) -> isize;
    fn owos_tramp_exit(code: i32) -> !;
}

extern "C" fn tramp_write(fd: i32, buf: *const u8, count: usize) -> isize {
    unsafe { owos_tramp_write(fd, buf, count) }
}

extern "C" fn tramp_alloc(size: usize) -> *mut u8 {
    unsafe { owos_tramp_alloc(size) }
}

extern "C" fn tramp_open(path: *const u8, flags: i32) -> i32 {
    unsafe { owos_tramp_open(path, flags) }
}

extern "C" fn tramp_read(fd: i32, buf: *mut u8, count: usize) -> isize {
    unsafe { owos_tramp_read(fd, buf, count) }
}

extern "C" fn tramp_close(fd: i32) -> i32 {
    unsafe { owos_tramp_close(fd) }
}

extern "C" fn tramp_lseek(fd: i32, offset: isize, whence: i32) -> isize {
    unsafe { owos_tramp_lseek(fd, offset, whence) }
}

extern "C" fn tramp_exit(code: i32) -> ! {
    unsafe { owos_tramp_exit(code) }
}

fn maybe_log_syscall(name: &str) {
    let n = crate::runtime::loader::log_jit_syscall(name);
    if n <= 8 || n % 64 == 0 {
        crate::klog::log(
            "JIT",
            &alloc::format!("syscall #{n} {name}"),
            crate::klog::MessageType::Info,
        );
    }
}

fn should_yield_after_syscall() -> bool {
    crate::runtime::loader::consume_syscall_budget()
        || crate::runtime::loader::slice_time_expired()
}

fn maybe_schedule_yield() {
    if should_yield_after_syscall() {
        crate::runtime::loader::set_syscall_yield_flag();
    }
}

/// After each guest syscall, optionally end the current scheduler slice.
#[inline(never)]
fn syscall_epilogue_isize(ret: isize) -> isize {
    maybe_schedule_yield();
    ret
}

#[inline(never)]
fn syscall_epilogue_i32(ret: i32) -> i32 {
    maybe_schedule_yield();
    ret
}

#[inline(never)]
fn syscall_epilogue_ptr(ret: *mut u8) -> *mut u8 {
    maybe_schedule_yield();
    ret
}

pub fn jit_syscall_count() -> u64 {
    crate::runtime::loader::jit_syscall_count()
}

pub fn begin_program(arena_base: *mut u8, arena_size: usize) {
    let mut run = PROGRAM_RUN.lock();
    run.arena_base = arena_base as usize;
    run.arena_size = arena_size;
    run.arena_used = 0;
    run.kernel_rsp = 0;
    run.fds.reset();
    drop(run);

    PROG_EXIT_CODE.store(0, Ordering::Release);
    PROG_EXITED.store(false, Ordering::Release);
    PROG_PREEMPTED.store(false, Ordering::Release);
    PROG_ACTIVE.store(true, Ordering::Release);
    crate::runtime::loader::reset_syscall_budget();
    crate::runtime::loader::reset_jit_syscall_count();
}

pub fn program_active() -> bool {
    PROG_ACTIVE.load(Ordering::Acquire)
}

pub fn abort_active_program(code: i32) {
    if !PROG_ACTIVE.load(Ordering::Acquire) {
        return;
    }
    PROG_EXIT_CODE.store(code, Ordering::Release);
    PROG_EXITED.store(true, Ordering::Release);
    PROG_PREEMPTED.store(false, Ordering::Release);
    PROG_ACTIVE.store(false, Ordering::Release);
}

pub fn mark_preempted() {
    if !PROG_ACTIVE.load(Ordering::Acquire) {
        return;
    }
    PROG_PREEMPTED.store(true, Ordering::Release);
}

pub fn take_preempted() -> bool {
    PROG_PREEMPTED.swap(false, Ordering::AcqRel)
}

pub fn program_exit_code() -> i32 {
    PROG_EXIT_CODE.load(Ordering::Acquire)
}

pub fn program_exited() -> bool {
    PROG_EXITED.load(Ordering::Acquire)
}

pub fn kernel_rsp_for_abort() -> u64 {
    let run = PROGRAM_RUN.lock();
    if run.kernel_rsp != 0 {
        run.kernel_rsp
    } else {
        crate::runtime::loader::saved_kernel_rsp()
    }
}

pub fn end_program() {
    PROG_ACTIVE.store(false, Ordering::Release);
    PROG_EXITED.store(false, Ordering::Release);
    PROG_PREEMPTED.store(false, Ordering::Release);
    PROG_EXIT_CODE.store(0, Ordering::Release);

    let mut run = PROGRAM_RUN.lock();
    run.arena_base = 0;
    run.arena_size = 0;
    run.arena_used = 0;
    run.kernel_rsp = 0;
    run.fds.reset();
}

#[unsafe(no_mangle)]
pub extern "C" fn owos_record_kernel_rsp(rsp: u64) {
    PROGRAM_RUN.lock().kernel_rsp = rsp;
}

#[unsafe(no_mangle)]
pub extern "C" fn owos_mark_preempted_from_asm() {
    mark_preempted();
    crate::runtime::loader::set_syscall_ctx_valid();
}

#[unsafe(no_mangle)]
pub extern "C" fn owos_kern_write(fd: i32, buf: *const u8, count: usize) -> isize {
    maybe_log_syscall("write");
    syscall_epilogue_isize(output::write_fd(fd, buf, count))
}

#[unsafe(no_mangle)]
pub extern "C" fn owos_kern_alloc(size: usize) -> *mut u8 {
    let mut run = PROGRAM_RUN.lock();
    if !PROG_ACTIVE.load(Ordering::Acquire) {
        return syscall_epilogue_ptr(core::ptr::null_mut());
    }
    let aligned = (size + 15) & !15;
    if run.arena_used.saturating_add(aligned) > run.arena_size {
        drop(run);
        return syscall_epilogue_ptr(core::ptr::null_mut());
    }
    let ptr = run.arena_base + run.arena_used;
    run.arena_used += aligned;
    drop(run);
    maybe_log_syscall("alloc");
    syscall_epilogue_ptr(ptr as *mut u8)
}

#[unsafe(no_mangle)]
pub extern "C" fn owos_kern_open(path: *const u8, flags: i32) -> i32 {
    if path.is_null() {
        return syscall_epilogue_i32(-1);
    }
    let path = cstr_to_string(path);
    maybe_log_syscall("open");
    let fd = {
        let mut run = PROGRAM_RUN.lock();
        run.fds.open(&path, flags).unwrap_or(-1)
    };
    syscall_epilogue_i32(fd)
}

#[unsafe(no_mangle)]
pub extern "C" fn owos_kern_read(fd: i32, buf: *mut u8, count: usize) -> isize {
    maybe_log_syscall("read");
    let ret = {
        let mut run = PROGRAM_RUN.lock();
        run.fds.read(fd, buf, count)
    };
    syscall_epilogue_isize(ret)
}

#[unsafe(no_mangle)]
pub extern "C" fn owos_kern_close(fd: i32) -> i32 {
    let ret = {
        let mut run = PROGRAM_RUN.lock();
        match run.fds.close(fd) {
            Ok(()) => 0,
            Err(code) => code,
        }
    };
    syscall_epilogue_i32(ret)
}

#[unsafe(no_mangle)]
pub extern "C" fn owos_kern_lseek(fd: i32, offset: isize, whence: i32) -> isize {
    let ret = {
        let mut run = PROGRAM_RUN.lock();
        run.fds.lseek(fd, offset, whence)
    };
    syscall_epilogue_isize(ret)
}

fn cstr_to_string(ptr: *const u8) -> alloc::string::String {
    unsafe {
        let mut len = 0usize;
        while *ptr.add(len) != 0 {
            len += 1;
            if len > 4096 {
                return alloc::string::String::new();
            }
        }
        let bytes = core::slice::from_raw_parts(ptr, len);
        core::str::from_utf8(bytes)
            .map(alloc::string::String::from)
            .unwrap_or_default()
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn owos_kern_exit(code: i32) -> ! {
    maybe_log_syscall("exit");
    let resume_rsp = {
        PROG_EXIT_CODE.store(code, Ordering::Release);
        PROG_EXITED.store(true, Ordering::Release);
        PROG_PREEMPTED.store(false, Ordering::Release);
        PROG_ACTIVE.store(false, Ordering::Release);
        let run = PROGRAM_RUN.lock();
        run.kernel_rsp
    };
    let _ = resume_rsp;
    unsafe {
        crate::runtime::loader::jit_return_to_kernel();
    }
}