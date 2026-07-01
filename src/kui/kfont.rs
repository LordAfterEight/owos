use core::default::Default;
use spin::Once;

pub static KFONT: Once<fontdue::Font> = Once::new();
pub static ORBITRON_LIGHT: Once<fontdue::Font> = Once::new();
pub static ORBITRON_REGULAR: Once<fontdue::Font> = Once::new();
pub static ORBITRON_BOLD: Once<fontdue::Font> = Once::new();
pub static SAIBA45_OUTLINE: Once<fontdue::Font> = Once::new();
pub static SAIBA45: Once<fontdue::Font> = Once::new();
pub static HALFTONE: Once<fontdue::Font> = Once::new();

pub static KFONT_BYTES_REGULAR: &[u8] = include_bytes!("../../assets/fonts/Datatype-Regular.ttf");
pub static ORBITRON_BYTES_LIGHT: &[u8] = include_bytes!("../../assets/fonts/Orbitron Light.ttf");
pub static ORBITRON_BYTES_REGULAR: &[u8] = include_bytes!("../../assets/fonts/Orbitron Regular.ttf");
pub static ORBITRON_BYTES_BOLD: &[u8] = include_bytes!("../../assets/fonts/Orbitron Bold.ttf");
pub static SAIBA45_OUTLINE_BYTES: &[u8] = include_bytes!("../../assets/fonts/SAIBA-45-Outline.ttf");
pub static SAIBA45_BYTES: &[u8] = include_bytes!("../../assets/fonts/SAIBA-45.ttf");
pub static HALFTONE_BYTES: &[u8] = include_bytes!("../../assets/fonts/HalftoneJo.otf");

pub fn init() {
    KFONT.call_once(|| fontdue::Font::from_bytes(KFONT_BYTES_REGULAR, Default::default()).unwrap());
    ORBITRON_LIGHT.call_once(|| fontdue::Font::from_bytes(ORBITRON_BYTES_LIGHT, Default::default()).unwrap());
    ORBITRON_REGULAR.call_once(|| fontdue::Font::from_bytes(ORBITRON_BYTES_REGULAR, Default::default()).unwrap());
    ORBITRON_BOLD.call_once(|| fontdue::Font::from_bytes(ORBITRON_BYTES_BOLD, Default::default()).unwrap());
    SAIBA45_OUTLINE.call_once(|| fontdue::Font::from_bytes(SAIBA45_OUTLINE_BYTES, Default::default()).unwrap());
    SAIBA45.call_once(|| fontdue::Font::from_bytes(SAIBA45_BYTES, Default::default()).unwrap());
    HALFTONE.call_once(|| fontdue::Font::from_bytes(HALFTONE_BYTES, Default::default()).unwrap());
}

pub fn kfont_regular() -> &'static fontdue::Font {
    KFONT.get().expect("No such font")
}

pub fn orbitron_light() -> &'static fontdue::Font {
    ORBITRON_LIGHT.get().expect("No such font")
}

pub fn orbitron_regular() -> &'static fontdue::Font {
    ORBITRON_REGULAR.get().expect("No such font")
}

pub fn orbitron_bold() -> &'static fontdue::Font {
    ORBITRON_BOLD.get().expect("No such font")
}