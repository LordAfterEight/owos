use core::default::Default;
use spin::Once;

pub static KFONT_BYTES_LIGHT: Once<fontdue::Font> = Once::new();
pub static KFONT_BYTES_REGULAR: Once<fontdue::Font> = Once::new();
pub static KFONT_BYTES_BOLD: Once<fontdue::Font> = Once::new();

pub static FONT_BYTES_LIGHT: &[u8] = include_bytes!("../../assets/fonts/Datatype-Light.ttf");
pub static FONT_BYTES_REGULAR: &[u8] = include_bytes!("../../assets/fonts/Datatype-Regular.ttf");
pub static FONT_BYTES_BOLD: &[u8] = include_bytes!("../../assets/fonts/Datatype-Bold.ttf");

pub fn init() {
    KFONT_BYTES_LIGHT.call_once(|| fontdue::Font::from_bytes(FONT_BYTES_LIGHT, Default::default()).unwrap());
    KFONT_BYTES_REGULAR.call_once(|| fontdue::Font::from_bytes(FONT_BYTES_REGULAR, Default::default()).unwrap());
    KFONT_BYTES_BOLD.call_once(|| fontdue::Font::from_bytes(FONT_BYTES_BOLD, Default::default()).unwrap());
}

pub fn kfont_light() -> &'static fontdue::Font {
    KFONT_BYTES_LIGHT.get().expect("No light font")
}

pub fn kfont_regular() -> &'static fontdue::Font {
    KFONT_BYTES_REGULAR.get().expect("No regular font")
}

pub fn kfont_bold() -> &'static fontdue::Font {
    KFONT_BYTES_BOLD.get().expect("No bold font")
}