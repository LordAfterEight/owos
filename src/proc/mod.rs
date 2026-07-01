pub mod csched;

pub trait Process {
    fn on_tick(&mut self) -> Result<ProcessEvent, ProcessError>;
    fn on_uninit(self: alloc::boxed::Box<Self>);
    fn on_init() where Self: Sized;
}

#[derive(PartialEq, Eq)]
pub enum ProcessEvent {
    Yielded,
    Closed(i8),
}

#[derive(core::fmt::Debug)]
pub enum ProcessError {
    Crashed(i8),
}