type SpawnFn = fn(alloc::vec::Vec<alloc::string::String>);

pub struct SpawnEntry {
    pub aliases: &'static [&'static str],
    pub running_name: &'static str,
    spawn: SpawnFn,
}

fn spawn_compositor(args: alloc::vec::Vec<alloc::string::String>) {
    crate::proc::create_spawn_task::<crate::apps::compositor::Compositor>(args);
}

fn spawn_memtracker(args: alloc::vec::Vec<alloc::string::String>) {
    crate::proc::create_spawn_task::<crate::apps::memtracker::MemTracker>(args);
}

fn spawn_ps2(args: alloc::vec::Vec<alloc::string::String>) {
    crate::proc::create_spawn_task::<crate::drivers::ps2::Ps2Driver>(args);
}

fn spawn_ps2_mouse(args: alloc::vec::Vec<alloc::string::String>) {
    crate::proc::create_spawn_task::<crate::drivers::ps2_mouse::Ps2MouseDriver>(args);
}

fn spawn_shell(args: alloc::vec::Vec<alloc::string::String>) {
    crate::proc::create_spawn_task::<crate::apps::shell::Shell>(args);
}

fn spawn_ofs(args: alloc::vec::Vec<alloc::string::String>) {
    crate::proc::create_spawn_task::<crate::apps::filesystem::OfsDriver>(args);
}

fn spawn_proctracker(args: alloc::vec::Vec<alloc::string::String>) {
    crate::proc::create_spawn_task::<crate::apps::proctracker::ProcessTracker>(args);
}

fn shell_pid() -> Option<u32> {
    crate::proc::registry::PROCESS_TABLE
        .lock()
        .iter()
        .find(|entry| entry.name == "Shell")
        .map(|entry| entry.pid)
}

fn spawn_compiler(mut args: alloc::vec::Vec<alloc::string::String>) {
    if args.len() == 1 {
        if let Some(pid) = shell_pid() {
            args.push(alloc::format!("{pid}"));
        }
    }
    crate::proc::create_spawn_task::<crate::apps::compiler::Compiler>(args);
}

fn spawn_texteditor(args: alloc::vec::Vec<alloc::string::String>) {
    crate::proc::create_spawn_task::<crate::apps::texteditor::TextEditor>(args);
}

const SPAWN_TABLE: &[SpawnEntry] = &[
    SpawnEntry {
        aliases: &["compositor", "comp"],
        running_name: "Compositor",
        spawn: spawn_compositor,
    },
    SpawnEntry {
        aliases: &["memtracker", "mem", "memory"],
        running_name: "Memory Tracker",
        spawn: spawn_memtracker,
    },
    SpawnEntry {
        aliases: &["ps2", "keyboard"],
        running_name: "PS/2 Driver",
        spawn: spawn_ps2,
    },
    SpawnEntry {
        aliases: &["mouse", "ps2mouse"],
        running_name: "PS/2 Mouse",
        spawn: spawn_ps2_mouse,
    },
    SpawnEntry {
        aliases: &["shell"],
        running_name: "Shell",
        spawn: spawn_shell,
    },
    SpawnEntry {
        aliases: &["ofs", "filesystem"],
        running_name: "OFS Driver",
        spawn: spawn_ofs,
    },
    SpawnEntry {
        aliases: &["proctracker", "pt"],
        running_name: "ProcessTracker",
        spawn: spawn_proctracker,
    },
    SpawnEntry {
        aliases: &["compiler", "cc"],
        running_name: "Compiler",
        spawn: spawn_compiler,
    },
    SpawnEntry {
        aliases: &["editor", "edit", "texteditor"],
        running_name: "Text Editor",
        spawn: spawn_texteditor,
    },
];

#[derive(Debug, PartialEq, Eq)]
pub enum SpawnError {
    UnknownProcess,
    AlreadyRunning,
}

pub fn list_spawnable() -> &'static [SpawnEntry] {
    SPAWN_TABLE
}

fn process_running(name: &str) -> bool {
    crate::proc::registry::PROCESS_TABLE
        .lock()
        .iter()
        .any(|entry| entry.name == name)
}

fn lookup(name: &str) -> Option<&'static SpawnEntry> {
    SPAWN_TABLE.iter().find(|entry| entry.aliases.iter().any(|alias| *alias == name))
}

pub fn spawn_by_name(name: &str, args: &[&str]) -> Result<(), SpawnError> {
    let entry = lookup(name).ok_or(SpawnError::UnknownProcess)?;
    if process_running(entry.running_name) {
        return Err(SpawnError::AlreadyRunning);
    }

    let owned_args: alloc::vec::Vec<alloc::string::String> =
        args.iter().map(|arg| alloc::string::String::from(*arg)).collect();

    (entry.spawn)(owned_args);
    Ok(())
}