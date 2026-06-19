#![no_std]
#![no_main]
extern crate alloc;

use core::any::type_name_of_val;
use alloc::string::ToString;

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
    owos::kui::kdraw::GLOBAL_FB.call_once(|| owos::kui::kdraw::SyncFramebuffer(fb));
    let fb = owos::kui::kdraw::GLOBAL_FB.get().unwrap();
    owos::println!("Success");

    owos::println!("Initializing fonts...");
    owos::kui::kfont::init();
    owos::println!("Done");

    owos::kui::kbackground(fb);
    owos::kui::draw_text(10, 10, 20.0, &owos::kui::kfont::UIFONT_BOLD, owos::VERSION_STR, fb);

    let string = "Hello World!".to_string();
    let mut file = owos::ofs::PlaintextFile::new("TestFile.txt").expect("Failed to create file");
    file.write_bytes(&string.as_bytes());
    file.write_serde(&Data::new("Inside File"));

    owos::println!("{:#?}", file);
    owos::println!("{:?}", alloc::string::String::from_utf8(file.read_bytes(0).unwrap().to_vec()).unwrap());
    owos::println!("{:?}", file.read_serde::<Data>(1).unwrap());
    owos::println!("{:?}", alloc::string::String::from_utf8(file.read_bytes(1).unwrap().to_vec()).unwrap());
    owos::println!("{:?}", file.read_serde::<Data>(0).unwrap());

    loop { unsafe { core::arch::asm!("cli; hlt;") } }
}

#[panic_handler]
fn panic<'a, 'b>(info: &'a core::panic::PanicInfo<'b>) -> ! {
    owos::println!("Panic: {:?}", info);
    #[allow(static_mut_refs)]
    {
        owos::kui::kbackground(unsafe { owos::kui::kdraw::GLOBAL_FB.get().unwrap() });
        owos::kui::draw_text(20, 20, 30.0, &owos::kui::kfont::UIFONT_BOLD, "PANIC", unsafe { owos::kui::kdraw::GLOBAL_FB.get().unwrap() });
    }
    loop {}
}

#[derive(serde::Serialize, serde::Deserialize, Debug)]
struct Data {
    name: alloc::string::String,
}

impl Data {
    pub fn new(name: &str) -> Self {
        Self {
            name: name.to_string()
        }
    }
}