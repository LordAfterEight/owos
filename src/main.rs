#![no_std]
#![no_main]
extern crate alloc;

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

fn preload_text_file(path: &str, contents: &str) {
    let _ = owos::ofs::vfs::write_text(path, contents);
}

fn preload_binary_file(path: &str, bytes: &[u8], exec: bool) {
    if exec {
        let _ = owos::ofs::vfs::write_executable(path, bytes);
    } else {
        let _ = owos::ofs::vfs::replace_bytes(
            path,
            bytes,
            owos::ofs::FLAG_READ | owos::ofs::FLAG_WRTE,
        );
    }
}

fn preload_userspace_binaries() {
    preload_binary_file("hello.bin", include_bytes!("../libc/out/hello.bin"), true);
    preload_binary_file("tcc.bin", include_bytes!("../libc/out/tcc.bin"), true);
    preload_binary_file("crt0.o", include_bytes!("../libc/out/crt0.o"), false);
    preload_binary_file("libc.a", include_bytes!("../libc/out/libc.a"), false);
    preload_text_file("link.ld", include_str!("../libc/link.ld"));

    preload_text_file("hello.c", include_str!("../libc/hello.c"));
    preload_text_file("include/stddef.h", include_str!("../libc/include/stddef.h"));
    preload_text_file("include/stdarg.h", include_str!("../libc/include/stdarg.h"));
    preload_text_file("include/stdio.h", include_str!("../libc/include/stdio.h"));
    preload_text_file("include/stdlib.h", include_str!("../libc/include/stdlib.h"));
    preload_text_file("include/string.h", include_str!("../libc/include/string.h"));
    preload_text_file("include/unistd.h", include_str!("../libc/include/unistd.h"));
    preload_text_file("include/fcntl.h", include_str!("../libc/include/fcntl.h"));
    preload_text_file("include/errno.h", include_str!("../libc/include/errno.h"));
    preload_text_file(
        "include/owos/api.h",
        include_str!("../libc/include/owos/api.h"),
    );
    preload_text_file(
        "include/owos/print.h",
        include_str!("../libc/include/owos/print.h"),
    );
}

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
    owos::println!("Success");

    owos::kui::kdraw::init_backbuffer();

    owos::println!("Initializing fonts...");
    owos::kui::kfont::init();
    owos::println!("Done");

    owos::println!("Initializing GDT/IDT and timer...");
    owos::arch::init();
    owos::println!("Done");

    owos::println!("Preloading userspace binaries...");
    preload_userspace_binaries();
    owos::println!("Done");

    let mut scheduler = owos::proc::csched::CooperativeScheduler::init();

    scheduler.add_process::<owos::apps::compositor::Compositor>();
    scheduler.add_process::<owos::apps::memtracker::MemTracker>();
    scheduler.add_process::<owos::apps::runtime_runner::RuntimeRunner>();
    scheduler.add_process::<owos::drivers::ps2_mouse::Ps2MouseDriver>();
    scheduler.add_process::<owos::drivers::ps2::Ps2Driver>();
    scheduler.add_process::<owos::apps::shell::Shell>();

    #[cfg(feature = "autotest-cc")]
    owos::proc::create_spawn_task::<owos::apps::compiler::Compiler>(alloc::vec![
        alloc::string::String::from("hello.c"),
    ]);

    owos::arch::enable_interrupts();

    match scheduler.start() {
        Ok(()) => unreachable!("start() only returns on error"),
        Err(e) => panic!("scheduler exited: {:?}", e),
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

    panic::draw_panic_screen(info, &trace);

    loop {
        unsafe {
            core::arch::asm!("hlt");
        }
    }
}