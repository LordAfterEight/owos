use core::default::Default;
use spin::Once;

pub static KFONT: Once<fontdue::Font> = Once::new();
pub static UIFONT_LIGHT: Once<fontdue::Font> = Once::new();
pub static UIFONT_REGULAR: Once<fontdue::Font> = Once::new();
pub static UIFONT_BOLD: Once<fontdue::Font> = Once::new();

pub static KFONT_BYTES_REGULAR: &[u8] = include_bytes!("../../assets/fonts/Datatype-Regular.ttf");
pub static UIFONT_BYTES_LIGHT: &[u8] = include_bytes!("../../assets/fonts/ElmsSans-Light.ttf");
pub static UIFONT_BYTES_REGULAR: &[u8] = include_bytes!("../../assets/fonts/ElmsSans-Regular.ttf");
pub static UIFONT_BYTES_BOLD: &[u8] = include_bytes!("../../assets/fonts/ElmsSans-Bold.ttf");

pub fn init() {
    KFONT.call_once(|| fontdue::Font::from_bytes(KFONT_BYTES_REGULAR, Default::default()).unwrap());
    UIFONT_LIGHT.call_once(|| fontdue::Font::from_bytes(UIFONT_BYTES_LIGHT, Default::default()).unwrap());
    UIFONT_REGULAR.call_once(|| fontdue::Font::from_bytes(UIFONT_BYTES_REGULAR, Default::default()).unwrap());
    UIFONT_BOLD.call_once(|| fontdue::Font::from_bytes(UIFONT_BYTES_BOLD, Default::default()).unwrap());
}

pub fn kfont_regular() -> &'static fontdue::Font {
    KFONT.get().expect("No regular font")
}

pub fn uifont_light() -> &'static fontdue::Font {
    UIFONT_LIGHT.get().expect("No light UI font")
}

pub fn uifont_regular() -> &'static fontdue::Font {
    UIFONT_REGULAR.get().expect("No regular UI font")
}

pub fn uifont_bold() -> &'static fontdue::Font {
    UIFONT_BOLD.get().expect("No bold UI font")
}