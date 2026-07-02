use core::default::Default;
use spin::Once;

pub static KFONT: Once<fontdue::Font> = Once::new();
pub static NABLA_REGULAR: Once<fontdue::Font> = Once::new();
pub static ORBITRON_LIGHT: Once<fontdue::Font> = Once::new();
pub static ORBITRON_REGULAR: Once<fontdue::Font> = Once::new();
pub static ORBITRON_BOLD: Once<fontdue::Font> = Once::new();
pub static KODEMONO_REGULAR: Once<fontdue::Font> = Once::new();
pub static KODEMONO_BOLD: Once<fontdue::Font> = Once::new();
pub static ICELAND: Once<fontdue::Font> = Once::new();
pub static BARCODE: Once<fontdue::Font> = Once::new();

static KFONT_BYTES_REGULAR: &[u8] = include_bytes!("../../assets/fonts/Datatype-Regular.ttf");
static ORBITRON_BYTES_LIGHT: &[u8] = include_bytes!("../../assets/fonts/Orbitron Light.ttf");
static ORBITRON_BYTES_REGULAR: &[u8] = include_bytes!("../../assets/fonts/Orbitron Regular.ttf");
static ORBITRON_BYTES_BOLD: &[u8] = include_bytes!("../../assets/fonts/Orbitron Bold.ttf");
static KODEMONO_BYTES_REGULAR: &[u8] = include_bytes!("../../assets/fonts/KodeMono-Regular.ttf");
static KODEMONO_BYTES_BOLD: &[u8] = include_bytes!("../../assets/fonts/KodeMono-Bold.ttf");
static NABLA_BYTES_REGULAR: &[u8] = include_bytes!("../../assets/fonts/Nabla-Regular.ttf");
static ICELAND_BYTES: &[u8] = include_bytes!("../../assets/fonts/Iceland-Regular.ttf");
static BARCODE_BYTES: &[u8] = include_bytes!("../../assets/fonts/LibreBarcode128Text-Regular.ttf");

pub fn init() {
    KFONT.call_once(|| fontdue::Font::from_bytes(KFONT_BYTES_REGULAR, Default::default()).unwrap());
    ORBITRON_LIGHT.call_once(|| fontdue::Font::from_bytes(ORBITRON_BYTES_LIGHT, Default::default()).unwrap());
    ORBITRON_REGULAR.call_once(|| fontdue::Font::from_bytes(ORBITRON_BYTES_REGULAR, Default::default()).unwrap());
    ORBITRON_BOLD.call_once(|| fontdue::Font::from_bytes(ORBITRON_BYTES_BOLD, Default::default()).unwrap());
    KODEMONO_REGULAR.call_once(|| fontdue::Font::from_bytes(KODEMONO_BYTES_REGULAR, Default::default()).unwrap());
    KODEMONO_BOLD.call_once(|| fontdue::Font::from_bytes(KODEMONO_BYTES_BOLD, Default::default()).unwrap());
    NABLA_REGULAR.call_once(|| fontdue::Font::from_bytes(NABLA_BYTES_REGULAR, Default::default()).unwrap());
    ICELAND.call_once(|| fontdue::Font::from_bytes(ICELAND_BYTES, Default::default()).unwrap());
    BARCODE.call_once(|| fontdue::Font::from_bytes(BARCODE_BYTES, Default::default()).unwrap());
}