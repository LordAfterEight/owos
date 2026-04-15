// Limine protocol structures for x86_64, compatible with Limine v8+
// Requests are placed in .limine_requests via linksection.
// Limine scans the section bounded by the start/end markers.

const common_magic = [2]u64{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

// Section markers — must be exported so the linker keeps them.
pub export var requests_start_marker: [2]u64 linksection(".limine_requests_start") = .{
    0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf,
};
pub export var requests_end_marker: [2]u64 linksection(".limine_requests_end") = .{
    0x9798b032f5d81a1e, 0x0008a8427b1e7e2b,
};

// Base revision — tells Limine which protocol revision the kernel requires.
// Limine sets index [2] to 0 on success.
pub export var base_revision: [3]u64 linksection(".limine_requests") = .{
    0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 3,
};

// ── HHDM ────────────────────────────────────────────────────────────────────

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

pub const HhdmRequest = extern struct {
    id: [4]u64 = .{ common_magic[0], common_magic[1], 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    revision: u64 = 0,
    response: ?*HhdmResponse = null,
};

// ── Framebuffer ──────────────────────────────────────────────────────────────

pub const Framebuffer = extern struct {
    address: [*]u8,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: ?*anyopaque,
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: [*]*Framebuffer,
};

pub const FramebufferRequest = extern struct {
    id: [4]u64 = .{ common_magic[0], common_magic[1], 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    revision: u64 = 0,
    response: ?*FramebufferResponse = null,
};

// ── Memory map ───────────────────────────────────────────────────────────────

pub const MemMapEntryType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    kernel_and_modules = 6,
    framebuffer = 7,
};

pub const MemMapEntry = extern struct {
    base: u64,
    length: u64,
    type: MemMapEntryType,
};

pub const MemMapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]*MemMapEntry,
};

pub const MemMapRequest = extern struct {
    id: [4]u64 = .{ common_magic[0], common_magic[1], 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    revision: u64 = 0,
    response: ?*MemMapResponse = null,
};

// ── RSDP ────────────────────────────────────────────────────────────────────

pub const RsdpResponse = extern struct {
    revision: u64,
    address: u64,
};

pub const RsdpRequest = extern struct {
    id: [4]u64 = .{ common_magic[0], common_magic[1], 0xc5e77b6b397e7b43, 0x27637845accdcf3c },
    revision: u64 = 0,
    response: ?*RsdpResponse = null,
};

// ── Kernel address ───────────────────────────────────────────────────────────

pub const KernelAddressResponse = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};

pub const KernelAddressRequest = extern struct {
    id: [4]u64 = .{ common_magic[0], common_magic[1], 0x71ba76863cc55f63, 0xb2644a48c516a487 },
    revision: u64 = 0,
    response: ?*KernelAddressResponse = null,
};
