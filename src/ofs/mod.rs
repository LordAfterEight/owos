pub const FLAG_READ: u8 = 0b1000_0000;
pub const FLAG_WRTE: u8 = 0b0100_0000;
pub const FLAG_EXEC: u8 = 0b0010_0000;
pub const FLAG_HIDE: u8 = 0b0001_0000;
pub const FLAG_LOCK: u8 = 0b0000_1000;

#[derive(Copy, Clone, Debug)]
#[repr(C)]
pub struct PlaintextFileHeader {
    pub name: [u8; 48],
    pub extension: [u8; 15],
    /// File marker flags as a single byte. Each bit corresponds to one flag
    /// ```text
    /// bit:    8 7 6 5 4 3 2 1
    /// flag:   R W E H L - - -
    /// ```
    /// where:
    /// - R: Readable
    /// - W: Writable
    /// - E: Executable
    /// - H: Hidden
    /// - L: Locked
    pub flags: u8,
}

impl PlaintextFileHeader {
    pub fn new(name: &str) -> Result<Self, FileError> {
        let (name, extension) = name.split_once('.').ok_or(FileError::InvalidFileExtension)?;
        if name.len() > 48 { return Err(FileError::NameTooLong); }
        if extension.len() > 15 { return Err(FileError::ExtensionTooLong); }
        let mut header = Self {
            name: [0; 48],
            extension: [0; 15],
            flags: FLAG_READ | FLAG_WRTE,
        };
        header.name[..name.len()].copy_from_slice(name.as_bytes());
        header.extension[..extension.len()].copy_from_slice(extension.as_bytes());
        Ok(header)
    }
}

#[derive(Debug)]
pub struct DataBlock {
    data: alloc::vec::Vec<u8>,
}

impl DataBlock {
    fn new(data: alloc::vec::Vec<u8>) -> Self {
        Self { data }
    }

    pub fn len(&self) -> usize {
        self.data.len()
    }

    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }

    pub fn as_bytes(&self) -> &[u8] {
        &self.data
    }
}

#[derive(Debug)]
pub struct PlaintextFile {
    header: PlaintextFileHeader,
    blocks: alloc::vec::Vec<DataBlock>,
}

impl PlaintextFile {
    pub fn new(name: &str) -> Result<Self, FileError> {
        Ok(Self {
            header: PlaintextFileHeader::new(name)?,
            blocks: alloc::vec::Vec::new(),
        })
    }

    pub fn writable(&self) -> bool {
        self.header.flags & FLAG_WRTE != 0
    }

    pub fn readable(&self) -> bool {
        self.header.flags & FLAG_READ != 0
    }

    pub fn locked(&self) -> bool {
        self.header.flags & FLAG_LOCK != 0
    }

    pub fn block_count(&self) -> usize {
        self.blocks.len()
    }

    fn check_access(&self, write: bool) -> Result<(), FileIoError> {
        if self.locked() { return Err(FileIoError::Locked); }
        if write && !self.writable() { return Err(FileIoError::NotWritable); }
        if !write && !self.readable() { return Err(FileIoError::NotReadable); }
        Ok(())
    }

    /// Writes a raw byte slice as a new block.
    pub fn write_bytes(&mut self, bytes: &[u8]) -> Result<(), FileIoError> {
        self.check_access(true)?;
        self.blocks.push(DataBlock::new(bytes.to_vec()));
        Ok(())
    }

    /// Serializes any `T: Serialize` and writes it as a new block.
    pub fn write_serde<T: serde::Serialize>(&mut self, val: &T) -> Result<(), FileIoError> {
        self.check_access(true)?;
        self.blocks.push(DataBlock::new(
            postcard::to_allocvec(val).map_err(|_| FileIoError::SerializeError)?
        ));
        Ok(())
    }

    /// Reads block at `index` as raw bytes.
    pub fn read_bytes(&self, index: usize) -> Result<&[u8], FileIoError> {
        self.check_access(false)?;
        Ok(self.blocks.get(index).ok_or(FileIoError::OutOfBounds)?.as_bytes())
    }

    /// Deserializes block at `index` into `T: Deserialize`.
    /// 
    /// ## Important
    /// You *must* know what the `T` you're trying to read is, otherwise you will
    /// receive garbage or a `DeserializeError`.
    pub fn read_serde<T: for<'de> serde::Deserialize<'de>>(&self, index: usize) -> Result<T, FileIoError> {
        self.check_access(false)?;
        let block = self.blocks.get(index).ok_or(FileIoError::OutOfBounds)?;
        postcard::from_bytes(block.as_bytes()).map_err(|_| FileIoError::DeserializeError)
    }

    /// Flattens the file to bytes for storage or transfer.
    /// 
    /// Layout: `(header: 64B)(block_count: u32)((len: u32)(data)...)`
    pub fn to_bytes(&self) -> Result<alloc::vec::Vec<u8>, FileIoError> {
        if self.locked() { return Err(FileIoError::Locked); }
        let mut out = alloc::vec::Vec::new();
        out.extend_from_slice(&self.header.name);
        out.extend_from_slice(&self.header.extension);
        out.push(self.header.flags);
        out.extend_from_slice(&(self.blocks.len() as u32).to_le_bytes());
        for block in &self.blocks {
            out.extend_from_slice(&(block.len() as u32).to_le_bytes());
            out.extend_from_slice(block.as_bytes());
        }
        Ok(out)
    }
}

#[derive(Debug)]
pub enum FileIoError {
    Locked,
    NotWritable,
    NotReadable,
    OutOfBounds,
    SerializeError,
    DeserializeError,
}

#[derive(Debug)]
pub enum FileError {
    InvalidFileExtension,
    NameTooLong,
    ExtensionTooLong,
}