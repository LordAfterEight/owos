use alloc::vec::Vec;

pub struct ProcTableEntry {
    pub pid: u32,
    pub name: &'static str,
    pub status: crate::proc::ProcessStatus,
}

pub static PROCESS_TABLE: spin::Mutex<Vec<ProcTableEntry>> =
    spin::Mutex::new(Vec::new());