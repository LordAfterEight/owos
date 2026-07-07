use core::arch::global_asm;

#[repr(C)]
pub struct IsrContext {
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

global_asm!(
    r#"
    .section .bss
    .align 16
    isr_ctx_ptr:
    .space 8
    isr_stack:
    .space 8192
    isr_stack_top:

    .section .text
    .align 16

    .macro PUSH_REGS
    push %rax
    push %rcx
    push %rdx
    push %rsi
    push %rdi
    push %rbp
    push %r8
    push %r9
    push %r10
    push %r11
    push %r12
    push %r13
    push %r14
    push %r15
    .endm

    .macro POP_REGS
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
    .endm

    .macro ISR_NOERRCODE num
    .global isr_\num
    .type isr_\num, @function
    isr_\num:
        push $0
        push $\num
        jmp isr_common
    .endm

    .macro ISR_ERRCODE num
    .global isr_\num
    .type isr_\num, @function
    isr_\num:
        push $\num
        jmp isr_common
    .endm

    ISR_NOERRCODE 0
    ISR_NOERRCODE 1
    ISR_NOERRCODE 2
    ISR_NOERRCODE 3
    ISR_NOERRCODE 4
    ISR_NOERRCODE 5
    ISR_NOERRCODE 6
    ISR_NOERRCODE 7
    ISR_ERRCODE 8
    ISR_ERRCODE 10
    ISR_ERRCODE 11
    ISR_ERRCODE 12
    ISR_ERRCODE 13
    ISR_ERRCODE 14
    ISR_NOERRCODE 16
    ISR_ERRCODE 17
    ISR_NOERRCODE 18
    ISR_NOERRCODE 19
    ISR_NOERRCODE 20
    ISR_ERRCODE 30
    ISR_NOERRCODE 32

    .global isr_common
    .type isr_common, @function
    isr_common:
        cli
        PUSH_REGS
        mov %rsp, isr_ctx_ptr(%rip)
        lea isr_stack_top(%rip), %rsp
        sub $8, %rsp
        mov isr_ctx_ptr(%rip), %rdi
        call isr_dispatch
        add $8, %rsp
        mov isr_ctx_ptr(%rip), %rsp
        POP_REGS
        add $16, %rsp
        iretq
    "#,
    options(att_syntax)
);

unsafe extern "C" {
    fn isr_0();
    fn isr_1();
    fn isr_2();
    fn isr_3();
    fn isr_4();
    fn isr_5();
    fn isr_6();
    fn isr_7();
    fn isr_8();
    fn isr_10();
    fn isr_11();
    fn isr_12();
    fn isr_13();
    fn isr_14();
    fn isr_16();
    fn isr_17();
    fn isr_18();
    fn isr_19();
    fn isr_20();
    fn isr_30();
    fn isr_32();
}

fn has_cpu_error_code(vector: u8) -> bool {
    matches!(vector, 8 | 10 | 11 | 12 | 13 | 14 | 17 | 30)
}

fn read_cr2() -> u64 {
    let cr2: u64;
    unsafe {
        core::arch::asm!("mov {}, cr2", out(reg) cr2, options(nostack, preserves_flags));
    }
    cr2
}

#[unsafe(no_mangle)]
extern "C" fn isr_dispatch(ctx: *mut IsrContext) {
    let ctx = unsafe { &mut *ctx };
    let vector = ctx.vector as u8;

    if vector == crate::arch::pic::PIC1_OFFSET {
        crate::arch::pit::on_tick();
        if crate::runtime::loader::jit_is_running()
            && crate::runtime::loader::is_jit_rip(ctx.rip)
            && crate::runtime::loader::slice_tick_expired()
        {
            crate::runtime::loader::jit_preempt_from_isr(ctx);
        }
        return;
    }

    if vector == 3 {
        ctx.rip = ctx.rip.saturating_add(1);
    }

    let error_code = if has_cpu_error_code(vector) {
        Some(ctx.error_code)
    } else if ctx.error_code != 0 {
        Some(ctx.error_code)
    } else {
        None
    };

    let fault_addr = if vector == 14 {
        Some(read_cr2())
    } else {
        None
    };

    crate::arch::faults::record(vector, ctx.rip, fault_addr, error_code);

    if crate::runtime::kapi::program_active()
        && matches!(vector, 6 | 8 | 12 | 13 | 14)
    {
        crate::runtime::kapi::abort_active_program(-1);
        ctx.rip = crate::runtime::loader::fault_resume_addr();
    }
}

pub fn handler_addr(vector: u8) -> u64 {
    let ptr: unsafe extern "C" fn() = match vector {
        0 => isr_0,
        1 => isr_1,
        2 => isr_2,
        3 => isr_3,
        4 => isr_4,
        5 => isr_5,
        6 => isr_6,
        7 => isr_7,
        8 => isr_8,
        10 => isr_10,
        11 => isr_11,
        12 => isr_12,
        13 => isr_13,
        14 => isr_14,
        16 => isr_16,
        17 => isr_17,
        18 => isr_18,
        19 => isr_19,
        20 => isr_20,
        30 => isr_30,
        32 => isr_32,
        _ => return 0,
    };
    ptr as usize as u64
}