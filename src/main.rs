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

#[allow(unused)]
#[derive(Default, Debug)]
struct Point {
    x: usize,
    y: usize,
}

#[allow(unused)]
#[derive(Default, Debug)]
struct Person {
    name: owos::alloc::String,
    age: u8
}

#[used]
#[unsafe(link_section = ".limine_requests")]
static ENTRY_POINT: owos::limine::limine::EntryPointRequest = owos::limine::limine::entry_point_request(start);

#[unsafe(no_mangle)]
extern "C" fn start() -> ! {
    let mut mem = Mem::init();
    let mut alloc = owos::mem::BumpAllocator::init(&mut mem.0);

    let mut point = alloc.alloc(Point {x: 10, y: 20}).unwrap();
    let person = alloc.alloc(Person {name: "Elias".into(), age: 18}).unwrap();
    point.x = 90;

    owos::drivers::serial::outb(owos::drivers::serial::COM1, b'H');

    loop {}
}

#[panic_handler]
fn panic<'a, 'b>(info: &'a core::panic::PanicInfo<'b>) -> ! {
    loop {}
}
