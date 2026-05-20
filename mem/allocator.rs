pub struct BumpAllocator<'a> {
    data: &'a mut Mem,
    ptr: usize,
}

impl<'a> BumpAllocator<'a> {
    pub fn init(reference: &'a mut Mem) -> Self {
        Self {
            data: reference,
            ptr: 0,
        }
    }
    pub fn alloc<T>(&mut self, val: T) -> Result<crate::mem::Ptr<'a, T>, crate::error::AllocationError> {
        let align = std::mem::align_of::<T>();
        let size  = std::mem::size_of::<T>();

        let offset = (self.ptr + align - 1) & !(align - 1);

        if offset + size > self.data.0.len() {
            return Err(crate::error::AllocationError::OOM);
        }

        let ptr = unsafe {
            let raw = self.data.0.as_mut_ptr().add(offset) as *mut T;
            std::ptr::write(raw, val);
            raw
        };

        self.ptr = offset + size;
        Ok(crate::mem::Ptr { ptr: ptr, phantom: crate::marker::PhantomData })
    }
}