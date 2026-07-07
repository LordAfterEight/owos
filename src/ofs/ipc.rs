/// Holds the response from the last IPC message handled by the OFS driver.
/// Cleared when a new message arrives; read by the scheduler after `receive` succeeds.
pub static IPC_RESPONSE: spin::Mutex<Option<alloc::string::String>> =
    spin::Mutex::new(None);

pub fn set_response(response: alloc::string::String) {
    *IPC_RESPONSE.lock() = Some(response);
}

pub fn take_response() -> Option<alloc::string::String> {
    IPC_RESPONSE.lock().take()
}