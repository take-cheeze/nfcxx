// rustc: E0597
// nfcxx: error
// A reference to an element outlives the Vec, which is dropped at the end of its block. println! reads
// the element after the drop.
fn main() {
    let r;
    {
        let mut v: Vec<i32> = Vec::new();
        v.push(1);
        r = &v[0];
    }
    println!("{}", r);
}
