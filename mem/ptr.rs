#[derive(Debug)]
pub struct Ptr<'a, T> {
    pub(super) ptr: *mut T,
    pub(super) phantom: crate::marker::PhantomData<&'a mut T> 
}

impl<'a, T> crate::ops::Deref for Ptr<'a, T> {
    type Target = T;
    fn deref(&self) -> &T {
        unsafe { &*self.ptr }
    }
}

impl<'a, T> crate::ops::DerefMut for Ptr<'a, T> {
    fn deref_mut(&mut self) -> &mut T {
        unsafe { &mut *self.ptr }
    }
}