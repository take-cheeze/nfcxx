// Rust: text processing on a byte buffer, with no allocation (no std): splitting a &str into words, counting
// letters, and building an upper-case copy in a fixed array. Byte strings and slices print through log_str.
#![no_std]
#![no_main]

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}

extern "C" {
    fn log_str(s: *const u8, len: i64);
}

fn say(s: &[u8]) {
    unsafe { log_str(s.as_ptr(), s.len() as i64) }
}

const TEXT: &str = "the quick brown fox jumps over the lazy dog";

#[no_mangle]
pub extern "C" fn main() -> i32 {
    // the longest word, and the number of words
    let mut longest = "";
    let mut words = 0;
    for w in TEXT.split(' ') {
        words += 1;
        if w.len() > longest.len() {
            longest = w;
        }
    }
    say(longest.as_bytes());

    // how many distinct letters (a pangram has all 26)
    let mut seen = [false; 26];
    for b in TEXT.bytes().filter(|b| b.is_ascii_lowercase()) {
        seen[(b - b'a') as usize] = true;
    }
    let distinct = seen.iter().filter(|&&s| s).count() as i32;

    // the first letter of each word, upper case
    let mut initials = [0u8; 16];
    let mut n = 0;
    for w in TEXT.split(' ') {
        initials[n] = w.as_bytes()[0].to_ascii_uppercase();
        n += 1;
    }
    say(&initials[..n]);

    words * 100 + distinct // 9 words, 26 letters
}
