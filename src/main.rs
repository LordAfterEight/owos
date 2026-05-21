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

#[unsafe(no_mangle)]
extern "C" fn start() -> ! {
    let mut mem = Mem::init();
    let mut alloc = owos::mem::BumpAllocator::init(&mut mem.0);

    owos::drivers::serial::println("Hello, world!");

    loop {}
}

#[panic_handler]
fn panic<'a, 'b>(info: &'a core::panic::PanicInfo<'b>) -> ! {
    loop {}
}
