static CAPTURE: spin::Mutex<alloc::string::String> =
    spin::Mutex::new(alloc::string::String::new());

pub fn begin_capture() {
    CAPTURE.lock().clear();
}

pub fn take_capture() -> alloc::string::String {
    core::mem::take(&mut *CAPTURE.lock())
}

pub fn write_fd(fd: i32, buf: *const u8, count: usize) -> isize {
    if fd != 1 && fd != 2 {
        return -1;
    }
    if buf.is_null() || count == 0 {
        return 0;
    }
    let bytes = unsafe { core::slice::from_raw_parts(buf, count) };
    let chunk = core::str::from_utf8(bytes).unwrap_or("");
    CAPTURE.lock().push_str(chunk);
    count as isize
}