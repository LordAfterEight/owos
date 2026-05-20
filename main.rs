pub struct Mem([u8; 65536]);

impl Mem {
    pub fn init() -> Self {
        Self {
            0: [0u8; 65536],
        }
    }
}

#[allow(unused)]
#[derive(Default, Debug)]
struct Point {
    x: usize,
    y: usize,
}

#[allow(unused)]
#[derive(Default, Debug)]
struct Person {
    name: String,
    age: u8
}

fn main() -> Result<(), crate::error::AllocationError> {
    let mut mem = Mem::init();
    let mut alloc = crate::mem::BumpAllocator::init(&mut mem);
    
    let mut point = alloc.alloc(Point {x: 10, y: 20})?;
    let person = alloc.alloc(Person {name: "Elias".into(), age: 18})?;
    point.x = 90;
    println!("{:#?}", point);
    println!("{:#?}", person);
    
    for byte in (0..mem.0.len()).step_by(8) {
        for i in 0..8 {
            print!("{:02X} ", mem.0[byte + i]);
        }
        println!();
    }
    Ok(())
}