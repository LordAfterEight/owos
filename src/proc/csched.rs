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

        crate::println!(
            "[{}]: Initialized process: {} | PID {}",
            core::any::type_name_of_val(&self),
            process.name(),
            process.pid()
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
                        let proc = self.procs.remove(idx);
                        crate::proc::registry::PROCESS_TABLE
                            .lock()
                            .retain(|e| e.pid != pid);
                        crate::println!(
                            "[{}]: Killing process: {} | PID {}",
                            core::any::type_name_of_val(&self),
                            proc.name(),
                            proc.pid()
                        );
                        proc.on_uninit();
                    }
                },
                SchedulerTask::Spawn(ctor) => {
                    let mut process = ctor();

                    process.set_pid(self.pid_counter);
                    self.pid_counter += 1;

                    crate::println!(
                        "[{}]: Spawned process: {} | PID {}",
                        core::any::type_name_of_val(&self),
                        process.name(),
                        process.pid()
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
                            crate::println!("Process exited with error {:?}", err);
                            break;
                        }
                        Ok(crate::proc::ProcessEvent::Yielded) => break,
                        Ok(crate::proc::ProcessEvent::Closed(_code)) => {
                            let proc = self.procs.remove(i);
                            crate::proc::registry::PROCESS_TABLE
                                .lock()
                                .retain(|e| e.pid != proc.pid());
                            crate::println!(
                                "[{}]: Process closed: {} | PID {}",
                                core::any::type_name_of_val(&self),
                                proc.name(),
                                proc.pid()
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
    Spawn(alloc::boxed::Box<dyn FnOnce() -> alloc::boxed::Box<dyn crate::proc::Process> + Send + 'static>),
}
