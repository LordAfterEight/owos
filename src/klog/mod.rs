pub fn log(module: &str, msg: &str, message_type: MessageType) {
    match message_type {
        MessageType::Info => crate::print!("\x1b[38;2;85;234;212m"),
        MessageType::Warn => crate::print!("\x1b[38;2;243;104;0m"),
        MessageType::Error => crate::print!("\x1b[38;2;197;0;60m"),
    }
    crate::print!("[{}]\x1b[0m: {}\n", module, msg);
}

pub enum MessageType {
    Info,
    Warn,
    Error,
}