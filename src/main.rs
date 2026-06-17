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

#[used]
#[unsafe(link_section = ".limine_requests")]
static STACK_SIZE: owos::limine::StackSizeRequest = owos::limine::stack_size_request(1024 * 1024);

#[used]
#[unsafe(link_section = ".limine_requests")]
static HHDM_REQUEST: owos::limine::HhdmRequest = owos::limine::hhdm_request();

#[unsafe(no_mangle)]
extern "C" fn start() -> ! {
    owos::println!("Booting...");

    let hhdm = HHDM_REQUEST.get_response().expect("No HHDM Response");

    if FRAMEBUFFER_REQUEST.response.get().is_null() {
        owos::println!("No framebuffer response");
    }

    let mmap = MEMMAP_REQUEST.get_response().expect("Failed to get memory map response");
    owos::println!("Entries: {}", mmap.entry_count);

    let region = mmap.entries()
        .iter()
        .filter_map(|e| unsafe { (*e).as_ref() })
        .filter(|e| e.typ == 0)
        .max_by_key(|e| e.length)
        .expect("no suitable memory region");

    unsafe {
        owos::mem::ALLOCATOR.init((hhdm.offset + region.base) as *mut u8, region.length as usize);
    }


    let key = [0u8; 32];
    let stream = chacha20poly1305_nostd::ChaCha20Poly1305::new(&key).expect("Failed to create stream");

    let text = owos::alloc::String::<11>::create("Hello World");

    let nonce = [0u8; 12];

    let ciphertext = stream.encrypt(&nonce, text.as_str().as_bytes(), None).unwrap();


    owos::println!("Plaintext: {:?}\nEncrypted: {:?}", stream.decrypt(&nonce, &ciphertext, None).unwrap(), ciphertext);
    loop {}
}

#[panic_handler]
fn panic<'a, 'b>(info: &'a core::panic::PanicInfo<'b>) -> ! {
    owos::println!("Panic: {:?}", info);
    loop {}
}