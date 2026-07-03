pub struct OfsDriver {
    name: &'static str,
    pid: u32,
    status: crate::proc::ProcessStatus,

    files: alloc::vec::Vec<crate::ofs::PlaintextFile>,
    ticks: u32,
    closing: bool,
}

impl crate::proc::Process for OfsDriver {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            name: "OFS File System Driver",
            pid: 0,
            status: crate::proc::ProcessStatus::Running,

            files: alloc::vec::Vec::new(),
            ticks: 0,
            closing: false,
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

    fn set_name(&mut self, name: &'static str) {
        self.name = name;
    }

    fn set_pid(&mut self, pid: u32) {
        self.pid = pid;
    }

    fn set_status(&mut self, status: crate::proc::ProcessStatus) {
        self.status = status;
    }

    fn on_init(&self) {}

    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        if self.closing {
            for _ in 0..1000 {
                if self.files.pop().is_none() {
                    break;
                }
            }
            if self.files.is_empty() {
                let fb = crate::kui::kdraw::GLOBAL_FB.get().unwrap().0;
                let text_length = crate::kui::kdraw::text_length(
                    "Deallocating Files...",
                    &crate::kui::kfont::ICELAND,
                    28.0,
                );
                let x_pos = fb.width as u32 / 2 - text_length as u32 / 2;
                crate::kui::kdraw::draw_rect(
                    x_pos - 10,
                    fb.height as u32 / 2,
                    text_length as u32 + 10,
                    30,
                    15,
                    0xF3E600,
                );
                crate::kui::kdraw::draw_text(
                    x_pos,
                    fb.height as u32 / 2 + 2,
                    28.0,
                    &crate::kui::kfont::ICELAND,
                    "Deallocating Files",
                    0x0,
                );
                return Ok(crate::proc::ProcessEvent::Closed(0));
            }
            return Ok(crate::proc::ProcessEvent::Yielded);
        }

        self.ticks += 1;

        if self.ticks % 5 == 0 {
            let mut file = crate::ofs::PlaintextFile::new("TestFile.txt").unwrap();
            file.write_bytes("Hello World!".as_bytes()).unwrap();
            self.files.push(file);
        }

        if self.files.len() == 15_000_000 {
            self.closing = true;
        }

        if self.ticks % 100_000 == 0 {
            let text = &alloc::format!("Tracking {} files", self.files.len());
            crate::kui::kdraw::draw_rect(
                20,
                200,
                crate::kui::kdraw::text_length(text, &crate::kui::kfont::ICELAND, 20.0) as u32,
                20,
                10,
                0,
            );
            crate::kui::kdraw::draw_text(
                20,
                200,
                20.0,
                &crate::kui::kfont::ICELAND,
                text,
                0x55EAD4,
            );
        }

        Ok(crate::proc::ProcessEvent::Yielded)
    }

    fn on_uninit(mut self: alloc::boxed::Box<Self>) {
        crate::proc::create_spawn_task::<OfsDriver>();
        self.files.clear();
    }
}
