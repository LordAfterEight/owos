use alloc::boxed::Box;
use alloc::string::String;

pub mod csched;
pub mod registry;

pub trait Process {
    fn new() -> Box<Self>
    where
        Self: Sized;

    fn on_tick(&mut self) -> Result<ProcessEvent, ProcessError>;
    fn on_init(&self);
    fn on_uninit(self: Box<Self>);

    fn pid(&self) -> u32;
    fn name(&self) -> &'static str;
    fn status(&self) -> ProcessStatus;

    fn set_pid(&mut self, pid: u32);
    fn set_name(&mut self, name: &'static str);
    fn set_status(&mut self, status: ProcessStatus);

    fn receive(&mut self, data: IpcData) -> Result<(), IpcReceiveError>;
    fn bind(&mut self, subscriber: u32);
}

#[derive(PartialEq, Eq)]
pub enum ProcessEvent {
    Continue,
    Yielded,
    Closed(i8),
}

#[derive(Debug)]
pub enum ProcessError {
    Crashed(i8),
}

#[derive(PartialEq, Eq, Clone, Copy, Debug)]
pub enum ProcessStatus {
    Running,
    Frozen,
    Sleeping,
}

#[derive(Debug)]
pub enum IpcReceiveError {
    Concrete(Box<dyn core::any::Any + Send>),
    Message(&'static str),
}

#[derive(Debug)]
pub enum IpcData {
    Message(String),
    SendConfirmation(String),
    SendError(String),
    Payload(Box<dyn core::any::Any + Send>),
}

/// Queues a spawn request for a process of type `T`.
///
/// `T` must implement `Process + Send + 'static`.
/// The process will be spawned the next time the scheduler drains its command queue.
pub fn create_spawn_task<T: Process + Send + 'static>() {
    csched::SCHEDULER_COMMAND_QUEUE
        .lock()
        .push_back(csched::SchedulerTask::Spawn(Box::new(|| <T as Process>::new())));
}

pub fn create_ipc_task(sender_pid: u32, target_pid: u32, data: IpcData) {
    csched::SCHEDULER_COMMAND_QUEUE
        .lock()
        .push_back(csched::SchedulerTask::Send(sender_pid, target_pid, data));
}

pub fn create_binding_task(sender_pid: u32, target_pid: u32) {
    csched::SCHEDULER_COMMAND_QUEUE
        .lock()
        .push_back(csched::SchedulerTask::ConnectTo(sender_pid, target_pid));
}