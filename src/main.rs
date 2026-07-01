#![no_std]
#![no_main]
extern crate alloc;

use alloc::string::ToString;
use core::any::type_name_of_val;
mod panic;

#[used]
#[unsafe(link_section = ".limine_requests")]
static ENTRY_POINT: owos::limine::EntryPointRequest = owos::limine::entry_point_request(start);

#[used]
#[unsafe(link_section = ".limine_requests")]
static FRAMEBUFFER_REQUEST: owos::limine::FramebufferRequest = owos::limine::framebuffer_request();

#[used]
#[unsafe(link_section = ".limine_requests")]
static MEMMAP_REQUEST: owos::limine::MemoryMapRequest = owos::limine::memmap_request();

#[used]
#[unsafe(link_section = ".limine_requests")]
static STACK_SIZE: owos::limine::StackSizeRequest =
    owos::limine::stack_size_request(1024 * 1024 * 16); // 16 MiB of stack

#[used]
#[unsafe(link_section = ".limine_requests")]
static HHDM_REQUEST: owos::limine::HhdmRequest = owos::limine::hhdm_request();

static PANICKING: core::sync::atomic::AtomicBool = core::sync::atomic::AtomicBool::new(false);

fn enable_sse() {
    unsafe {
        core::arch::asm!(
            "mov rax, cr0
            and rax, ~(1 << 2)
            or  rax, (1 << 1)
            mov cr0, rax

            mov rax, cr4
            or  rax, (1 << 9)
            or  rax, (1 << 10)
            mov cr4, rax"
        );
    }
}

#[unsafe(no_mangle)]
extern "C" fn start() -> ! {
    enable_sse();
    owos::println!("Getting Limine HHDM response...");
    let hhdm = HHDM_REQUEST
        .get_response()
        .expect("Failed to get HHDM response");
    owos::println!("Success");

    owos::println!("Getting Limine MEMMAP response...");
    let mmap = MEMMAP_REQUEST
        .get_response()
        .expect("Failed to get MEMMAP response");
    owos::println!(
        "{} memory map entries found, finding biggest one...",
        mmap.entry_count
    );

    let region = mmap
        .entries()
        .iter()
        .filter_map(|e| unsafe { (*e).as_ref() })
        .filter(|e| e.typ == 0)
        .max_by_key(|e| e.length)
        .expect("No region found");
    owos::println!(
        "Found region of size {} MiB",
        region.length as f32 / 1024.0 / 1024.0
    );

    owos::println!(
        "Initializing GlobalAlloc with {}",
        type_name_of_val(&owos::mem::ALLOCATOR)
    );
    unsafe {
        owos::mem::ALLOCATOR.init(
            (hhdm.offset + region.base) as *mut u8,
            region.length as usize,
        );
    }
    owos::println!("Success");

    owos::println!("Getting Limine framebuffer...");
    let fb_request = FRAMEBUFFER_REQUEST
        .get_response()
        .expect("Failed to get Framebuffer response");
    let fb_ptrs = unsafe {
        core::slice::from_raw_parts(
            fb_request.framebuffers,
            fb_request.framebuffer_count as usize,
        )
    };
    let fb = unsafe { &*fb_ptrs[0] };
    owos::kui::kdraw::GLOBAL_FB.call_once(|| owos::kui::kdraw::SyncFramebuffer(fb));
    let fb = owos::kui::kdraw::GLOBAL_FB.get().unwrap();
    owos::println!("Success");

    owos::println!("Initializing fonts...");
    owos::kui::kfont::init();
    owos::println!("Done");

    owos::kui::ktitledwindow(&alloc::format!("OwOS v{}", env!("CARGO_PKG_VERSION")));
    let mut sched = owos::proc::csched::CooperativeScheduler::init();
    sched.start();

    loop {
        unsafe { core::arch::asm!("cli; hlt;") }
    }
}

#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    unsafe {
        core::arch::asm!("cli", options(nomem, nostack));
    }

    if PANICKING.swap(true, core::sync::atomic::Ordering::SeqCst) {
        owos::println!("DOUBLE PANIC - halting");
        loop {
            unsafe {
                core::arch::asm!("hlt");
            }
        }
    }

    owos::println!("================ KERNEL PANIC ================");
    owos::println!("{info:#?}");

    let trace = unsafe { panic::walk_stack() };
    owos::println!("Stack trace ({} frames):", trace.count);
    for (i, addr) in trace.frames[..trace.count].iter().enumerate() {
        owos::println!("  #{i:<2}  {addr:#018x}");
    }
    owos::println!("================================================");

    draw_panic_screen(info, &trace);

    loop {
        unsafe {
            core::arch::asm!("hlt");
        }
    }
}

fn draw_panic_screen(info: &core::panic::PanicInfo, trace: &panic::StackTrace) {
    if owos::kui::kdraw::GLOBAL_FB.get().is_none() {
        return;
    }

    let fb = owos::kui::kdraw::GLOBAL_FB.get().unwrap().0;
    let width = fb.width as u32;
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
