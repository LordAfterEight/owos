pub mod bumpallocator;
pub mod freelistallocator;

pub mod ptr;
pub use ptr::Ptr;

#[global_allocator]
pub static ALLOCATOR:freelistallocator::FreeListAllocator = freelistallocator::FreeListAllocator::uninit(); 