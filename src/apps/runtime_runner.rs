use crate::runtime::queue::{RunComplete, RUN_QUEUE};
pub struct RuntimeRunner {
    name: &'static str,
    pid: u32,
    status: crate::proc::ProcessStatus,
}

impl crate::proc::Process for RuntimeRunner {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            name: "Runtime",
            pid: 0,
            status: crate::proc::ProcessStatus::Running,
        })
    }

    fn name(&self) -> &'static str {
        self.name
    }

    fn pid(&self) -> u32 {
        self.pid
    }

    fn status(&self) -> crate::proc::ProcessStatus {
        self.status
    }

    fn set_pid(&mut self, pid: u32) {
        self.pid = pid;
    }

    fn set_name(&mut self, name: &'static str) {
        self.name = name;
    }

    fn set_status(&mut self, status: crate::proc::ProcessStatus) {
        self.status = status;
    }

    fn on_init(&self) {}

    fn on_uninit(self: alloc::boxed::Box<Self>) {}

    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        let request = RUN_QUEUE.lock().take();
        let Some(request) = request else {
            return Ok(crate::proc::ProcessEvent::Yielded);
        };

        let argv: alloc::vec::Vec<&str> = request.argv.iter().map(|s| s.as_str()).collect();
        let arena = crate::runtime::loader::arena_size_for(
            request.argv.first().map(|s| s.as_str()).unwrap_or(""),
        );
        let result = match crate::runtime::loader::load_and_run_with_arena(
            &request.image,
            &argv,
            arena,
        ) {
            Ok((exit_code, output)) => RunComplete {
                exit_code,
                output,
                error: None,
            },
            Err(err) => RunComplete {
                exit_code: -1,
                output: alloc::string::String::new(),
                error: Some(err),
            },
        };

        crate::proc::create_ipc_task(
            self.pid,
            request.reply_pid,
            crate::proc::IpcData::Payload(alloc::boxed::Box::new(result)),
        );

        Ok(crate::proc::ProcessEvent::Yielded)
    }

    fn receive(&mut self, _data: crate::proc::IpcData) -> Result<(), crate::proc::IpcReceiveError> {
        Ok(())
    }

    fn bind(&mut self, _subscriber: u32) {}
}