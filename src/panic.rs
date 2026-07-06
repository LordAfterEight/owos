use core::arch::asm;

const MAX_FRAMES: usize = 32;

pub struct StackTrace {
    pub frames: [usize; MAX_FRAMES],
    pub count: usize,
}

#[inline(always)]
unsafe fn read_rbp() -> usize {
    let rbp: usize;
    unsafe { asm!("mov {}, rbp", out(reg) rbp) };
    rbp
}

#[inline(always)]
fn is_canonical(addr: usize) -> bool {
    let se = ((addr as isize) << 16) >> 16;
    se as usize == addr
}

pub unsafe fn walk_stack() -> StackTrace {
    let mut trace = StackTrace { frames: [0; MAX_FRAMES], count: 0 };
    let mut rbp = unsafe { read_rbp() };
    let mut prev_rbp = 0usize;

    while trace.count < MAX_FRAMES {
        if rbp == 0 || rbp % 8 != 0 || !is_canonical(rbp) {
            break;
        }
        if prev_rbp != 0 && rbp <= prev_rbp {
            break;
        }

        let ret_ptr = (rbp + 8) as *const usize;
        if !is_canonical(ret_ptr as usize) {
            break;
        }

        let return_addr = unsafe { core::ptr::read(ret_ptr) };
        if return_addr == 0 || !is_canonical(return_addr) {
            break;
        }

        trace.frames[trace.count] = return_addr;
        trace.count += 1;

        prev_rbp = rbp;
        rbp = unsafe { core::ptr::read(rbp as *const usize) };
    }

    trace
}

pub fn draw_panic_screen(info: &core::panic::PanicInfo, trace: &StackTrace) {
    if owos::kui::kdraw::GLOBAL_FB.get().is_none() {
        return;
    }

    let fb = owos::kui::kdraw::GLOBAL_FB.get().unwrap().0;
    let _width = fb.width as u32;
    let height = fb.height as u32;

    unsafe {
        core::ptr::write_bytes(fb.base, 0, (fb.pitch * fb.height) as usize);
    }

    owos::kui::ktitledwindow("KERNEL PANIC");

    let message = alloc::format!("{info:#?}");
    owos::kui::draw_text(
        30,
        75,
        12.0,
        &owos::kui::kfont::KODEMONO_REGULAR,
        &message,
        0xF3E600,
    );

    let trace_top = 275u32;
    let line_height = 18u32;
    let max_visible = height.saturating_sub(trace_top + 10) / line_height;
    let visible = trace.count.min(max_visible as usize);

    let mut trace_text = alloc::format!("Stack trace ({} frames):\n", trace.count);
    for (i, addr) in trace.frames[..visible].iter().enumerate() {
        trace_text.push_str(&alloc::format!("  #{i:<2}  {addr:#018x}\n"));
    }
    if visible < trace.count {
        trace_text.push_str(&alloc::format!(
            "  ... {} more (see serial output)\n",
            trace.count - visible
        ));
    }

    owos::kui::draw_text(
        30,
        trace_top as u32,
        12.0,
        &owos::kui::kfont::KODEMONO_REGULAR,
        &trace_text,
        0x55EAD4,
    );
}