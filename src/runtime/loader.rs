use core::arch::global_asm;
use core::sync::atomic::{AtomicBool, Ordering};

use super::kapi::{self, API_TABLE};
use super::output;

pub const JIT_LOAD_ADDR: u64 = 0xffff_ffff_8100_0000;
const MAX_PROGRAM_BYTES: usize = 4 * 1024 * 1024;
const DEFAULT_STACK_BYTES: usize = 0x10000;
const LARGE_STACK_BYTES: usize = 0x100000;
const DEFAULT_ARENA_SIZE: usize = 64 * 1024;
const LARGE_ARENA_SIZE: usize = 8 * 1024 * 1024;

/// Saved interrupt frame for preempt/resume (matches `arch::isr::IsrContext`).
#[repr(C, align(16))]
pub struct JitSavedContext {
    pub rax: u64,
    pub rcx: u64,
    pub rdx: u64,
    pub rsi: u64,
    pub rdi: u64,
    pub rbp: u64,
    pub r8: u64,
    pub r9: u64,
    pub r10: u64,
    pub r11: u64,
    pub r12: u64,
    pub r13: u64,
    pub r14: u64,
    pub r15: u64,
    pub vector: u64,
    pub error_code: u64,
    pub rip: u64,
    pub cs: u64,
    pub rflags: u64,
}

static mut JIT_RESUME_FRAME: JitSavedContext = JitSavedContext {
    rax: 0,
    rcx: 0,
    rdx: 0,
    rsi: 0,
    rdi: 0,
    rbp: 0,
    r8: 0,
    r9: 0,
    r10: 0,
    r11: 0,
    r12: 0,
    r13: 0,
    r14: 0,
    r15: 0,
    vector: 0,
    error_code: 0,
    rip: 0,
    cs: 0,
    rflags: 0,
};

static JIT_FRAME_VALID: AtomicBool = AtomicBool::new(false);
static SYSCALL_CTX_VALID: AtomicBool = AtomicBool::new(false);
static JIT_RUNNING: AtomicBool = AtomicBool::new(false);

const SLICE_SYSCALL_LIMIT: u64 = 8;
/// ~5M cycles ≈ 1–2 ms; force yield after long syscalls.
const SLICE_MAX_CYCLES: u64 = 5_000_000;
/// PIT runs at 100 Hz; 2 ticks ≈ 20 ms per JIT slice.
const JIT_SLICE_TICKS: u64 = 2;
static SYSCALL_BUDGET: core::sync::atomic::AtomicU64 =
    core::sync::atomic::AtomicU64::new(0);
static SLICE_START_TSC: core::sync::atomic::AtomicU64 =
    core::sync::atomic::AtomicU64::new(0);
static SLICE_START_TICK: core::sync::atomic::AtomicU64 =
    core::sync::atomic::AtomicU64::new(0);
static JIT_SYSCALL_LOGS: core::sync::atomic::AtomicU64 =
    core::sync::atomic::AtomicU64::new(0);

const JIT_EXEC_BYTES: u64 = (MAX_PROGRAM_BYTES + LARGE_STACK_BYTES) as u64;

/// Guest register snapshot at a syscall return boundary (SysV callee-saved + RSP + RAX).
#[repr(C)]
struct SyscallSliceCtx {
    rbx: u64,
    rbp: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rsp: u64,
    rax: u64,
}

pub fn reset_syscall_budget() {
    SYSCALL_BUDGET.store(SLICE_SYSCALL_LIMIT, Ordering::Release);
    SLICE_START_TSC.store(read_tsc(), Ordering::Release);
    SLICE_START_TICK.store(
        crate::arch::pit::TIMER_TICKS.load(Ordering::Acquire),
        Ordering::Release,
    );
    clear_syscall_yield_flag();
}

fn read_tsc() -> u64 {
    let lo: u32;
    let hi: u32;
    unsafe {
        core::arch::asm!(
            "rdtsc",
            out("eax") lo,
            out("edx") hi,
            options(nomem, nostack, preserves_flags)
        );
    }
    (hi as u64) << 32 | lo as u64
}

pub fn slice_time_expired() -> bool {
    if !jit_is_running() {
        return false;
    }
    let start = SLICE_START_TSC.load(Ordering::Acquire);
    read_tsc().saturating_sub(start) >= SLICE_MAX_CYCLES
}

pub fn slice_tick_expired() -> bool {
    if !jit_is_running() {
        return false;
    }
    let start = SLICE_START_TICK.load(Ordering::Acquire);
    let now = crate::arch::pit::TIMER_TICKS.load(Ordering::Acquire);
    now.saturating_sub(start) >= JIT_SLICE_TICKS
}

pub fn log_jit_syscall(name: &str) -> u64 {
    let _ = name;
    JIT_SYSCALL_LOGS.fetch_add(1, Ordering::Relaxed) + 1
}

pub fn reset_jit_syscall_count() {
    JIT_SYSCALL_LOGS.store(0, Ordering::Release);
}

pub fn jit_syscall_count() -> u64 {
    JIT_SYSCALL_LOGS.load(Ordering::Relaxed)
}

pub fn consume_syscall_budget() -> bool {
    if !jit_is_running() {
        return false;
    }
    loop {
        let left = SYSCALL_BUDGET.load(Ordering::Acquire);
        if left == 0 {
            return true;
        }
        if SYSCALL_BUDGET
            .compare_exchange_weak(left, left - 1, Ordering::AcqRel, Ordering::Relaxed)
            .is_ok()
        {
            return left == 1 || slice_time_expired();
        }
    }
}

pub fn set_syscall_yield_flag() {
    unsafe {
        core::ptr::addr_of_mut!(owos_syscall_yield_flag).write_volatile(1);
    }
}

pub fn clear_syscall_yield_flag() {
    unsafe {
        core::ptr::addr_of_mut!(owos_syscall_yield_flag).write_volatile(0);
    }
}

pub fn set_syscall_ctx_valid() {
    SYSCALL_CTX_VALID.store(true, Ordering::Release);
    JIT_FRAME_VALID.store(false, Ordering::Release);
}

pub fn jit_is_running() -> bool {
    JIT_RUNNING.load(Ordering::Relaxed)
}

pub fn is_jit_rip(rip: u64) -> bool {
    rip >= JIT_LOAD_ADDR && rip < JIT_LOAD_ADDR + JIT_EXEC_BYTES
}

unsafe fn enter_jit_run(entry: *mut u8, stack: *const u8) {
    JIT_RUNNING.store(true, Ordering::Release);
    owos_run_program(entry, stack);
    JIT_RUNNING.store(false, Ordering::Release);
}

unsafe fn enter_jit_resume() {
    JIT_RUNNING.store(true, Ordering::Release);
    owos_resume_jit(core::ptr::addr_of!(JIT_RESUME_FRAME));
    JIT_RUNNING.store(false, Ordering::Release);
}

unsafe fn enter_jit_resume_syscall() {
    JIT_RUNNING.store(true, Ordering::Release);
    owos_begin_jit_resume();
    JIT_RUNNING.store(false, Ordering::Release);
}

/// Program code must live in kernel image memory (RWX), not the heap. Limine maps
/// heap pages non-executable, so jumping into `Vec` backing storage faults forever.
/// Linked at JIT_LOAD_ADDR (see linker.ld + libc/link.ld).
#[repr(C, align(4096))]
struct ExecMemory {
    code: [u8; MAX_PROGRAM_BYTES],
    stack: [u8; LARGE_STACK_BYTES],
}

#[repr(C, align(16))]
struct StaticArena {
    bytes: [u8; LARGE_ARENA_SIZE],
}

#[unsafe(link_section = ".jit_exec")]
static mut EXEC: ExecMemory = ExecMemory {
    code: [0; MAX_PROGRAM_BYTES],
    stack: [0; LARGE_STACK_BYTES],
};

#[unsafe(link_section = ".jit_arena")]
static mut TCC_ARENA: StaticArena = StaticArena {
    bytes: [0; LARGE_ARENA_SIZE],
};

struct ArenaBacking {
    ptr: usize,
    heap_layout: Option<core::alloc::Layout>,
}

fn acquire_arena(arena_size: usize) -> Result<ArenaBacking, alloc::string::String> {
    if arena_size == LARGE_ARENA_SIZE {
        let ptr = unsafe { core::ptr::addr_of_mut!(TCC_ARENA.bytes) as usize };
        return Ok(ArenaBacking {
            ptr,
            heap_layout: None,
        });
    }

    let layout = core::alloc::Layout::from_size_align(arena_size, 16).map_err(|_| {
        alloc::string::String::from("runtime error: invalid arena layout")
    })?;
    let ptr = unsafe { alloc::alloc::alloc(layout) };
    if ptr.is_null() {
        return Err(alloc::string::String::from(
            "runtime error: arena alloc failed",
        ));
    }
    Ok(ArenaBacking {
        ptr: ptr as usize,
        heap_layout: Some(layout),
    })
}

fn release_arena(backing: ArenaBacking) {
    if let Some(layout) = backing.heap_layout {
        unsafe { alloc::alloc::dealloc(backing.ptr as *mut u8, layout) };
    }
}

global_asm!(
    r#"
    .section .bss
    .align 8
    .global owos_saved_kernel_rsp
    owos_saved_kernel_rsp:
        .space 8

    .align 8
    .global owos_syscall_ctx
    owos_syscall_ctx:
        .space 64

    .global owos_syscall_guest_rsp
    owos_syscall_guest_rsp:
        .space 8

    .global owos_syscall_yield_flag
    owos_syscall_yield_flag:
        .byte 0

    .align 8
    .global owos_kernel_jit_ctx
    owos_kernel_jit_ctx:
        .space 48

    .section .text

    .macro SYSCALL_TRAMP impl
    mov %rsp, owos_syscall_guest_rsp(%rip)
    mov %rbx, owos_syscall_ctx+0
    mov %rbp, owos_syscall_ctx+8
    mov %r12, owos_syscall_ctx+16
    mov %r13, owos_syscall_ctx+24
    mov %r14, owos_syscall_ctx+32
    mov %r15, owos_syscall_ctx+40
    call \impl
    mov %rax, owos_syscall_ctx+56
    cmpb $1, owos_syscall_yield_flag(%rip)
    jne .Lsyscall_done_\@
    movb $0, owos_syscall_yield_flag(%rip)
    mov owos_syscall_guest_rsp(%rip), %rax
    mov %rax, owos_syscall_ctx+48
    call owos_mark_preempted_from_asm
    mov $-2, %eax
    jmp owos_jit_return_to_kernel
.Lsyscall_done_\@:
    mov owos_syscall_ctx+0, %rbx
    mov owos_syscall_ctx+8, %rbp
    mov owos_syscall_ctx+16, %r12
    mov owos_syscall_ctx+24, %r13
    mov owos_syscall_ctx+32, %r14
    mov owos_syscall_ctx+40, %r15
    mov owos_syscall_guest_rsp(%rip), %rsp
    mov owos_syscall_ctx+56, %rax
    ret
    .endm

    .global owos_tramp_write
    .type owos_tramp_write, @function
    owos_tramp_write:
    SYSCALL_TRAMP owos_kern_write

    .global owos_tramp_alloc
    .type owos_tramp_alloc, @function
    owos_tramp_alloc:
    SYSCALL_TRAMP owos_kern_alloc

    .global owos_tramp_open
    .type owos_tramp_open, @function
    owos_tramp_open:
    SYSCALL_TRAMP owos_kern_open

    .global owos_tramp_read
    .type owos_tramp_read, @function
    owos_tramp_read:
    SYSCALL_TRAMP owos_kern_read

    .global owos_tramp_close
    .type owos_tramp_close, @function
    owos_tramp_close:
    SYSCALL_TRAMP owos_kern_close

    .global owos_tramp_lseek
    .type owos_tramp_lseek, @function
    owos_tramp_lseek:
    SYSCALL_TRAMP owos_kern_lseek

    .global owos_tramp_exit
    .type owos_tramp_exit, @function
    owos_tramp_exit:
    jmp owos_kern_exit
    .global owos_begin_jit_resume
    .type owos_begin_jit_resume, @function
    owos_begin_jit_resume:
        mov %rbx, owos_kernel_jit_ctx+0(%rip)
        mov %rbp, owos_kernel_jit_ctx+8(%rip)
        mov %r12, owos_kernel_jit_ctx+16(%rip)
        mov %r13, owos_kernel_jit_ctx+24(%rip)
        mov %r14, owos_kernel_jit_ctx+32(%rip)
        mov %r15, owos_kernel_jit_ctx+40(%rip)
        lea .Ljit_resume_done(%rip), %rax
        push %rax
        mov %rsp, owos_saved_kernel_rsp(%rip)
        jmp owos_resume_from_syscall
    .Ljit_resume_done:
        ret

    .global owos_jit_return_to_kernel
    .type owos_jit_return_to_kernel, @function
    owos_jit_return_to_kernel:
        mov owos_saved_kernel_rsp(%rip), %rsp
        mov owos_kernel_jit_ctx+0(%rip), %rbx
        mov owos_kernel_jit_ctx+8(%rip), %rbp
        mov owos_kernel_jit_ctx+16(%rip), %r12
        mov owos_kernel_jit_ctx+24(%rip), %r13
        mov owos_kernel_jit_ctx+32(%rip), %r14
        mov owos_kernel_jit_ctx+40(%rip), %r15
        sti
        ret

    .global owos_fault_resume
    .type owos_fault_resume, @function
    owos_fault_resume:
        mov $-1, %eax
        jmp owos_jit_return_to_kernel

    .global owos_preempt_resume
    .type owos_preempt_resume, @function
    owos_preempt_resume:
        mov $-2, %eax
        jmp owos_jit_return_to_kernel

    .global owos_resume_from_syscall
    .type owos_resume_from_syscall, @function
    owos_resume_from_syscall:
        mov owos_syscall_ctx+0, %rbx
        mov owos_syscall_ctx+8, %rbp
        mov owos_syscall_ctx+16, %r12
        mov owos_syscall_ctx+24, %r13
        mov owos_syscall_ctx+32, %r14
        mov owos_syscall_ctx+40, %r15
        mov owos_syscall_ctx+56, %rax
        mov owos_syscall_ctx+48, %rsp
        ret

    .global owos_resume_jit
    .type owos_resume_jit, @function
    owos_resume_jit:
        mov %rbx, owos_kernel_jit_ctx+0(%rip)
        mov %rbp, owos_kernel_jit_ctx+8(%rip)
        mov %r12, owos_kernel_jit_ctx+16(%rip)
        mov %r13, owos_kernel_jit_ctx+24(%rip)
        mov %r14, owos_kernel_jit_ctx+32(%rip)
        mov %r15, owos_kernel_jit_ctx+40(%rip)
        lea .Ljit_iret_return(%rip), %rax
        push %rax
        mov %rsp, owos_saved_kernel_rsp(%rip)
        mov %rdi, %rsp
        pop %r15
        pop %r14
        pop %r13
        pop %r12
        pop %r11
        pop %r10
        pop %r9
        pop %r8
        pop %rbp
        pop %rdi
        pop %rsi
        pop %rdx
        pop %rcx
        pop %rax
        add $16, %rsp
        iretq
    .Ljit_iret_return:
        ret

    .global owos_run_program
    .type owos_run_program, @function
    owos_run_program:
        mov %rbx, owos_kernel_jit_ctx+0(%rip)
        mov %rbp, owos_kernel_jit_ctx+8(%rip)
        mov %r12, owos_kernel_jit_ctx+16(%rip)
        mov %r13, owos_kernel_jit_ctx+24(%rip)
        mov %r14, owos_kernel_jit_ctx+32(%rip)
        mov %r15, owos_kernel_jit_ctx+40(%rip)
        mov %rsp, %rax
        mov %rax, owos_saved_kernel_rsp(%rip)
        push %rdi
        mov %rax, %rdi
        call owos_record_kernel_rsp
        pop %rdi
        mov %rsi, %rsp
        sti
        call *%rdi
        jmp owos_jit_return_to_kernel
    "#,
    options(att_syntax)
);

unsafe extern "C" {
    fn owos_record_kernel_rsp(rsp: u64);
}

unsafe extern "C" {
    static mut owos_saved_kernel_rsp: u64;
    static mut owos_syscall_yield_flag: u8;
    fn owos_begin_jit_resume();
    fn owos_run_program(entry: *mut u8, stack: *const u8);
    fn owos_fault_resume();
    fn owos_preempt_resume();
    fn owos_resume_jit(ctx: *const JitSavedContext);
    fn owos_resume_from_syscall();
    fn owos_tramp_write(fd: i32, buf: *const u8, count: usize) -> isize;
    fn owos_tramp_alloc(size: usize) -> *mut u8;
    fn owos_tramp_open(path: *const u8, flags: i32) -> i32;
    fn owos_tramp_read(fd: i32, buf: *mut u8, count: usize) -> isize;
    fn owos_tramp_close(fd: i32) -> i32;
    fn owos_tramp_lseek(fd: i32, offset: isize, whence: i32) -> isize;
    fn owos_tramp_exit(code: i32) -> !;
}

pub fn fault_resume_addr() -> u64 {
    owos_fault_resume as usize as u64
}

pub fn preempt_resume_addr() -> u64 {
    owos_preempt_resume as usize as u64
}

pub fn jit_preempt_from_isr(ctx: &mut crate::arch::isr::IsrContext) {
    const RFLAGS_IF: u64 = 1 << 9;
    unsafe {
        let src = ctx as *const crate::arch::isr::IsrContext as *const u8;
        let dst = core::ptr::addr_of_mut!(JIT_RESUME_FRAME) as *mut u8;
        core::ptr::copy_nonoverlapping(src, dst, core::mem::size_of::<JitSavedContext>());
        let frame = &mut *core::ptr::addr_of_mut!(JIT_RESUME_FRAME);
        frame.rflags |= RFLAGS_IF;
    }
    SYSCALL_CTX_VALID.store(false, Ordering::Release);
    JIT_FRAME_VALID.store(true, Ordering::Release);
    kapi::mark_preempted();
    ctx.rip = preempt_resume_addr();
}

pub enum RunSlice {
    Preempted,
    Done(i32, alloc::string::String),
}

pub struct PreemptibleSession {
    arena: ArenaBacking,
    arena_size: usize,
    entry: usize,
    stack_ptr: usize,
    waiting_resume: bool,
    finished: bool,
    started: bool,
}

impl Drop for PreemptibleSession {
    fn drop(&mut self) {
        if self.finished || !kapi::program_active() {
            return;
        }
        kapi::end_program();
        release_arena(core::mem::replace(
            &mut self.arena,
            ArenaBacking {
                ptr: 0,
                heap_layout: None,
            },
        ));
        JIT_FRAME_VALID.store(false, Ordering::Release);
        SYSCALL_CTX_VALID.store(false, Ordering::Release);
    }
}

impl PreemptibleSession {
    pub fn prepare(
        image: &ProgramImage,
        argv: &[&str],
        arena_size: usize,
    ) -> Result<Self, alloc::string::String> {
        if image.code.len() > MAX_PROGRAM_BYTES {
            return Err(alloc::string::String::from(
                "runtime error: executable too large",
            ));
        }

        let exec_addr = unsafe { core::ptr::addr_of!(EXEC) as u64 };
        if exec_addr != JIT_LOAD_ADDR {
            return Err(alloc::format!(
                "runtime error: JIT buffer at {exec_addr:#x}, expected {JIT_LOAD_ADDR:#x}"
            ));
        }

        let arena = acquire_arena(arena_size)?;

        let (entry, stack_ptr) = unsafe {
            let exec = &mut *core::ptr::addr_of_mut!(EXEC);
            exec.code[..image.code.len()].copy_from_slice(&image.code);
            let code = &mut exec.code[..image.code.len()];
            patch_api_table(code, image.api_offset)?;
            let stack_bytes = stack_size_for(argv.first().copied().unwrap_or(""));
            let rsp_offset = build_stack(argv, &mut exec.stack[..stack_bytes])?;
            let entry = exec.code.as_mut_ptr().add(image.entry);
            let stack_ptr = exec.stack.as_ptr().add(rsp_offset);
            (entry, stack_ptr)
        };

        Ok(Self {
            arena,
            arena_size,
            entry: entry as usize,
            stack_ptr: stack_ptr as usize,
            waiting_resume: false,
            finished: false,
            started: false,
        })
    }

    pub fn run_slice(&mut self) -> Result<RunSlice, alloc::string::String> {
        if self.finished {
            return Err(alloc::string::String::from(
                "runtime error: session already finished",
            ));
        }

        if self.waiting_resume {
            self.waiting_resume = false;
            reset_syscall_budget();
            let have_syscall = SYSCALL_CTX_VALID.load(Ordering::Acquire);
            let have_timer = JIT_FRAME_VALID.load(Ordering::Acquire);
            if !have_syscall && !have_timer {
                return Err(alloc::string::String::from(
                    "runtime error: missing JIT resume frame",
                ));
            }
            unsafe {
                if have_syscall {
                    enter_jit_resume_syscall();
                } else {
                    enter_jit_resume();
                }
            }
            return self.handle_return();
        }

        if !self.started {
            self.started = true;
            output::begin_capture();
            kapi::begin_program(self.arena.ptr as *mut u8, self.arena_size);
            reset_syscall_budget();
            unsafe {
                enter_jit_run(self.entry as *mut u8, self.stack_ptr as *const u8);
            }
            return self.handle_return();
        }

        Err(alloc::string::String::from(
            "runtime error: run_slice called with nothing to do",
        ))
    }

    fn handle_return(&mut self) -> Result<RunSlice, alloc::string::String> {
        if kapi::take_preempted() {
            self.waiting_resume = true;
            return Ok(RunSlice::Preempted);
        }

        if !kapi::program_exited() {
            let syscalls = kapi::jit_syscall_count();
            return Err(alloc::format!(
                "runtime error: guest returned without exit (syscalls={syscalls})"
            ));
        }

        let code = kapi::program_exit_code();

        let captured = output::take_capture();
        kapi::end_program();
        release_arena(core::mem::replace(
            &mut self.arena,
            ArenaBacking {
                ptr: 0,
                heap_layout: None,
            },
        ));
        JIT_FRAME_VALID.store(false, Ordering::Release);
        SYSCALL_CTX_VALID.store(false, Ordering::Release);
        self.finished = true;
        Ok(RunSlice::Done(code, captured))
    }
}

pub fn saved_kernel_rsp() -> u64 {
    unsafe { core::ptr::addr_of!(owos_saved_kernel_rsp).read_volatile() }
}

pub fn jit_return_to_kernel() -> ! {
    unsafe {
        core::arch::asm!(
            "jmp owos_jit_return_to_kernel",
            options(noreturn)
        );
    }
}

#[derive(Debug)]
pub struct ProgramImage {
    pub entry: usize,
    pub api_offset: usize,
    pub code: alloc::vec::Vec<u8>,
}

pub fn parse_bin(bytes: &[u8]) -> Result<ProgramImage, alloc::string::String> {
    if bytes.len() < 16 {
        return Err(alloc::string::String::from(
            "runtime error: executable too small",
        ));
    }
    let entry = u64::from_le_bytes(bytes[0..8].try_into().unwrap()) as usize;
    let api_offset = u64::from_le_bytes(bytes[8..16].try_into().unwrap()) as usize;
    let code = bytes[16..].to_vec();
    if entry >= code.len() {
        return Err(alloc::string::String::from(
            "runtime error: invalid executable entry",
        ));
    }
    Ok(ProgramImage {
        entry,
        api_offset,
        code,
    })
}

pub fn is_large_program(argv0: &str) -> bool {
    argv0 == "tcc.bin" || argv0 == "tcc"
}

pub fn arena_size_for(argv0: &str) -> usize {
    if is_large_program(argv0) {
        LARGE_ARENA_SIZE
    } else {
        DEFAULT_ARENA_SIZE
    }
}

pub fn stack_size_for(argv0: &str) -> usize {
    if is_large_program(argv0) {
        LARGE_STACK_BYTES
    } else {
        DEFAULT_STACK_BYTES
    }
}

pub fn load_and_run(
    image: &ProgramImage,
    argv: &[&str],
) -> Result<(i32, alloc::string::String), alloc::string::String> {
    load_and_run_with_arena(image, argv, arena_size_for(argv.first().copied().unwrap_or("")))
}

pub fn load_and_run_with_arena(
    image: &ProgramImage,
    argv: &[&str],
    arena_size: usize,
) -> Result<(i32, alloc::string::String), alloc::string::String> {
    if image.code.len() > MAX_PROGRAM_BYTES {
        return Err(alloc::string::String::from(
            "runtime error: executable too large",
        ));
    }

    let exec_addr = unsafe { core::ptr::addr_of!(EXEC) as u64 };
    if exec_addr != JIT_LOAD_ADDR {
        return Err(alloc::format!(
            "runtime error: JIT buffer at {exec_addr:#x}, expected {JIT_LOAD_ADDR:#x}"
        ));
    }

    output::begin_capture();

    let arena = acquire_arena(arena_size)?;

    let (entry, stack_ptr) = unsafe {
        let exec = &mut *core::ptr::addr_of_mut!(EXEC);
        exec.code[..image.code.len()].copy_from_slice(&image.code);
        let code = &mut exec.code[..image.code.len()];
        patch_api_table(code, image.api_offset)?;
        let stack_bytes = stack_size_for(argv.first().copied().unwrap_or(""));
        let rsp_offset = build_stack(argv, &mut exec.stack[..stack_bytes])?;
        let entry = exec.code.as_mut_ptr().add(image.entry);
        let stack_ptr = exec.stack.as_ptr().add(rsp_offset);
        (entry, stack_ptr)
    };

    let exit_code =
        unsafe { invoke_program(entry, stack_ptr, arena.ptr as *mut u8, arena_size) };
    let captured = output::take_capture();

    release_arena(arena);
    Ok((exit_code, captured))
}

fn patch_api_table(
    code: &mut [u8],
    api_offset: usize,
) -> Result<(), alloc::string::String> {
    if api_offset == 0 {
        return Err(alloc::string::String::from(
            "runtime error: missing owos_api offset",
        ));
    }
    if api_offset.saturating_add(8) > code.len() {
        return Err(alloc::string::String::from(
            "runtime error: owos_api offset out of range",
        ));
    }
    unsafe {
        let slot = code.as_mut_ptr().add(api_offset) as *mut *const kapi::OwosApi;
        core::ptr::write_volatile(slot, core::ptr::from_ref(&API_TABLE));
        let patched = core::ptr::read_volatile(slot);
        if patched.is_null() {
            return Err(alloc::string::String::from(
                "runtime error: owos_api patch failed",
            ));
        }
    }
    Ok(())
}

fn build_stack(argv: &[&str], stack: &mut [u8]) -> Result<usize, alloc::string::String> {
    // x86 stack grows down. Place argv/argc near the top of the buffer so
    // calls in crt0/main/write have room below the initial RSP.
    stack.fill(0);
    let base = stack.as_ptr() as usize;
    let mut top = stack.len();

    let mut argv_ptrs = alloc::vec::Vec::new();
    for arg in argv {
        let len = arg.len();
        if top < len + 1 {
            return Err(alloc::string::String::from(
                "runtime error: stack overflow while building argv strings",
            ));
        }
        top -= len + 1;
        stack[top..top + len].copy_from_slice(arg.as_bytes());
        stack[top + len] = 0;
        argv_ptrs.push(base + top);
    }

    top &= !0xF;
    let need = 8 + argv_ptrs.len() * 8 + 8;
    if top < need {
        return Err(alloc::string::String::from(
            "runtime error: stack overflow while building argv table",
        ));
    }

    top -= 8; // argv[argc] = NULL (already zero)

    for ptr in argv_ptrs.into_iter().rev() {
        top -= 8;
        unsafe {
            core::ptr::write(stack.as_mut_ptr().add(top) as *mut u64, ptr as u64);
        }
    }

    top -= 8;
    unsafe {
        core::ptr::write(
            stack.as_mut_ptr().add(top) as *mut u64,
            argv.len() as u64,
        );
    }

    Ok(top)
}

unsafe fn invoke_program(
    entry: *mut u8,
    stack: *const u8,
    arena_ptr: *mut u8,
    arena_size: usize,
) -> i32 {
    kapi::begin_program(arena_ptr, arena_size);
    enter_jit_run(entry, stack);

    let code = if kapi::program_exited() {
        kapi::program_exit_code()
    } else {
        0
    };
    kapi::end_program();
    code
}