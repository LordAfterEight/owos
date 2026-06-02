#![no_std]
#![no_main]

#[used]
#[unsafe(link_section = ".limine_requests")]
static ENTRY_POINT: owos::limine::EntryPointRequest = owos::limine::entry_point_request(start);

#[used]
#[unsafe(link_section = ".limine_requests")]
static FRAMEBUFFER_REQUEST: owos::limine::FramebufferRequest = owos::limine::framebuffer_request();

#[used]
#[unsafe(link_section = ".limine_requests")]
static MEMMAP_REQUEST: owos::limine::MemoryMapRequest = owos::limine::memmap_request();

#[unsafe(no_mangle)]
extern "C" fn start() -> ! {
    owos::println!("Booting...");

    if FRAMEBUFFER_REQUEST.response.is_null() {
        owos::println!("No framebuffer response");
    }

    let mmap = MEMMAP_REQUEST.get_response().expect("Failed to get memory map response");
    owos::println!("Entries: {}", mmap.entry_count);

    let region = mmap.entries()
        .iter()
        .find(|e| unsafe { e.as_ref().unwrap().typ == 0 && e.as_ref().unwrap().length >= 0x100000000 })
        .expect("no suitable memory region");

    unsafe {
        let entry = region.as_ref().unwrap();
        owos::mem::ALLOCATOR.init(entry.base as *mut u8, entry.length as usize);
    }

    let key = [0u8; 32];
    let stream = chacha20poly1305_nostd::ChaCha20Poly1305::new(&key).expect("Failed to create stream");

    //let text = owos::alloc::String::<11>::create("Hello World");

    //let nonce = [0u8; 12];

    //let ciphertext = stream.encrypt(&nonce, text.as_str().as_bytes(), None);

    owos::println!("Hello, world!");
    loop {}
}

#[panic_handler]
fn panic<'a, 'b>(info: &'a core::panic::PanicInfo<'b>) -> ! {
    owos::println!("Panic: {:?}", info);
    loop {}
}