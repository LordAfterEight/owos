use super::codegen::Executable;
use spin::Mutex;

static OUTPUT: Mutex<alloc::vec::Vec<alloc::string::String>> =
    Mutex::new(alloc::vec::Vec::new());

#[unsafe(no_mangle)]
pub extern "C" fn print_int(value: i32) {
    OUTPUT
        .lock()
        .push(alloc::format!("{value}"));
}

pub fn take_output() -> alloc::vec::Vec<alloc::string::String> {
    core::mem::take(&mut *OUTPUT.lock())
}

pub fn execute(exe: &Executable) -> Result<i32, alloc::string::String> {
    OUTPUT.lock().clear();
    if exe.code.is_empty() {
        return Err(alloc::string::String::from("runtime error: empty executable"));
    }

    let entry = exe
        .code
        .get(exe.entry)
        .map(|_| exe.code.as_ptr().wrapping_add(exe.entry))
        .ok_or_else(|| alloc::string::String::from("runtime error: invalid entry"))?;

    let main_fn: extern "C" fn() -> i32 = unsafe { core::mem::transmute(entry) };
    let code = main_fn();
    Ok(code)
}