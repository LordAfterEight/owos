use core::prelude::rust_2024::derive;

#[derive(core::fmt::Debug)]
pub struct String([u8; 64]);

impl core::default::Default for String {
    fn default() -> Self {
        let mut buf: [u8; 64] = [0u8; 64];
        for idx in 0..64 {
            buf[idx] = 0;
        }
        Self {
            0: buf
        }
    }
}

impl core::convert::From<&str> for String {
    fn from(text: &str) -> String {
        let mut buf: [u8; 64] = [0u8; 64];
        let mut counter = 0;
        for char in text.chars() {
            if counter >= 64 {break}
            buf[counter] = char as u8;
            counter += 1;
        }
        Self {
            0: buf
        }
    }
}
