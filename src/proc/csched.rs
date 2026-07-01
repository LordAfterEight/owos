pub struct CooperativeScheduler {
    procs: alloc::vec::Vec<alloc::boxed::Box<dyn crate::proc::Process>>,
}

impl CooperativeScheduler {
    pub fn init() -> Self {
        Self {
            procs: alloc::vec::Vec::new(),
        }
    }

    pub fn add_process<T: crate::proc::Process + 'static>(&mut self, process: T) {
        T::on_init();
        self.procs.push(alloc::boxed::Box::new(process));
    }

    pub fn start(&mut self) -> Result<(), SchedulerError<crate::proc::ProcessError>> {
        loop {
            let mut i = 0;
            while i < self.procs.len() {
                loop {
                    match self.procs[i].on_tick() {
                        Err(err) => {
                            self.procs.remove(i).on_uninit();
                            crate::println!("Process exited with error {:?}", err);
                            break;
                        }
                        Ok(crate::proc::ProcessEvent::Yielded) => break,
                        Ok(crate::proc::ProcessEvent::Closed(_code)) => {
                            self.procs.remove(i).on_uninit();
                            break;
                        }
                    }
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
