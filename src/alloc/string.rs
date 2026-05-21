use core::prelude::rust_2024::derive;

#[derive(core::fmt::Debug)]
pub struct String<const N: usize>([u8; N]);

impl<const N: usize> String<N> {
    pub fn new() -> Self {
        Self([0u8; N])
    }

    pub fn create(text: &str) -> Self {
        let mut buf: [u8; N] = [0u8; N];
        let mut counter = 0;
        for char in text.chars() {
            if counter >= N {break}
            buf[counter] = char as u8;
            counter += 1;
        }
        Self(buf)
    }
}

impl<const N: usize> core::default::Default for String<N> {
    fn default() -> Self {
        let mut buf: [u8; N] = [0u8; N];
        for idx in 0..N {
            buf[idx] = 0;
        }
        Self {
            0: buf
        }
    }
}

impl<const N: usize> core::convert::From<&str> for String<N> {
    fn from(text: &str) -> String<N> {
        let mut buf: [u8; N] = [0u8; N];
        let mut counter = 0;
        for char in text.chars() {
            if counter >= N {break}
            buf[counter] = char as u8;
            counter += 1;
        }
        Self {
            0: buf
        }
    }
}
