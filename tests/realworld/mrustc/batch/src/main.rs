use std::collections::HashMap;
fn main() {
    let mut m: HashMap<&str, u32> = HashMap::new();
    m.insert("a", 1);
    println!("{:?}", m.get("a"));
    println!("{}", base64::Engine::encode(&base64::engine::general_purpose::STANDARD, b"hi"));
    println!("{}", hex::encode("hi"));
    println!("{}", semver::Version::parse("1.2.3").unwrap());
    println!("{:?}", either::Either::<u8, u16>::Left(3));
    println!("{}", itoa::Buffer::new().format(42u32));
    let mut v: smallvec::SmallVec<[u8; 4]> = smallvec::SmallVec::new();
    v.push(1);
    println!("{:?}", v.as_slice());
    println!("{}", "ab\u{301}c".chars().count() + unicode_segmentation::UnicodeSegmentation::graphemes("ab\u{301}c", true).count());
    let mut h = fnv::FnvHasher::default();
    use std::hash::Hasher;
    h.write(b"x");
    println!("{}", h.finish() > 0);
    let _g = scopeguard::guard(1, |_| {});
    let cell: once_cell::sync::Lazy<u8> = once_cell::sync::Lazy::new(|| 7);
    println!("{}", *cell);
    log::info!("ok");
}
