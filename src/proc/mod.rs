pub mod csched;
pub mod registry;

pub trait Process {
    fn new() -> alloc::boxed::Box<Self> where Self: Sized;
    fn on_tick(&mut self) -> Result<ProcessEvent, ProcessError>;
    fn on_uninit(self: alloc::boxed::Box<Self>);
    fn on_init(&self);
    fn pid(&self) -> u32;
    fn name(&self) -> &'static str;
    fn set_pid(&mut self, pid: u32);
    fn set_name(&mut self, name: &'static str);
    fn status(&self) -> ProcessStatus;
    fn set_status(&mut self, status: ProcessStatus);
}

#[derive(PartialEq, Eq)]
pub enum ProcessEvent {
    Continue,
    Yielded,
    Closed(i8),
}

#[derive(core::fmt::Debug)]
pub enum ProcessError {
    Crashed(i8),
}

#[derive(PartialEq, Eq, Clone, Copy, core::fmt::Debug)]
pub enum ProcessStatus {
    Running,
    Frozen,
    Sleeping,
}