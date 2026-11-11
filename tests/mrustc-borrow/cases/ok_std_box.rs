// rustc: ok
// nfcxx: ok
// Box::new, reads and writes through the Box, and a borrow of its contents that ends before the write.
fn main() {
    let mut b = Box::new(7);
    let r = &*b;
    println!("{}", r);
    *b += 1;
    println!("{}", *b);
}
