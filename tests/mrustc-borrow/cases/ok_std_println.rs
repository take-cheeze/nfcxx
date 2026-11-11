// rustc: ok
// nfcxx: ok
// println! and eprintln! with several arguments and format specs: the fmt::Arguments holds borrows of
// the values until _print reads them, and the values are free again after it.
fn main() {
    let mut n = 1;
    let r = &n;
    println!("{} {:?} {:x}", n, r, 255u32);
    n += 1;
    eprintln!("n = {}", n);
    println!("done");
}
