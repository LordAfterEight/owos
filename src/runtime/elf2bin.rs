use super::loader::JIT_LOAD_ADDR;

const ELF_MAGIC: [u8; 4] = [0x7f, b'E', b'L', b'F'];
const PT_LOAD: u32 = 1;
const SHT_SYMTAB: u32 = 2;
const STT_FUNC: u8 = 2;

pub fn is_elf(bytes: &[u8]) -> bool {
    bytes.len() >= 4 && bytes[..4] == ELF_MAGIC
}

pub fn convert_elf(bytes: &[u8]) -> Result<alloc::vec::Vec<u8>, alloc::string::String> {
    if !is_elf(bytes) {
        return Ok(bytes.to_vec());
    }
    if bytes.len() < 64 || bytes[4] != 2 {
        return Err(alloc::string::String::from(
            "elf2bin error: expected ELF64",
        ));
    }

    let e_phoff = read_u64(bytes, 32)? as usize;
    let e_shoff = read_u64(bytes, 40)? as usize;
    let e_phentsize = read_u16(bytes, 54)? as usize;
    let e_phnum = read_u16(bytes, 56)? as usize;
    let e_shentsize = read_u16(bytes, 58)? as usize;
    let e_shnum = read_u16(bytes, 60)? as usize;
    let e_shstrndx = read_u16(bytes, 62)? as usize;

    let load_base = JIT_LOAD_ADDR as usize;
    let mut image = alloc::vec::Vec::new();

    for i in 0..e_phnum {
        let off = e_phoff + i * e_phentsize;
        let p_type = read_u32(bytes, off)?;
        if p_type != PT_LOAD {
            continue;
        }
        let p_offset = read_u64(bytes, off + 8)? as usize;
        let p_vaddr = read_u64(bytes, off + 16)? as usize;
        let p_filesz = read_u64(bytes, off + 32)? as usize;
        if p_filesz == 0 {
            continue;
        }
        if p_offset.saturating_add(p_filesz) > bytes.len() {
            return Err(alloc::string::String::from(
                "elf2bin error: program header out of range",
            ));
        }
        let dest = p_vaddr.checked_sub(load_base).ok_or_else(|| {
            alloc::string::String::from("elf2bin error: segment below JIT base")
        })?;
        if image.len() < dest {
            image.resize(dest, 0);
        }
        if image.len() < dest + p_filesz {
            image.resize(dest + p_filesz, 0);
        }
        image[dest..dest + p_filesz]
            .copy_from_slice(&bytes[p_offset..p_offset + p_filesz]);
    }

    if image.is_empty() {
        return Err(alloc::string::String::from(
            "elf2bin error: no loadable segments",
        ));
    }

    let (entry, api_offset) = find_symbols(bytes, e_shoff, e_shentsize, e_shnum, e_shstrndx)?;
    let entry = entry.checked_sub(load_base).ok_or_else(|| {
        alloc::string::String::from("elf2bin error: entry below JIT base")
    })?;
    let api_offset = api_offset.checked_sub(load_base).ok_or_else(|| {
        alloc::string::String::from("elf2bin error: owos_api below JIT base")
    })?;
    if entry >= image.len() {
        return Err(alloc::string::String::from(
            "elf2bin error: entry out of range",
        ));
    }

    let mut out = alloc::vec::Vec::with_capacity(16 + image.len());
    out.extend_from_slice(&(entry as u64).to_le_bytes());
    out.extend_from_slice(&(api_offset as u64).to_le_bytes());
    out.extend_from_slice(&image);
    Ok(out)
}

fn find_symbols(
    bytes: &[u8],
    e_shoff: usize,
    e_shentsize: usize,
    e_shnum: usize,
    _e_shstrndx: usize,
) -> Result<(usize, usize), alloc::string::String> {
    let mut symtab_idx = None;
    let mut strtab_idx = None;
    for i in 0..e_shnum {
        let sh_type = section_type(bytes, e_shoff, e_shentsize, i)?;
        if sh_type == SHT_SYMTAB {
            symtab_idx = Some(i);
            let sh_link = section_link(bytes, e_shoff, e_shentsize, i)?;
            strtab_idx = Some(sh_link);
            break;
        }
    }

    let (symtab_idx, strtab_idx) = match (symtab_idx, strtab_idx) {
        (Some(a), Some(b)) => (a, b),
        _ => {
            return Err(alloc::string::String::from(
                "elf2bin error: missing symbol table",
            ));
        }
    };

    let sym_off = section_offset(bytes, e_shoff, e_shentsize, symtab_idx)?;
    let sym_size = section_size(bytes, e_shoff, e_shentsize, symtab_idx)?;
    let sym_entsize = section_entsize(bytes, e_shoff, e_shentsize, symtab_idx)?;
    let str_off = section_offset(bytes, e_shoff, e_shentsize, strtab_idx)?;

    if sym_entsize < 24 {
        return Err(alloc::string::String::from(
            "elf2bin error: invalid symbol entry size",
        ));
    }

    let mut entry = 0usize;
    let mut api_offset = 0usize;
    let count = sym_size / sym_entsize;
    for i in 0..count {
        let off = sym_off + i * sym_entsize;
        if off + 24 > bytes.len() {
            break;
        }
        let st_name = read_u32(bytes, off)? as usize;
        let st_info = bytes[off + 4];
        let st_value = read_u64(bytes, off + 8)? as usize;
        let name = read_elf_string(bytes, str_off, st_name)?;
        if name == "_start" && st_info & 0xf == STT_FUNC {
            entry = st_value;
        } else if name == "owos_api" {
            api_offset = st_value;
        }
    }

    if entry == 0 {
        return Err(alloc::string::String::from(
            "elf2bin error: missing _start symbol",
        ));
    }
    if api_offset == 0 {
        return Err(alloc::string::String::from(
            "elf2bin error: missing owos_api symbol",
        ));
    }
    Ok((entry, api_offset))
}

fn section_header_off(e_shoff: usize, e_shentsize: usize, idx: usize) -> usize {
    e_shoff + idx * e_shentsize
}

fn section_offset(
    bytes: &[u8],
    e_shoff: usize,
    e_shentsize: usize,
    idx: usize,
) -> Result<usize, alloc::string::String> {
    let off = section_header_off(e_shoff, e_shentsize, idx);
    Ok(read_u64(bytes, off + 24)? as usize)
}

fn section_size(
    bytes: &[u8],
    e_shoff: usize,
    e_shentsize: usize,
    idx: usize,
) -> Result<usize, alloc::string::String> {
    let off = section_header_off(e_shoff, e_shentsize, idx);
    Ok(read_u64(bytes, off + 32)? as usize)
}

fn section_type(
    bytes: &[u8],
    e_shoff: usize,
    e_shentsize: usize,
    idx: usize,
) -> Result<u32, alloc::string::String> {
    let off = section_header_off(e_shoff, e_shentsize, idx);
    read_u32(bytes, off + 4)
}

fn section_link(
    bytes: &[u8],
    e_shoff: usize,
    e_shentsize: usize,
    idx: usize,
) -> Result<usize, alloc::string::String> {
    let off = section_header_off(e_shoff, e_shentsize, idx);
    Ok(read_u32(bytes, off + 40)? as usize)
}

fn section_entsize(
    bytes: &[u8],
    e_shoff: usize,
    e_shentsize: usize,
    idx: usize,
) -> Result<usize, alloc::string::String> {
    let off = section_header_off(e_shoff, e_shentsize, idx);
    Ok(read_u64(bytes, off + 56)? as usize)
}

fn read_elf_string(
    bytes: &[u8],
    str_off: usize,
    name_off: usize,
) -> Result<alloc::string::String, alloc::string::String> {
    let start = str_off.saturating_add(name_off);
    if start >= bytes.len() {
        return Ok(alloc::string::String::new());
    }
    let end = bytes[start..]
        .iter()
        .position(|&b| b == 0)
        .map(|p| start + p)
        .unwrap_or(bytes.len());
    core::str::from_utf8(&bytes[start..end])
        .map(alloc::string::String::from)
        .map_err(|_| alloc::string::String::from("elf2bin error: invalid symbol name"))
}

fn read_u16(bytes: &[u8], off: usize) -> Result<u16, alloc::string::String> {
    if off + 2 > bytes.len() {
        return Err(alloc::string::String::from("elf2bin error: read past end"));
    }
    Ok(u16::from_le_bytes(bytes[off..off + 2].try_into().unwrap()))
}

fn read_u32(bytes: &[u8], off: usize) -> Result<u32, alloc::string::String> {
    if off + 4 > bytes.len() {
        return Err(alloc::string::String::from("elf2bin error: read past end"));
    }
    Ok(u32::from_le_bytes(bytes[off..off + 4].try_into().unwrap()))
}

fn read_u64(bytes: &[u8], off: usize) -> Result<u64, alloc::string::String> {
    if off + 8 > bytes.len() {
        return Err(alloc::string::String::from("elf2bin error: read past end"));
    }
    Ok(u64::from_le_bytes(bytes[off..off + 8].try_into().unwrap()))
}