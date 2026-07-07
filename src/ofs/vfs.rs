use crate::ofs::{PlaintextFile, FLAG_EXEC, FLAG_READ, FLAG_WRTE};

pub static VFS: spin::Mutex<alloc::vec::Vec<PlaintextFile>> =
    spin::Mutex::new(alloc::vec::Vec::new());

pub fn find_file_index(name: &str) -> Option<usize> {
    let name = name.trim();
    VFS.lock()
        .iter()
        .position(|file| file.display_name() == name)
}

pub fn read_all_bytes(name: &str) -> Result<alloc::vec::Vec<u8>, alloc::string::String> {
    let vfs = VFS.lock();
    let index = vfs
        .iter()
        .position(|file| file.display_name() == name)
        .ok_or_else(|| alloc::format!("error: file not found: {name}"))?;
    let file = &vfs[index];
    if file.block_count() == 0 {
        return Ok(alloc::vec::Vec::new());
    }
    drop(vfs);
    let blocks = read_blocks(name)?;
    let mut out = alloc::vec::Vec::new();
    for block in blocks {
        out.extend_from_slice(&block);
    }
    Ok(out)
}

pub fn read_blocks(name: &str) -> Result<alloc::vec::Vec<alloc::vec::Vec<u8>>, alloc::string::String> {
    let vfs = VFS.lock();
    let index = vfs
        .iter()
        .position(|file| file.display_name() == name)
        .ok_or_else(|| alloc::format!("error: file not found: {name}"))?;
    let file = &vfs[index];
    if file.block_count() == 0 {
        return Ok(alloc::vec::Vec::new());
    }
    let mut out = alloc::vec::Vec::new();
    for block in 0..file.block_count() {
        let bytes = file
            .read_bytes(block)
            .map_err(|e| alloc::format!("error: {e:?}"))?;
        out.push(bytes.to_vec());
    }
    Ok(out)
}

pub fn read_all_text(name: &str) -> Result<alloc::string::String, alloc::string::String> {
    let bytes = read_all_bytes(name)?;
    alloc::string::String::from_utf8(bytes)
        .map_err(|_| alloc::string::String::from("error: file is not valid utf-8"))
}

pub fn replace_block(
    name: &str,
    block: usize,
    bytes: &[u8],
) -> Result<alloc::string::String, alloc::string::String> {
    let mut vfs = VFS.lock();
    let index = vfs
        .iter()
        .position(|file| file.display_name() == name)
        .ok_or_else(|| alloc::format!("error: file not found: {name}"))?;
    vfs[index]
        .replace_block(block, bytes)
        .map_err(|e| alloc::format!("error: {e:?}"))?;
    Ok(alloc::format!(
        "ok: replaced block {block} in {name} ({} byte(s))",
        bytes.len()
    ))
}

pub fn ensure_file(name: &str, flags: u8) -> Result<(), alloc::string::String> {
    let mut vfs = VFS.lock();
    if vfs.iter().any(|file| file.display_name() == name) {
        return Ok(());
    }
    let mut file = PlaintextFile::new(name).map_err(|e| alloc::format!("error: {e:?}"))?;
    file.set_flags(flags);
    vfs.push(file);
    Ok(())
}

pub fn remove_file(name: &str) -> Result<(), alloc::string::String> {
    let mut vfs = VFS.lock();
    if let Some(index) = vfs.iter().position(|file| file.display_name() == name) {
        vfs.remove(index);
    }
    Ok(())
}

pub fn replace_blocks(
    name: &str,
    blocks: &[&[u8]],
    flags: u8,
) -> Result<alloc::string::String, alloc::string::String> {
    let mut vfs = VFS.lock();
    if let Some(index) = vfs
        .iter()
        .position(|file| file.display_name() == name)
    {
        let file = &mut vfs[index];
        file.set_flags(flags);
        for (block_idx, data) in blocks.iter().enumerate() {
            if block_idx < file.block_count() {
                file.replace_block(block_idx, data)
                    .map_err(|e| alloc::format!("error: {e:?}"))?;
            } else {
                file.append_block(data)
                    .map_err(|e| alloc::format!("error: {e:?}"))?;
            }
        }
        file.truncate_blocks(blocks.len());
        file.set_flags(flags);
        return Ok(alloc::format!(
            "ok: wrote {} block(s) to {name}",
            blocks.len()
        ));
    }

    let mut file = PlaintextFile::new(name).map_err(|e| alloc::format!("error: {e:?}"))?;
    for data in blocks {
        file.append_block(data)
            .map_err(|e| alloc::format!("error: {e:?}"))?;
    }
    file.set_flags(flags);
    vfs.push(file);
    Ok(alloc::format!(
        "ok: created {name}, wrote {} block(s)",
        blocks.len()
    ))
}

pub fn replace_bytes(
    name: &str,
    bytes: &[u8],
    flags: u8,
) -> Result<alloc::string::String, alloc::string::String> {
    replace_blocks(name, &[bytes], flags)
}

pub fn write_bytes(
    name: &str,
    bytes: &[u8],
    flags: u8,
) -> Result<alloc::string::String, alloc::string::String> {
    let mut vfs = VFS.lock();
    if let Some(index) = vfs
        .iter()
        .position(|file| file.display_name() == name)
    {
        vfs[index]
            .append_block(bytes)
            .map_err(|e| alloc::format!("error: {e:?}"))?;
        vfs[index].set_flags(flags);
        return Ok(alloc::format!(
            "ok: appended {} byte(s) to {name} (block {})",
            bytes.len(),
            vfs[index].block_count() - 1
        ));
    }

    let mut file = PlaintextFile::new(name).map_err(|e| alloc::format!("error: {e:?}"))?;
    file.append_block(bytes)
        .map_err(|e| alloc::format!("error: {e:?}"))?;
    file.set_flags(flags);
    vfs.push(file);
    Ok(alloc::format!(
        "ok: created {name}, wrote {} byte(s) (block 0)",
        bytes.len()
    ))
}

pub fn write_text(name: &str, text: &str) -> Result<alloc::string::String, alloc::string::String> {
    replace_bytes(name, text.as_bytes(), FLAG_READ | FLAG_WRTE)
}

pub fn write_executable(
    name: &str,
    bytes: &[u8],
) -> Result<alloc::string::String, alloc::string::String> {
    let mut vfs = VFS.lock();
    if let Some(index) = vfs
        .iter()
        .position(|file| file.display_name() == name)
    {
        vfs.remove(index);
    }
    drop(vfs);
    replace_bytes(name, bytes, FLAG_READ | FLAG_EXEC)
}

pub fn is_executable(name: &str) -> bool {
    let vfs = VFS.lock();
    vfs.iter()
        .find(|file| file.display_name() == name)
        .is_some_and(|file| file.executable())
}