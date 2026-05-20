#[derive(Debug)]
pub struct Ptr<'a, T> {
    ptr: *mut T,
    phantom: core::marker::PhantomData<&'a mut T> 
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