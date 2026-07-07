#[derive(Debug)]
pub struct OfsDriver {
    name: &'static str,
    pid: u32,
    status: crate::proc::ProcessStatus,
    closing: bool,
}

impl OfsDriver {
    fn closing_procedure(&mut self) -> Option<crate::proc::ProcessEvent> {
        if self.closing {
            let mut vfs = crate::ofs::vfs::VFS.lock();
            for _ in 0..1000 {
                if vfs.pop().is_none() {
                    break;
                }
            }
            if vfs.is_empty() {
                return Some(crate::proc::ProcessEvent::Closed(0));
            }

            return Some(crate::proc::ProcessEvent::Yielded);
        }
        None
    }

    fn format_block(file: &crate::ofs::PlaintextFile, block: usize) -> alloc::string::String {
        match file.read_bytes(block) {
            Ok(bytes) => {
                if bytes.is_empty() {
                    alloc::format!("  (block {block} is empty)")
                } else {
                    let text = core::str::from_utf8(bytes).unwrap_or("<binary>");
                    alloc::format!("  [{block}] {text}")
                }
            }
            Err(e) => alloc::format!("error: {e:?}"),
        }
    }

    fn parse_write_args(msg: &str) -> Result<(&str, &str), alloc::string::String> {
        let rest = msg
            .strip_prefix("write ")
            .ok_or_else(|| alloc::string::String::from("error: usage write <name.ext> <data>"))?;
        match rest.split_once(' ') {
            Some((name, data)) if !name.is_empty() => Ok((name.trim(), data)),
            None if !rest.is_empty() => Ok((rest.trim(), "")),
            _ => Err(alloc::string::String::from(
                "error: usage write <name.ext> <data>",
            )),
        }
    }

    fn parse_read_args(msg: &str) -> Result<(&str, Option<usize>), alloc::string::String> {
        let rest = msg
            .strip_prefix("read ")
            .ok_or_else(|| alloc::string::String::from("error: usage read <name.ext> [block]"))?;
        match rest.split_once(' ') {
            Some((name, block_str)) if !name.is_empty() => {
                let block_str = block_str.trim();
                if block_str.is_empty() {
                    Ok((name.trim(), None))
                } else {
                    let block = parse_usize(block_str).ok_or_else(|| {
                        alloc::format!("error: invalid block index: {block_str}")
                    })?;
                    Ok((name.trim(), Some(block)))
                }
            }
            None if !rest.is_empty() => Ok((rest.trim(), None)),
            _ => Err(alloc::string::String::from(
                "error: usage read <name.ext> [block]",
            )),
        }
    }

    fn handle_message(&mut self, msg: &str) -> alloc::string::String {
        let cmd = msg.split_whitespace().next().unwrap_or("");
        match cmd {
            "list" => {
                let vfs = crate::ofs::vfs::VFS.lock();
                if vfs.is_empty() {
                    return alloc::string::String::from("(no files)");
                }
                let mut out = alloc::string::String::new();
                for file in vfs.iter() {
                    out.push_str(&alloc::format!(
                        "  {} ({} block{})\n",
                        file.display_name(),
                        file.block_count(),
                        if file.block_count() == 1 { "" } else { "s" }
                    ));
                }
                out
            }
            "write" => {
                let (name, data) = match Self::parse_write_args(msg) {
                    Ok(args) => args,
                    Err(e) => return e,
                };
                crate::ofs::vfs::write_text(name, data).unwrap_or_else(|e| e)
            }
            "read" => {
                let (name, block_arg) = match Self::parse_read_args(msg) {
                    Ok(args) => args,
                    Err(e) => return e,
                };
                let vfs = crate::ofs::vfs::VFS.lock();
                let Some(index) = vfs
                    .iter()
                    .position(|file| file.display_name() == name)
                else {
                    return alloc::format!("error: file not found: {name}");
                };
                let file = &vfs[index];
                if file.block_count() == 0 {
                    return alloc::format!("error: {name} has no data blocks");
                }
                match block_arg {
                    Some(block) => Self::format_block(file, block),
                    None => {
                        let mut out = alloc::format!(
                            "{name} ({} block{}):",
                            file.block_count(),
                            if file.block_count() == 1 { "" } else { "s" }
                        );
                        for block in 0..file.block_count() {
                            out.push('\n');
                            out.push_str(&Self::format_block(file, block));
                        }
                        out
                    }
                }
            }
            _ => alloc::format!("error: unknown ofs command: {cmd}"),
        }
    }
}

fn parse_usize(s: &str) -> Option<usize> {
    if s.is_empty() {
        return None;
    }
    let mut n = 0usize;
    for c in s.chars() {
        if !c.is_ascii_digit() {
            return None;
        }
        n = n
            .checked_mul(10)?
            .checked_add(c.to_digit(10)? as usize)?;
    }
    Some(n)
}

impl crate::proc::Process for OfsDriver {
    fn new() -> alloc::boxed::Box<Self> {
        alloc::boxed::Box::new(Self {
            name: "OFS Driver",
            pid: 0,
            status: crate::proc::ProcessStatus::Running,
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

    fn apply_spawn_args(&mut self, _args: &[alloc::string::String]) {}

    fn on_init(&self) {}

    fn on_tick(&mut self) -> Result<crate::proc::ProcessEvent, crate::proc::ProcessError> {
        if let Some(event) = self.closing_procedure() {
            return Ok(event);
        }
        Ok(crate::proc::ProcessEvent::Yielded)
    }

    fn on_uninit(self: alloc::boxed::Box<Self>) {
        crate::ofs::vfs::VFS.lock().clear();
    }

    fn receive(&mut self, data: crate::proc::IpcData) -> Result<(), crate::proc::IpcReceiveError> {
        match data {
            crate::proc::IpcData::Message(msg) => {
                *crate::ofs::ipc::IPC_RESPONSE.lock() = None;
                let response = self.handle_message(&msg);
                crate::ofs::ipc::set_response(response);
                Ok(())
            }
            _ => Err(crate::proc::IpcReceiveError::Message("Expected Message")),
        }
    }
    fn bind(&mut self, _subscriber: u32) {}
}