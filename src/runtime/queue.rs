use super::loader::ProgramImage;

#[derive(Debug)]
pub struct RunRequest {
    pub image: ProgramImage,
    pub argv: alloc::vec::Vec<alloc::string::String>,
    pub reply_pid: u32,
}

#[derive(Debug)]
pub struct RunComplete {
    pub exit_code: i32,
    pub output: alloc::string::String,
    pub error: Option<alloc::string::String>,
}

pub static RUN_QUEUE: spin::Mutex<Option<RunRequest>> = spin::Mutex::new(None);

pub fn queue_run(
    image: ProgramImage,
    argv: alloc::vec::Vec<alloc::string::String>,
    reply_pid: u32,
) {
    *RUN_QUEUE.lock() = Some(RunRequest {
        image,
        argv,
        reply_pid,
    });
}