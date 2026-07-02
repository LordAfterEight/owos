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
    let mut scheduler = owos::proc::csched::CooperativeScheduler::init();

    scheduler.add_process::<ProcessTracker>();

    match scheduler.start() {
        Ok(()) => unreachable!("start() only returns on error"),
        Err(e) => owos::println!("scheduler exited: {:?}", e),
    }

    loop {
        unsafe {
            core::arch::asm!("cli; hlt;");
        }
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



pub struct ProcessTracker {
    pid: u32,
    name: &'static str,
    status: owos::proc::ProcessStatus,
    tick_count: u32,
    report_every: u32,
}

impl owos::proc::Process for ProcessTracker {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            pid: 0,
            name: "ProcessTracker",
            status: owos::proc::ProcessStatus::Running,
            tick_count: 0,
            report_every: 1_000_000,
        })
    }

    fn on_init(&self) {
        owos::println!("[{}] init (pid {})", self.name, self.pid);
        owos::kui::ktitledwindow("Process Tracker");
    }

    fn on_tick(&mut self) -> Result<owos::proc::ProcessEvent, owos::proc::ProcessError> {
        self.tick_count += 1;
        if self.tick_count % self.report_every == 0 {
            let table = owos::proc::registry::PROCESS_TABLE.lock();
            owos::println!("--- {} processes alive ---", table.len());
            for (i, entry) in table.iter().enumerate() {
                owos::println!(
                    "  pid {:>3}  {:<16} {:?}",
                    entry.pid,
                    entry.name,
                    entry.status
                );
                let text =
                    &alloc::format!("PID: {} | {} | {:?}", entry.pid, entry.name, entry.status);
                owos::kui::draw_rect(
                    20,
                    65 + i as u32 * 15,
                    owos::kui::kdraw::text_length(text, &owos::kui::kfont::KODEMONO_BOLD, 15.0) as u32,
                    18,
                    15,
                    0
                );
                owos::kui::draw_text(
                    20,
                    65 + i as u32 * 15,
                    15.0,
                    &owos::kui::kfont::KODEMONO_BOLD,
                    text,
                    0x55EAD4,
                );
            }
        }
        Ok(owos::proc::ProcessEvent::Yielded)
    }

    fn on_uninit(self: alloc::boxed::Box<Self>) {
        owos::println!("[{}] uninit", self.name);
    }

    fn pid(&self) -> u32 {
        self.pid
    }
    fn name(&self) -> &'static str {
        self.name
    }
    fn set_pid(&mut self, pid: u32) {
        self.pid = pid;
    }
    fn set_name(&mut self, name: &'static str) {
        self.name = name;
    }
    fn status(&self) -> owos::proc::ProcessStatus {
        self.status
    }
    fn set_status(&mut self, status: owos::proc::ProcessStatus) {
        self.status = status;
    }
}
