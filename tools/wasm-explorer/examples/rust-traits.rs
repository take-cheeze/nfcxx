// Rust: traits and trait objects (a call through a vtable is a call_indirect), generics, closures and Option.
// The output goes to the Console through the log_str and log_i32 bindings.
#![no_std]
#![no_main]

// A panic (an overflow, an index out of range) prints where it happened and ends the run: abort is a browser binding.
#[panic_handler]
fn panic(info: &core::panic::PanicInfo) -> ! {
    extern "C" {
        fn log_str(s: *const u8, len: i64);
        fn log_i32(value: i32);
        fn abort() -> !;
    }
    unsafe {
        let what = b"panicked at (file, line):";
        log_str(what.as_ptr(), what.len() as i64);
        if let Some(loc) = info.location() {
            log_str(loc.file().as_ptr(), loc.file().len() as i64);
            log_i32(loc.line() as i32);
        }
        abort()
    }
}

extern "C" {
    fn log_str(s: *const u8, len: i64);
    fn log_i32(value: i32);
}

fn say(s: &str) {
    unsafe { log_str(s.as_ptr(), s.len() as i64) }
}

trait Shape {
    fn name(&self) -> &'static str;
    fn area(&self) -> i32;
    fn scaled(&self, k: i32) -> i32 {
        self.area() * k * k
    }
}

struct Square(i32);
struct Rect {
    w: i32,
    h: i32,
}

impl Shape for Square {
    fn name(&self) -> &'static str {
        "square"
    }
    fn area(&self) -> i32 {
        self.0 * self.0
    }
}

impl Shape for Rect {
    fn name(&self) -> &'static str {
        "rect"
    }
    fn area(&self) -> i32 {
        self.w * self.h
    }
}

#[inline(never)]
fn largest<'a>(shapes: &[&'a dyn Shape]) -> Option<&'a dyn Shape> {
    let mut best: Option<&dyn Shape> = None;
    for &s in shapes {
        if best.map_or(true, |b| s.area() > b.area()) {
            best = Some(s);
        }
    }
    best
}

fn sum_by<T, F: Fn(&T) -> i32>(items: &[T], f: F) -> i32 {
    items.iter().map(|x| f(x)).sum()
}

#[no_mangle]
pub extern "C" fn main() -> i32 {
    let sq = Square(4);
    let r = Rect { w: 3, h: 7 };
    let shapes: [&dyn Shape; 2] = [&sq, &r];
    for s in shapes.iter() {
        say(s.name());
        unsafe { log_i32(s.area()) };
    }
    let big = largest(&shapes).map(|s| s.name()).unwrap_or("none");
    say(big);
    let offset = 10;
    let total = sum_by(&shapes, |s| s.scaled(2) + offset); // (16 + 21) * 4 + 20
    total
}
