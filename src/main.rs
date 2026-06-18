#![no_std]
#![no_main]

use core::any::{type_name, type_name_of_val};

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
static STACK_SIZE: owos::limine::StackSizeRequest = owos::limine::stack_size_request(1024 * 1024 * 16); // 16 MiB of stack

#[used]
#[unsafe(link_section = ".limine_requests")]
static HHDM_REQUEST: owos::limine::HhdmRequest = owos::limine::hhdm_request();

#[unsafe(no_mangle)]
extern "C" fn start() -> ! {
    owos::println!("Getting Limine HHDM response...");
    let hhdm = HHDM_REQUEST.get_response().expect("Failed to get HHDM response");
    owos::println!("Success");

    owos::println!("Getting Limine MEMMAP response...");
    let mmap = MEMMAP_REQUEST.get_response().expect("Failed to get MEMMAP response");
    owos::println!("{} memory map entries found, finding biggest one...", mmap.entry_count);

    let region = mmap.entries()
        .iter()
        .filter_map(|e| unsafe { (*e).as_ref() })
        .filter(|e| e.typ == 0)
        .max_by_key(|e| e.length)
        .expect("No region found");
    owos::println!("Found region of size {} MiB", region.length as f32 / 1024.0 / 1024.0);

    owos::println!("Initializing GlobalAlloc with {}", type_name_of_val(&owos::mem::ALLOCATOR));
    unsafe {
        owos::mem::ALLOCATOR.init((hhdm.offset + region.base) as *mut u8, region.length as usize);
    }
    owos::println!("Success");

    owos::println!("Getting Limine framebuffer...");
    let fb_request = FRAMEBUFFER_REQUEST.get_response().expect("Failed to get Framebuffer response");
    let fb_ptrs = unsafe { core::slice::from_raw_parts(fb_request.framebuffers, fb_request.framebuffer_count as usize) };
    let fb = unsafe {&*fb_ptrs[0] };
    owos::println!("Success");
    owos::kui::kfont::init();

    owos::kui::kbackground(fb);
    owos::kui::draw_text(10, 10, 12.0, &owos::kui::kfont::UIFONT_BOLD, owos::VERSION_STR, fb);

    loop { unsafe { core::arch::asm!("cli; hlt;") } }
}

#[panic_handler]
fn panic<'a, 'b>(info: &'a core::panic::PanicInfo<'b>) -> ! {
    owos::println!("Panic: {:?}", info);
    loop {}
}