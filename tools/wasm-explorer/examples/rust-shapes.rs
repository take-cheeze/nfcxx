// Rust, through rustc's LLVM IR (-C opt-level=1, overflow checks on) and llvm-to-pathb.rb. The module has no
// standard library (#![no_std]) and no Rust entry point (#![no_main]): main is a C function the page calls, and
// the browser bindings are extern "C" functions. A panic (an overflow, an index out of range) traps.
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

enum Shape {
    Circle(i32),
    Rect(i32, i32),
    Empty,
}

fn area(s: &Shape) -> i32 {
    match s {
        Shape::Circle(r) => 3 * r * r,
        Shape::Rect(w, h) => w * h,
        Shape::Empty => 0,
    }
}

fn sort(v: &mut [i32]) {
    for i in 1..v.len() {
        let mut j = i;
        while j > 0 && v[j - 1] > v[j] {
            v.swap(j - 1, j);
            j -= 1;
        }
    }
}

#[no_mangle]
pub extern "C" fn main() -> i32 {
    let msg = "hello from rust";
    unsafe { log_str(msg.as_ptr(), msg.len() as i64) };
    let mut v = [9, 3, 7, 1, 5];
    sort(&mut v);
    let weighted: i32 = v.iter().enumerate().map(|(i, x)| (i as i32 + 1) * x).sum();
    let shapes = [Shape::Circle(2), Shape::Rect(3, 4), Shape::Empty];
    let total: i32 = shapes.iter().map(area).sum();
    unsafe { log_i32(total) };
    weighted + total // 95 + 24
}
