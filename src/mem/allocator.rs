pub struct BumpAllocator<'a> {
    data: &'a mut [u8],
    ptr: usize,
}

impl<'a> BumpAllocator<'a> {
    pub fn init(reference: &'a mut [u8]) -> Self {
        Self {
            data: reference,
            ptr: 0,
        }
    }
    pub fn alloc<T>(
        &mut self,
        val: T,
    ) -> core::result::Result<crate::mem::Ptr<'a, T>, crate::error::AllocationError> {
        let align = core::mem::align_of::<T>();
        let size = core::mem::size_of::<T>();

        let offset = (self.ptr + align - 1) & !(align - 1);

        if offset + size > self.data.len() {
            return core::result::Result::Err(crate::error::AllocationError::OOM);
        }

        let ptr = unsafe {
            let raw = self.data.as_mut_ptr().add(offset) as *mut T;
            core::ptr::write(raw, val);
            raw
        };

        self.ptr = offset + size;
        core::result::Result::Ok(crate::mem::Ptr {
            ptr: ptr,
            phantom: core::marker::PhantomData,
        })
    }
}
