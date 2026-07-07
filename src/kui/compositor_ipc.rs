use crate::kui::window::WindowHandle;
use crate::kui::WindowContentRect;

#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub enum CompositorRequest {
    CreateWindow {
        owner_pid: u32,
        title: alloc::string::String,
        x: u32,
        y: u32,
        w: u32,
        h: u32,
    },
    DestroyWindow {
        requester_pid: u32,
        handle: WindowHandle,
    },
    RaiseToTop {
        requester_pid: u32,
        handle: WindowHandle,
    },
    LowerToBottom {
        requester_pid: u32,
        handle: WindowHandle,
    },
    FocusWindow {
        requester_pid: u32,
        handle: WindowHandle,
    },
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub enum CompositorReply {
    WindowCreated {
        handle: WindowHandle,
        content: WindowContentRect,
    },
    Ok,
    Error(alloc::string::String),
}

pub fn compositor_pid() -> Option<u32> {
    crate::proc::registry::PROCESS_TABLE
        .lock()
        .iter()
        .find(|entry| entry.name == "Compositor")
        .map(|entry| entry.pid)
}

pub fn request(sender_pid: u32, req: CompositorRequest) {
    let Some(target) = compositor_pid() else {
        return;
    };
    crate::proc::create_ipc_task(
        sender_pid,
        target,
        crate::proc::IpcData::Payload(alloc::boxed::Box::new(req)),
    );
}

pub fn set_reply(reply: &CompositorReply) {
    let bytes = postcard::to_allocvec(reply).expect("serialize compositor reply");
    let hex: alloc::string::String = bytes
        .iter()
        .map(|b| alloc::format!("{b:02x}"))
        .collect();
    crate::ofs::ipc::set_response(hex);
}

pub fn parse_reply(msg: &str) -> Option<CompositorReply> {
    if msg.len() % 2 != 0 {
        return None;
    }
    let mut bytes = alloc::vec::Vec::with_capacity(msg.len() / 2);
    let chars: alloc::vec::Vec<char> = msg.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let hi = chars[i].to_digit(16)?;
        let lo = chars[i + 1].to_digit(16)?;
        bytes.push((hi << 4 | lo) as u8);
        i += 2;
    }
    postcard::from_bytes(&bytes).ok()
}

pub fn is_compositor_reply(msg: &str) -> bool {
    parse_reply(msg).is_some()
}