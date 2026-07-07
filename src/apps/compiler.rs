use crate::runtime::loader::{PreemptibleSession, ProgramImage, RunSlice, JIT_LOAD_ADDR};
use crate::runtime::queue::RunComplete;

enum CompilePhase {
    Setup,
    LoadTcc,
    Prepare,
    Running(PreemptibleSession),
    PostCompile {
        exit_code: i32,
        output: alloc::string::String,
        out_name: alloc::string::String,
    },
}

pub struct Compiler {
    name: &'static str,
    pid: u32,
    status: crate::proc::ProcessStatus,
    source: Option<alloc::string::String>,
    reply_pid: u32,
    deferred: bool,
    phase: CompilePhase,
    pending_result: Option<RunComplete>,
    tcc_image: Option<ProgramImage>,
}

impl Compiler {
    fn output_bin_name(source: &str) -> alloc::string::String {
        if let Some((base, _)) = source.rsplit_once('.') {
            alloc::format!("{base}.bin")
        } else {
            alloc::format!("{source}.bin")
        }
    }

    fn tcc_argv(source: &str, out_name: &str) -> alloc::vec::Vec<alloc::string::String> {
        alloc::vec![
            alloc::string::String::from("tcc"),
            alloc::string::String::from("-nostdlib"),
            alloc::string::String::from("-Iinclude"),
            alloc::format!("-Wl,-Ttext={JIT_LOAD_ADDR:#x}"),
            alloc::string::String::from("-o"),
            alloc::string::String::from(out_name),
            alloc::string::String::from(source),
            alloc::string::String::from("crt0.o"),
            alloc::string::String::from("-L."),
            alloc::string::String::from("libc.a"),
        ]
    }

    fn check_deps() -> Result<(), alloc::string::String> {
        for dep in ["tcc.bin", "crt0.o", "libc.a", "link.ld"] {
            if crate::ofs::vfs::find_file_index(dep).is_none() {
                return Err(alloc::format!("cc error: missing {dep}"));
            }
        }
        Ok(())
    }

    fn finish_compile(&self, mut result: RunComplete, out_name: &str) -> RunComplete {
        if result.error.is_none() && result.exit_code == 0 {
            match crate::ofs::vfs::read_all_bytes(out_name) {
                Ok(bytes) => match crate::runtime::elf2bin::convert_elf(&bytes) {
                    Ok(bin) => {
                        if let Err(err) = crate::ofs::vfs::write_executable(out_name, &bin) {
                            result.error = Some(err);
                        } else {
                            result.output.push_str(&alloc::format!(
                                "\nok: compiled -> {out_name}"
                            ));
                        }
                    }
                    Err(err) => result.error = Some(err),
                },
                Err(err) => result.error = Some(err),
            }
        }
        result
    }

    fn load_tcc_bytes(&mut self) -> Result<(), alloc::string::String> {
        let tcc_bytes = crate::ofs::vfs::read_all_bytes("tcc.bin")?;
        let image = crate::runtime::parse_bin(&tcc_bytes)?;
        self.tcc_image = Some(image);
        self.phase = CompilePhase::Prepare;
        Ok(())
    }

    fn begin_running(&mut self, source: &str) -> Result<(), alloc::string::String> {
        let image = self
            .tcc_image
            .take()
            .ok_or_else(|| alloc::string::String::from("cc error: tcc image not loaded"))?;
        let out_name = Self::output_bin_name(source);
        let argv_strings = Self::tcc_argv(source, &out_name);
        let argv: alloc::vec::Vec<&str> = argv_strings.iter().map(|s| s.as_str()).collect();
        let arena = crate::runtime::loader::arena_size_for("tcc");

        let session = PreemptibleSession::prepare(&image, &argv, arena)?;
        self.phase = CompilePhase::Running(session);
        crate::klog::log(
            "Compiler",
            &alloc::format!("tcc session ready for {source} -> {out_name}"),
            crate::klog::MessageType::Info,
        );
        Ok(())
    }

    fn fail(&mut self, err: alloc::string::String) {
        crate::klog::log("Compiler", &err, crate::klog::MessageType::Error);
        self.phase = CompilePhase::Setup;
        self.tcc_image = None;
        self.pending_result = Some(RunComplete {
            exit_code: -1,
            output: alloc::string::String::new(),
            error: Some(err),
        });
    }
}

impl crate::proc::Process for Compiler {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            name: "Compiler",
            pid: 0,
            status: crate::proc::ProcessStatus::Running,
            source: None,
            reply_pid: 0,
            deferred: false,
            phase: CompilePhase::Setup,
            pending_result: None,
            tcc_image: None,
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

    fn apply_spawn_args(&mut self, args: &[alloc::string::String]) {
        self.source = args.first().cloned();
        self.reply_pid = args
            .get(1)
            .and_then(|pid| pid.parse::<u32>().ok())
            .unwrap_or(0);
    }

    fn on_init(&self) {}

    fn on_uninit(self: alloc::boxed::Box<Self>) {}

    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        if let Some(result) = self.pending_result.take() {
            if self.reply_pid != 0 {
                crate::proc::create_ipc_task(
                    self.pid,
                    self.reply_pid,
                    crate::proc::IpcData::Payload(alloc::boxed::Box::new(result)),
                );
            }
            return Ok(crate::proc::ProcessEvent::Closed(0));
        }

        if !self.deferred {
            self.deferred = true;
            return Ok(crate::proc::ProcessEvent::Yielded);
        }

        let Some(source) = self.source.clone() else {
            if self.reply_pid != 0 {
                let result = RunComplete {
                    exit_code: -1,
                    output: alloc::string::String::new(),
                    error: Some(alloc::string::String::from(
                        "cc error: no source file specified",
                    )),
                };
                crate::proc::create_ipc_task(
                    self.pid,
                    self.reply_pid,
                    crate::proc::IpcData::Payload(alloc::boxed::Box::new(result)),
                );
            }
            return Ok(crate::proc::ProcessEvent::Closed(0));
        };

        match &mut self.phase {
            CompilePhase::Setup => {
                crate::klog::log(
                    "Compiler",
                    &alloc::format!("starting compile for {source}"),
                    crate::klog::MessageType::Info,
                );
                match Self::check_deps() {
                    Ok(()) => self.phase = CompilePhase::LoadTcc,
                    Err(err) => self.fail(err),
                }
            }
            CompilePhase::LoadTcc => {
                if let Err(err) = self.load_tcc_bytes() {
                    self.fail(err);
                }
            }
            CompilePhase::Prepare => {
                if let Err(err) = self.begin_running(&source) {
                    self.fail(err);
                }
            }
            CompilePhase::Running(session) => {
                let out_name = Self::output_bin_name(&source);
                match session.run_slice() {
                    Ok(RunSlice::Preempted) => {
                        static SLICE_LOGS: core::sync::atomic::AtomicU32 =
                            core::sync::atomic::AtomicU32::new(0);
                        let n = SLICE_LOGS.fetch_add(1, core::sync::atomic::Ordering::Relaxed) + 1;
                        if n <= 4 || n % 32 == 0 {
                            crate::klog::log(
                                "Compiler",
                                &alloc::format!("tcc slice preempted (#{n})"),
                                crate::klog::MessageType::Info,
                            );
                        }
                    }
                    Ok(RunSlice::Done(exit_code, output)) => {
                        let syscalls = crate::runtime::kapi::jit_syscall_count();
                        crate::klog::log(
                            "Compiler",
                            &alloc::format!("tcc finished exit={exit_code} syscalls={syscalls}"),
                            crate::klog::MessageType::Info,
                        );
                        if exit_code != 0 && !output.is_empty() {
                            let preview: alloc::string::String = output
                                .chars()
                                .take(512)
                                .collect();
                            crate::klog::log(
                                "Compiler",
                                &alloc::format!("tcc output: {preview}"),
                                crate::klog::MessageType::Error,
                            );
                        }
                        let (exit_code, output) = if exit_code == 0 && syscalls < 32 {
                            (
                                -1,
                                alloc::format!(
                                    "{output}cc error: tcc exited too early ({syscalls} syscalls)"
                                ),
                            )
                        } else {
                            (exit_code, output)
                        };
                        self.phase = CompilePhase::PostCompile {
                            exit_code,
                            output,
                            out_name,
                        };
                    }
                    Err(err) => self.fail(err),
                }
            }
            CompilePhase::PostCompile { .. } => {
                let CompilePhase::PostCompile {
                    exit_code,
                    output,
                    out_name,
                } = core::mem::replace(&mut self.phase, CompilePhase::Setup)
                else {
                    unreachable!();
                };
                crate::klog::log(
                    "Compiler",
                    &alloc::format!("post-compile {out_name} (exit={exit_code})"),
                    crate::klog::MessageType::Info,
                );
                self.pending_result = Some(self.finish_compile(
                    RunComplete {
                        exit_code,
                        output,
                        error: None,
                    },
                    &out_name,
                ));
            }
        }

        Ok(crate::proc::ProcessEvent::Yielded)
    }

    fn receive(&mut self, _data: crate::proc::IpcData) -> Result<(), crate::proc::IpcReceiveError> {
        Ok(())
    }

    fn bind(&mut self, _subscriber: u32) {}
}