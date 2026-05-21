#![no_std]
#![no_main]

pub struct Mem([u8; 65536]);

impl Mem {
    pub fn init() -> Self {
        Self {
            0: [0u8; 65536],
        }
    }
}

#[used]
#[unsafe(link_section = ".limine_requests")]
static ENTRY_POINT: owos::limine::limine::EntryPointRequest = owos::limine::limine::entry_point_request(start);

#[used]
#[unsafe(link_section = ".limine_requests")]
static FRAMEBUFFER_REQUEST: owos::limine::limine::FramebufferRequest = owos::limine::limine::framebuffer_request();

#[unsafe(no_mangle)]
extern "C" fn start() -> ! {
    let mut mem = Mem::init();
    let mut alloc = owos::mem::BumpAllocator::init(&mut mem.0);
    let key = [0u8; 32];
    let stream = chacha20poly1305_nostd::ChaCha20Poly1305::new(&key).expect("Failed to create stream");

    let text = owos::alloc::String::<11>::create("Hello World");

    let nonce = [0u8; 12];

    let ciphertext = stream.encrypt(&nonce, text.as_str().as_bytes(), None);

    owos::println!("Hello, world!");
    loop {}
}

#[panic_handler]
fn panic<'a, 'b>(info: &'a core::panic::PanicInfo<'b>) -> ! {
    owos::println!("Panic: {:?}", info);
    loop {}
}