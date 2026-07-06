use alloc::string::ToString;

pub static SCHEDULER_COMMAND_QUEUE: spin::Mutex<alloc::collections::VecDeque<SchedulerTask>> =
    spin::Mutex::new(alloc::collections::VecDeque::new());

pub struct CooperativeScheduler {
    pid_counter: u32,
    procs: alloc::vec::Vec<alloc::boxed::Box<dyn crate::proc::Process>>,
}

impl CooperativeScheduler {
    pub fn init() -> Self {
        Self {
            pid_counter: 0,
            procs: alloc::vec::Vec::new(),
        }
    }

    pub fn add_process<T: crate::proc::Process + 'static>(&mut self) {
        let mut process = T::new();
        process.set_pid(self.pid_counter);
        self.pid_counter += 1;

        crate::klog::log(
            "Cooperative Scheduler",
            &alloc::format!(
                "Initialized process: {} | PID {}",
                process.name(),
                process.pid()
            ),
            crate::klog::MessageType::Info
        );

        crate::proc::registry::PROCESS_TABLE
            .lock()
            .push(crate::proc::registry::ProcTableEntry {
                pid: process.pid(),
                name: process.name(),
                status: crate::proc::ProcessStatus::Running,
            });

        process.on_init();
        self.procs.push(process);
    }

    pub fn process_tasks(&mut self) {
        let mut queue = SCHEDULER_COMMAND_QUEUE.lock();
        while let Some(cmd) = queue.pop_front() {
            match cmd {
                SchedulerTask::Freeze(pid) => {
                    if let Some(p) = self.procs.iter_mut().find(|p| p.pid() == pid) {
                        p.set_status(crate::proc::ProcessStatus::Frozen);
                    }
                }
                SchedulerTask::Unfreeze(pid) => {
                    if let Some(p) = self.procs.iter_mut().find(|p| p.pid() == pid) {
                        p.set_status(crate::proc::ProcessStatus::Running);
                    }
                }
                SchedulerTask::Kill(pid) => {
                    if let Some(idx) = self.procs.iter().position(|p| p.pid() == pid) {
                        let process = self.procs.remove(idx);
                        crate::proc::registry::PROCESS_TABLE
                            .lock()
                            .retain(|e| e.pid != pid);
                        crate::klog::log(
                            "Cooperative Scheduler",
                            &alloc::format!(
                                "Killing process: {} | PID {}",
                                process.name(),
                                process.pid()
                            ),
                            crate::klog::MessageType::Info
                        );
                        process.on_uninit();
                    }
                }
                SchedulerTask::Spawn(ctor) => {
                    let mut process = ctor();

                    process.set_pid(self.pid_counter);
                    self.pid_counter += 1;

                    crate::klog::log(
                        "Cooperative Scheduler",
                        &alloc::format!(
                            "Spawned process: {} | PID {}",
                            process.name(),
                            process.pid()
                        ),
                        crate::klog::MessageType::Info
                    );

                    crate::proc::registry::PROCESS_TABLE.lock().push(
                        crate::proc::registry::ProcTableEntry {
                            pid: process.pid(),
                            name: process.name(),
                            status: crate::proc::ProcessStatus::Running,
                        },
                    );

                    process.on_init();
                    self.procs.push(process);
                }
                SchedulerTask::Send(sender_pid, target_pid, data) => {
                    let entry = match self.procs.iter_mut().find(|p| p.pid() == target_pid) {
                        Some(entry) => entry,
                        None => {
                            _ = self.procs[sender_pid as usize].receive(
                                crate::proc::IpcData::SendError(alloc::format!(
                                    "Invalid PID: {target_pid}"
                                )),
                            );
                            continue;
                        }
                    };
                    match entry.receive(data) {
                        Ok(_) => {
                            let _ = self.procs[sender_pid as usize].receive(
                                crate::proc::IpcData::SendConfirmation(
                                    "Payload sent successfully".to_string(),
                                ),
                            );
                        }
                        Err(e) => {
                            let _ = self.procs[sender_pid as usize].receive(
                                crate::proc::IpcData::SendError(alloc::format!(
                                    "Send failed: {e:?}"
                                )),
                            );
                        }
                    }
                },
                SchedulerTask::ConnectTo(sender_pid, target_pid) => {
                    let entry = match self.procs.iter_mut().find(|p| p.pid() == target_pid) {
                        Some(entry) => entry,
                        None => {
                            _ = self.procs[sender_pid as usize].receive(
                                crate::proc::IpcData::SendError(alloc::format!(
                                    "Invalid PID: {target_pid}"
                                )),
                            );
                            continue;
                        }
                    };
                    entry.bind(sender_pid);
                }
            }
        }
    }

    pub fn start(&mut self) -> Result<(), SchedulerError<crate::proc::ProcessError>> {
        loop {
            self.process_tasks();
            let mut i = 0;
            while i < self.procs.len() {
                if self.procs[i].status() != crate::proc::ProcessStatus::Running {
                    i += 1;
                    continue;
                }
                let mut removed = false;
                loop {
                    match self.procs[i].on_tick() {
                        Err(err) => {
                            let proc = self.procs.remove(i);
                            crate::proc::registry::PROCESS_TABLE
                                .lock()
                                .retain(|e| e.pid != proc.pid());
                            proc.on_uninit();
                            crate::klog::log(
                                "Cooperative Scheduler",
                                &alloc::format!("Process exited with error {:?}", err),
                                crate::klog::MessageType::Error
                            );
                            break;
                        }
                        Ok(crate::proc::ProcessEvent::Yielded) => break,
                        Ok(crate::proc::ProcessEvent::Closed(_code)) => {
                            let proc = self.procs.remove(i);
                            crate::proc::registry::PROCESS_TABLE
                                .lock()
                                .retain(|e| e.pid != proc.pid());
                            crate::klog::log(
                                "Cooperative Scheduler",
                                &alloc::format!(
                                    "Process closed: {} | PID {}",
                                    proc.name(),
                                    proc.pid()
                                ),
                                crate::klog::MessageType::Error
                            );
                            proc.on_uninit();
                            removed = true;
                            break;
                        }
                        Ok(crate::proc::ProcessEvent::Continue) => continue,
                    }
                }
                if removed {
                    continue;
                }

                let pid = self.procs[i].pid();
                let status = self.procs[i].status();
                if let Some(entry) = crate::proc::registry::PROCESS_TABLE
                    .lock()
                    .iter_mut()
                    .find(|e| e.pid == pid)
                {
                    entry.status = status;
                }
                i += 1;
            }
            if self.procs.is_empty() {
                return Err(SchedulerError::NoProcessesLeft);
            }
        }
    }
}

#[derive(core::fmt::Debug)]
pub enum SchedulerError<T> {
    ProcessError(T),
    NoProcessesLeft,
}

pub enum SchedulerTask {
    Unfreeze(u32),
    Freeze(u32),
    Kill(u32),
    Spawn(
        alloc::boxed::Box<
            dyn FnOnce() -> alloc::boxed::Box<dyn crate::proc::Process> + Send + 'static,
        >,
    ),
    Send(u32, u32, crate::proc::IpcData),
    /// This task carries the PID of the process that created this task, and
    /// the PID of the target process
    /// 
    /// This can for example be used for processes subscribing to other processes.
    /// A concrete example would be the PS/2 driver and a shell. The PS/2 process
    /// sends its input to all subscribers via IPC, but in order to do that, it
    /// needs to know the PIDs of its subscribers. This is what this `SchedulerTask`
    /// is for.
    ConnectTo(u32, u32),
}
