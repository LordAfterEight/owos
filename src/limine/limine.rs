const LIMINE_COMMON_MAGIC: [u64; 2] = [0xc7b1dd30df4c8b88, 0x0a82e883a194f07b];

// --- Base revision ---
#[used]
#[unsafe(link_section = ".limine_requests")]
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
    response: *mut EntryPointResponse,
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
        response: core::ptr::null_mut(),
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
    pub response: *mut FramebufferResponse,
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
        response: core::ptr::null_mut(),
    }
}

// --- Section markers ---
#[used]
#[unsafe(link_section = ".limine_requests_start")]
static _START: [u8; 0] = [];

#[used]
#[unsafe(link_section = ".limine_requests_end")]
static _END: [u8; 0] = [];
