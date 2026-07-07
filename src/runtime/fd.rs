use crate::ofs::vfs;

const MAX_FDS: usize = 32;

#[derive(Clone)]
pub struct OpenFile {
    pub name: alloc::string::String,
    pub offset: usize,
    pub write_only: bool,
    /// Cached file bytes for read-only fds (avoids reloading from VFS on every read).
    pub cache: Option<alloc::vec::Vec<u8>>,
    /// Buffered output for write-only fds; flushed to VFS on close.
    write_buf: Option<alloc::vec::Vec<u8>>,
}

pub struct FdTable {
    slots: [Option<OpenFile>; MAX_FDS],
    next: usize,
}

impl FdTable {
    pub const fn new() -> Self {
        Self {
            slots: [const { None }; MAX_FDS],
            next: 3,
        }
    }

    pub fn reset(&mut self) {
        for slot in &mut self.slots {
            if let Some(file) = slot.take() {
                flush_write_buf(file);
            }
        }
        self.next = 3;
    }

    pub fn open(&mut self, path: &str, flags: i32) -> Result<i32, i32> {
        let name = normalize_path(path);
        let o_creat = (flags & 0o100) != 0;
        let accmode = flags & 0o3;
        let mut write_only = accmode == 0o1 || accmode == 0o2;
        if o_creat {
            let mut create_flags = crate::ofs::FLAG_READ | crate::ofs::FLAG_WRTE;
            if name.ends_with(".bin") {
                create_flags |= crate::ofs::FLAG_EXEC;
            }
            if vfs::ensure_file(&name, create_flags).is_err() {
                return Err(-1);
            }
            if accmode == 0o0 {
                write_only = false;
            }
        }
        let (cache, write_buf) = if write_only {
            (None, Some(alloc::vec::Vec::new()))
        } else {
            match vfs::read_all_bytes(&name) {
                Ok(bytes) => (Some(bytes), None),
                Err(_) => return Err(-2),
            }
        };
        let fd = self.alloc_fd()?;
        self.slots[fd as usize] = Some(OpenFile {
            name,
            offset: 0,
            write_only,
            cache,
            write_buf,
        });
        Ok(fd)
    }

    pub fn close(&mut self, fd: i32) -> Result<(), i32> {
        if fd < 3 {
            return Ok(());
        }
        let idx = fd as usize;
        if idx >= MAX_FDS || self.slots[idx].is_none() {
            return Err(-9);
        }
        let file = self.slots[idx].take().unwrap();
        flush_write_buf(file);
        Ok(())
    }

    pub fn read(&mut self, fd: i32, buf: *mut u8, count: usize) -> isize {
        if fd < 3 || buf.is_null() {
            return -1;
        }
        let idx = fd as usize;
        if idx >= MAX_FDS {
            return -9;
        }
        let Some(file) = self.slots[idx].as_mut() else {
            return -9;
        };
        if file.write_only {
            return -1;
        }
        let Some(bytes) = file.cache.as_ref() else {
            return -2;
        };
        let offset = file.offset;
        if offset >= bytes.len() {
            return 0;
        }
        let avail = bytes.len() - offset;
        let n = count.min(avail);
        unsafe {
            core::ptr::copy_nonoverlapping(bytes.as_ptr().add(offset), buf, n);
        }
        file.offset = offset + n;
        n as isize
    }

    pub fn write(&mut self, fd: i32, buf: *const u8, count: usize) -> isize {
        if fd < 3 || buf.is_null() {
            return -1;
        }
        let idx = fd as usize;
        if idx >= MAX_FDS {
            return -9;
        }
        let Some(file) = self.slots[idx].as_mut() else {
            return -9;
        };
        let bytes = unsafe { core::slice::from_raw_parts(buf, count) };
        let Some(out) = file.write_buf.as_mut() else {
            return -1;
        };
        write_at(out, file.offset, bytes);
        file.offset += count;
        count as isize
    }

    pub fn lseek(&mut self, fd: i32, offset: isize, whence: i32) -> isize {
        if fd < 3 {
            return -1;
        }
        let idx = fd as usize;
        if idx >= MAX_FDS {
            return -9;
        }
        let Some(file) = self.slots[idx].as_mut() else {
            return -9;
        };
        let current = file.offset;
        let file_len = if let Some(buf) = file.write_buf.as_ref() {
            buf.len()
        } else if let Some(cache) = file.cache.as_ref() {
            cache.len()
        } else {
            vfs::read_all_bytes(&file.name)
                .map(|b| b.len())
                .unwrap_or(0)
        };
        let new_off = match whence {
            0 => offset,
            1 => current as isize + offset,
            2 => file_len as isize + offset,
            _ => return -1,
        };
        if new_off < 0 {
            return -1;
        }
        file.offset = new_off as usize;
        new_off
    }

    fn alloc_fd(&mut self) -> Result<i32, i32> {
        for fd in self.next..MAX_FDS {
            if self.slots[fd].is_none() {
                self.next = fd + 1;
                return Ok(fd as i32);
            }
        }
        for fd in 3..MAX_FDS {
            if self.slots[fd].is_none() {
                self.next = fd + 1;
                return Ok(fd as i32);
            }
        }
        Err(-24)
    }
}

fn write_at(buf: &mut alloc::vec::Vec<u8>, offset: usize, data: &[u8]) {
    let end = offset.saturating_add(data.len());
    if buf.len() < end {
        buf.resize(end, 0);
    }
    buf[offset..offset + data.len()].copy_from_slice(data);
}

fn flush_write_buf(file: OpenFile) {
    let Some(data) = file.write_buf else {
        return;
    };
    if data.is_empty() {
        return;
    }
    let mut flags = crate::ofs::FLAG_READ | crate::ofs::FLAG_WRTE;
    if file.name.ends_with(".bin") {
        flags |= crate::ofs::FLAG_EXEC;
    }
    let _ = vfs::replace_bytes(&file.name, &data, flags);
}

fn normalize_path(path: &str) -> alloc::string::String {
    let trimmed = path.trim();
    let trimmed = trimmed.strip_prefix("./").unwrap_or(trimmed);
    let trimmed = trimmed.strip_prefix('/').unwrap_or(trimmed);
    alloc::string::String::from(trimmed)
}