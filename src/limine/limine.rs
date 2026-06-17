const LIMINE_COMMON_MAGIC: [u64; 2] = [0xc7b1dd30df4c8b88, 0x0a82e883a194f07b];

// --- Base revision ---
#[used]
#[unsafe(link_section = ".limine_base_revision")]
static BASE_REVISION: [u64; 3] = [0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 3];

// --- Entry Point ---
#[repr(C)]
pub struct EntryPointResponse {
    pub revision: u64,
}

#[repr(C)]
pub struct EntryPointRequest {
    id: [u64; 4],
    revision: u64,
    response: core::cell::UnsafeCell<*mut EntryPointResponse>,
    entry: extern "C" fn() -> !,
}

unsafe impl Sync for EntryPointRequest {}

pub const fn entry_point_request(entry: extern "C" fn() -> !) -> EntryPointRequest {
    EntryPointRequest {
        id: [
            LIMINE_COMMON_MAGIC[0],
            LIMINE_COMMON_MAGIC[1],
            0x13d86c035a1cd3e1,
            0x2b0caa89d8f3026a,
        ],
        revision: 0,
        response: core::cell::UnsafeCell::new(core::ptr::null_mut()),
        entry,
    }
}

// --- Framebuffer ---
#[repr(C)]
pub struct Framebuffer {
    pub base: *mut u8,
    pub width: u64,
    pub height: u64,
    pub pitch: u64,
    pub bpp: u16,
    pub memory_model: u8,
    pub red_mask_size: u8,
    pub red_mask_shift: u8,
    pub green_mask_size: u8,
    pub green_mask_shift: u8,
    pub blue_mask_size: u8,
    pub blue_mask_shift: u8,
}

#[repr(C)]
pub struct FramebufferResponse {
    pub revision: u64,
    pub framebuffer_count: u64,
    pub framebuffers: *mut *mut Framebuffer,
}

#[repr(C)]
pub struct FramebufferRequest {
    id: [u64; 4],
    revision: u64,
    pub response: core::cell::UnsafeCell<*mut FramebufferResponse>,
}

unsafe impl Sync for FramebufferRequest {}

pub const fn framebuffer_request() -> FramebufferRequest {
    FramebufferRequest {
        id: [
            LIMINE_COMMON_MAGIC[0],
            LIMINE_COMMON_MAGIC[1],
            0x9d5827dcd881dd75,
            0xa3148604f6fab11b,
        ],
        revision: 0,
        response: core::cell::UnsafeCell::new(core::ptr::null_mut()),
    }
}

#[repr(C)]
pub struct MemoryMapEntry {
    pub base: u64,
    pub length: u64,
    pub typ: u32,
    pub reserved: u32,
}

#[repr(C)]
pub struct MemoryMapResponse {
    pub revision: u64,
    pub entry_count: u64,
    pub entries: *mut *mut MemoryMapEntry,
}

impl MemoryMapResponse {
    pub fn entries(&self) -> &[*mut MemoryMapEntry] {
        unsafe { core::slice::from_raw_parts(self.entries, self.entry_count as usize) }
    }
}

#[repr(C)]
pub struct MemoryMapRequest {
    id: [u64; 4],
    revision: u64,
    pub response: core::cell::UnsafeCell<*mut MemoryMapResponse>,
}

impl MemoryMapRequest {
    pub fn get_response(&self) -> Option<&MemoryMapResponse> {
        unsafe { (*self.response.get()).as_ref() }
    }
}

unsafe impl Sync for MemoryMapRequest {}

pub const fn memmap_request() -> MemoryMapRequest {
    MemoryMapRequest {
        id: [
            LIMINE_COMMON_MAGIC[0],
            LIMINE_COMMON_MAGIC[1],
            0x67cf3d9d378a806f,
            0xe304acdfc50c3c62,
        ],
        revision: 0,
        response: core::cell::UnsafeCell::new(core::ptr::null_mut()),
    }
}

#[repr(C)]
pub struct StackSizeRequest {
    id: [u64; 4],
    revision: u64,
    response: core::cell::UnsafeCell<*mut ()>,
    pub stack_size: u64,
}

unsafe impl Sync for StackSizeRequest {}

pub const fn stack_size_request(size: u64) -> StackSizeRequest {
    StackSizeRequest {
        id: [
            LIMINE_COMMON_MAGIC[0],
            LIMINE_COMMON_MAGIC[1],
            0x224ef0460a8e8926,
            0xe1cb0fc25f46ea3d,
        ],
        revision: 0,
        response: core::cell::UnsafeCell::new(core::ptr::null_mut()),
        stack_size: size
    }
}

#[repr(C)]
pub struct HhdmResponse {
    pub revision: u64,
    pub offset: u64,
}

#[repr(C)]
pub struct HhdmRequest {
    id: [u64; 4],
    revision: u64,
    response: core::cell::UnsafeCell<*mut HhdmResponse>,
}

impl HhdmRequest {
    pub fn get_response(&self) -> Option<&HhdmResponse> {
        unsafe { (*self.response.get()).as_ref() }
    }
}

unsafe impl Sync for HhdmRequest {}

pub const fn hhdm_request() -> HhdmRequest {
    HhdmRequest {
        id: [
            LIMINE_COMMON_MAGIC[0],
            LIMINE_COMMON_MAGIC[1],
            0x48dcf1cb8ad2b852,
            0x63984e959a98244b,
        ],
        revision: 0,
        response: core::cell::UnsafeCell::new(core::ptr::null_mut()),
    }
}

// --- Section markers ---
#[used]
#[unsafe(link_section = ".limine_requests_start_marker")]
static _START: [u64; 2] = [0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf];

#[used]
#[unsafe(link_section = ".limine_requests_end_marker")]
static _END: [u64; 2] = [0x1d600343e010f811, 0xad97e90e83b1a052];