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

    let mut sched = owos::proc::csched::CooperativeScheduler::init();

    sched.add_process(CounterProcess::new("counter-a", 5, 0));
    sched.add_process(HeartbeatProcess::new());
    sched.add_process(CrashyProcess::new(10));

    sched.start();

    loop { unsafe { core::arch::asm!("cli; hlt;") } }
}

#[panic_handler]
fn panic<'a, 'b>(info: &'a core::panic::PanicInfo<'b>) -> ! {
    owos::println!("Panic: {:?}", info);
    owos::kui::kbackground(owos::kui::kdraw::GLOBAL_FB.get().unwrap());
    owos::kui::draw_text(20, 20, 30.0, &owos::kui::kfont::ORBITRON_BOLD, "PANIC", 0xFF0000);
    loop {}
}


// ==== NOTE ====
// ! The following testing programs were written by Claude Sonnet 5 on 01.07.2026
// ! This is purely for testing and debugging purposes


use alloc::boxed::Box;
use owos::proc::{Process, ProcessEvent, ProcessError};

/// Runs for a fixed number of ticks, then closes with an exit code.
pub struct CounterProcess {
    name: &'static str,
    ticks_remaining: u32,
    exit_code: i8,
}

impl CounterProcess {
    pub fn new(name: &'static str, ticks: u32, exit_code: i8) -> Self {
        Self { name, ticks_remaining: ticks, exit_code }
    }
}

impl Process for CounterProcess {
    fn on_init() where Self: Sized {
        owos::println!("Counter process initialized");
    }

    fn on_tick(&mut self) -> Result<ProcessEvent, ProcessError> {
        if self.ticks_remaining == 0 {
            return Ok(ProcessEvent::Closed(self.exit_code));
        }
        self.ticks_remaining -= 1;
        owos::println!("{} tick, {} left", self.name, self.ticks_remaining);
        owos::kui::kdraw::draw_text(
            10,
            10,
            12.0,
            &owos::kui::kfont::ORBITRON_REGULAR,
            &alloc::format!("{} tick, {} left", self.name, self.ticks_remaining),
            0xFFFFFF
        );
        Ok(ProcessEvent::Yielded)
    }

    fn on_uninit(self: Box<Self>) {
        owos::println!("{} shutting down", self.name);
    }
}

/// Never closes, always yields — good for checking round-robin fairness.
pub struct HeartbeatProcess {
    beats: u64,
}

impl HeartbeatProcess {
    pub fn new() -> Self { Self { beats: 0 } }
}

impl Process for HeartbeatProcess {
    fn on_init() where Self: Sized {
        owos::println!("Heartbeat process initialized");
    }

    fn on_tick(&mut self) -> Result<ProcessEvent, ProcessError> {
        if self.beats % 10_000_000 == 0 {
            owos::println!("Beats: {}", self.beats);
            owos::kui::kdraw::draw_text(
                10,
                20,
                12.0,
                &owos::kui::kfont::SAIBA45,
                &alloc::format!("{}", self.beats),
                0xFFFFFF
            );
        }
        self.beats = self.beats.wrapping_add(1);
        Ok(ProcessEvent::Yielded)
    }

    fn on_uninit(self: Box<Self>) {}
}

/// Ticks a few times, then errors out — tests scheduler.start()'s Err path.
pub struct CrashyProcess {
    ticks_before_crash: u32,
}

impl CrashyProcess {
    pub fn new(ticks_before_crash: u32) -> Self {
        Self { ticks_before_crash }
    }
}

impl Process for CrashyProcess {
    fn on_init() where Self: Sized {
        owos::println!("Crashy process initialized");
    }

    fn on_tick(&mut self) -> Result<ProcessEvent, ProcessError> {
        owos::println!("Ticks before crash: {}", self.ticks_before_crash);
        owos::kui::kdraw::draw_text(
            10,
            30,
            12.0,
            &owos::kui::kfont::ORBITRON_REGULAR,
            &alloc::format!("Ticks before crash: {}", self.ticks_before_crash),
            0xFFFFFF
        );
        if self.ticks_before_crash == 0 {
            return Err(ProcessError::Crashed(-1));
        }
        self.ticks_before_crash -= 1;
        Ok(ProcessEvent::Yielded)
    }

    fn on_uninit(self: Box<Self>) {}
}