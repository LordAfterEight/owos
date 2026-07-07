use core::sync::atomic::{AtomicU64, AtomicU8, AtomicUsize, Ordering};

#[derive(Clone, Copy, Debug)]
pub struct FaultRecord {
    pub vector: u8,
    pub rip: u64,
    pub fault_addr: Option<u64>,
    pub error_code: Option<u64>,
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct FaultReport {
    pub vector: u8,
    pub name: alloc::string::String,
    pub rip: u64,
    pub fault_addr: Option<u64>,
    pub error_code: Option<u64>,
}

const RING_CAP: usize = 32;

static RING_HEAD: AtomicUsize = AtomicUsize::new(0);
static RING_TAIL: AtomicUsize = AtomicUsize::new(0);
static RING_VECTOR: [AtomicU8; RING_CAP] = [const { AtomicU8::new(0) }; RING_CAP];
static RING_RIP: [AtomicU64; RING_CAP] = [const { AtomicU64::new(0) }; RING_CAP];
static RING_FAULT_ADDR: [AtomicU64; RING_CAP] = [const { AtomicU64::new(0) }; RING_CAP];
static RING_ERROR: [AtomicU64; RING_CAP] = [const { AtomicU64::new(0) }; RING_CAP];
static RING_HAS_ERROR: [AtomicU8; RING_CAP] = [const { AtomicU8::new(0) }; RING_CAP];
static RING_HAS_FAULT_ADDR: [AtomicU8; RING_CAP] = [const { AtomicU8::new(0) }; RING_CAP];

static LAST_VECTOR: AtomicU8 = AtomicU8::new(0xFF);
static LAST_RIP: AtomicU64 = AtomicU64::new(0);

pub fn vector_name(vector: u8) -> &'static str {
    match vector {
        0 => "#DE Divide Error",
        1 => "#DB Debug",
        2 => "NMI",
        3 => "#BP Breakpoint",
        4 => "#OF Overflow",
        5 => "#BR Bound Range",
        6 => "#UD Invalid Opcode",
        7 => "#NM Device Not Available",
        8 => "#DF Double Fault",
        9 => "Coprocessor Segment Overrun",
        10 => "#TS Invalid TSS",
        11 => "#NP Segment Not Present",
        12 => "#SS Stack-Segment Fault",
        13 => "#GP General Protection",
        14 => "#PF Page Fault",
        16 => "#MF x87 FP Exception",
        17 => "#AC Alignment Check",
        18 => "#MC Machine Check",
        19 => "#XF SIMD FP Exception",
        20 => "#VE Virtualization Exception",
        30 => "#SX Security Exception",
        _ => "Unknown Exception",
    }
}

pub fn record(vector: u8, rip: u64, fault_addr: Option<u64>, error_code: Option<u64>) {
    if LAST_VECTOR.load(Ordering::Relaxed) == vector
        && LAST_RIP.load(Ordering::Relaxed) == rip
    {
        return;
    }
    LAST_VECTOR.store(vector, Ordering::Relaxed);
    LAST_RIP.store(rip, Ordering::Relaxed);

    let head = RING_HEAD.load(Ordering::Relaxed);
    let tail = RING_TAIL.load(Ordering::Relaxed);
    let next = (head + 1) % RING_CAP;
    if next == tail {
        return;
    }

    RING_VECTOR[head].store(vector, Ordering::Relaxed);
    RING_RIP[head].store(rip, Ordering::Relaxed);
    match fault_addr {
        Some(addr) => {
            RING_FAULT_ADDR[head].store(addr, Ordering::Relaxed);
            RING_HAS_FAULT_ADDR[head].store(1, Ordering::Relaxed);
        }
        None => RING_HAS_FAULT_ADDR[head].store(0, Ordering::Relaxed),
    }
    match error_code {
        Some(code) => {
            RING_ERROR[head].store(code, Ordering::Relaxed);
            RING_HAS_ERROR[head].store(1, Ordering::Relaxed);
        }
        None => {
            RING_HAS_ERROR[head].store(0, Ordering::Relaxed);
        }
    }
    RING_HEAD.store(next, Ordering::Release);
}

fn pop() -> Option<FaultRecord> {
    let tail = RING_TAIL.load(Ordering::Acquire);
    let head = RING_HEAD.load(Ordering::Acquire);
    if tail == head {
        return None;
    }

    let vector = RING_VECTOR[tail].load(Ordering::Relaxed);
    let rip = RING_RIP[tail].load(Ordering::Relaxed);
    let fault_addr = if RING_HAS_FAULT_ADDR[tail].load(Ordering::Relaxed) != 0 {
        Some(RING_FAULT_ADDR[tail].load(Ordering::Relaxed))
    } else {
        None
    };
    let error_code = if RING_HAS_ERROR[tail].load(Ordering::Relaxed) != 0 {
        Some(RING_ERROR[tail].load(Ordering::Relaxed))
    } else {
        None
    };
    RING_TAIL.store((tail + 1) % RING_CAP, Ordering::Release);

    Some(FaultRecord {
        vector,
        rip,
        fault_addr,
        error_code,
    })
}

pub fn drain_to_shell() {
    let shell_pid = crate::proc::registry::PROCESS_TABLE
        .lock()
        .iter()
        .find(|entry| entry.name == "Shell")
        .map(|entry| entry.pid);

    let Some(shell_pid) = shell_pid else {
        return;
    };

    while let Some(record) = pop() {
        let report = FaultReport {
            vector: record.vector,
            name: alloc::string::String::from(vector_name(record.vector)),
            rip: record.rip,
            fault_addr: record.fault_addr,
            error_code: record.error_code,
        };

        crate::proc::create_ipc_task(
            0,
            shell_pid,
            crate::proc::IpcData::Payload(alloc::boxed::Box::new(report)),
        );
    }
}