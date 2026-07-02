#[global_allocator]
pub static ALLOCATOR: BumpAllocator = BumpAllocator::uninit();


pub struct BumpAllocator {
    data: core::cell::UnsafeCell<*mut u8>,
    len:  core::cell::UnsafeCell<usize>,
    ptr:  core::cell::UnsafeCell<usize>,
}

unsafe impl Sync for BumpAllocator {}

impl BumpAllocator {
    pub const fn uninit() -> Self {
        Self {
            data: core::cell::UnsafeCell::new(core::ptr::null_mut()),
            len:  core::cell::UnsafeCell::new(0),
            ptr:  core::cell::UnsafeCell::new(0),
        }
    }

    pub unsafe fn init(&self, base: *mut u8, len: usize) {
        unsafe {
            *self.data.get() = base;
            *self.len.get()  = len;
            *self.ptr.get()  = 0;
        }
    }

    pub fn total(&self) -> usize {
        unsafe { *self.len.get() }
    }

    pub fn used(&self) -> usize {
        unsafe { *self.ptr.get() }
    }

    pub fn free(&self) -> usize {
        self.total() - self.used()
    }
}

unsafe impl core::alloc::GlobalAlloc for BumpAllocator {
    unsafe fn alloc(&self, layout: core::alloc::Layout) -> *mut u8 {
        unsafe {
            let ptr  = &mut *self.ptr.get();
            let base = *self.data.get();
            let len  = *self.len.get();

            let offset = (*ptr + layout.align() - 1) & !(layout.align() - 1);

            if offset + layout.size() > len {
                return core::ptr::null_mut();
            }

            *ptr = offset + layout.size();
            base.add(offset)
        }
    }

    unsafe fn dealloc(&self, _ptr: *mut u8, _layout: core::alloc::Layout) {}
}