// rustc: E0597
// nfcxx: error
// diag: inactive-loan
// A reference into a Box outlives it: the Box is dropped at the end of its block, which ends the
// loan of its contents, and println! reads through the reference after that.
fn main() {
    let r;
    {
        let b = Box::new(1);
        r = &*b;
    }
    println!("{}", r);
}
