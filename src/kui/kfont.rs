use core::default::Default;
use spin::Once;

pub static KFONT: Once<fontdue::Font> = Once::new();
pub static DOTO_LIGHT: Once<fontdue::Font> = Once::new();
pub static DOTO_REGULAR: Once<fontdue::Font> = Once::new();
pub static DOTO_BOLD: Once<fontdue::Font> = Once::new();
pub static ORBITRON_LIGHT: Once<fontdue::Font> = Once::new();
pub static ORBITRON_REGULAR: Once<fontdue::Font> = Once::new();
pub static ORBITRON_BOLD: Once<fontdue::Font> = Once::new();
pub static KODEMONO_REGULAR: Once<fontdue::Font> = Once::new();
pub static KODEMONO_BOLD: Once<fontdue::Font> = Once::new();
pub static SAIBA45_OUTLINE: Once<fontdue::Font> = Once::new();
pub static SAIBA45: Once<fontdue::Font> = Once::new();
pub static HALFTONE: Once<fontdue::Font> = Once::new();

static KFONT_BYTES_REGULAR: &[u8] = include_bytes!("../../assets/fonts/Datatype-Regular.ttf");
static ORBITRON_BYTES_LIGHT: &[u8] = include_bytes!("../../assets/fonts/Orbitron Light.ttf");
static ORBITRON_BYTES_REGULAR: &[u8] = include_bytes!("../../assets/fonts/Orbitron Regular.ttf");
static ORBITRON_BYTES_BOLD: &[u8] = include_bytes!("../../assets/fonts/Orbitron Bold.ttf");
static KODEMONO_BYTES_REGULAR: &[u8] = include_bytes!("../../assets/fonts/KodeMono-Regular.ttf");
static KODEMONO_BYTES_BOLD: &[u8] = include_bytes!("../../assets/fonts/KodeMono-Bold.ttf");
static DOTO_BYTES_LIGHT: &[u8] = include_bytes!("../../assets/fonts/Doto-Light.ttf");
static DOTO_BYTES_REGULAR: &[u8] = include_bytes!("../../assets/fonts/Doto-Regular.ttf");
static DOTO_BYTES_BOLD: &[u8] = include_bytes!("../../assets/fonts/Doto-Bold.ttf");
static SAIBA45_OUTLINE_BYTES: &[u8] = include_bytes!("../../assets/fonts/SAIBA-45-Outline.ttf");
static SAIBA45_BYTES: &[u8] = include_bytes!("../../assets/fonts/SAIBA-45.ttf");
static HALFTONE_BYTES: &[u8] = include_bytes!("../../assets/fonts/HalftoneJo.otf");

pub fn init() {
    KFONT.call_once(|| fontdue::Font::from_bytes(KFONT_BYTES_REGULAR, Default::default()).unwrap());
    ORBITRON_LIGHT.call_once(|| fontdue::Font::from_bytes(ORBITRON_BYTES_LIGHT, Default::default()).unwrap());
    ORBITRON_REGULAR.call_once(|| fontdue::Font::from_bytes(ORBITRON_BYTES_REGULAR, Default::default()).unwrap());
    ORBITRON_BOLD.call_once(|| fontdue::Font::from_bytes(ORBITRON_BYTES_BOLD, Default::default()).unwrap());
    KODEMONO_REGULAR.call_once(|| fontdue::Font::from_bytes(KODEMONO_BYTES_REGULAR, Default::default()).unwrap());
    KODEMONO_BOLD.call_once(|| fontdue::Font::from_bytes(KODEMONO_BYTES_BOLD, Default::default()).unwrap());
    DOTO_LIGHT.call_once(|| fontdue::Font::from_bytes(DOTO_BYTES_LIGHT, Default::default()).unwrap());
    DOTO_REGULAR.call_once(|| fontdue::Font::from_bytes(DOTO_BYTES_REGULAR, Default::default()).unwrap());
    DOTO_BOLD.call_once(|| fontdue::Font::from_bytes(DOTO_BYTES_BOLD, Default::default()).unwrap());
    SAIBA45_OUTLINE.call_once(|| fontdue::Font::from_bytes(SAIBA45_OUTLINE_BYTES, Default::default()).unwrap());
    SAIBA45.call_once(|| fontdue::Font::from_bytes(SAIBA45_BYTES, Default::default()).unwrap());
    HALFTONE.call_once(|| fontdue::Font::from_bytes(HALFTONE_BYTES, Default::default()).unwrap());
}