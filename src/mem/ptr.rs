use core::prelude::rust_2024::derive;

#[derive(core::fmt::Debug)]
pub struct Ptr<'a, T> {
    pub(super) ptr: *mut T,
    pub(super) phantom: core::marker::PhantomData<&'a mut T> 
}

impl<'a, T> core::ops::Deref for Ptr<'a, T> {
    type Target = T;
    fn deref(&self) -> &T {
        unsafe { &*self.ptr }
    }
}

impl<'a, T> core::ops::DerefMut for Ptr<'a, T> {
    fn deref_mut(&mut self) -> &mut T {
        unsafe { &mut *self.ptr }
    }
}
