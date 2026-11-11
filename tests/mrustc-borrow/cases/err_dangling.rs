// rustc: E0597
// nfcxx: error
// A reference outlives the block of its referent.
fn main() {
    let r;
    {
        let y = 1;
        r = &y;
    }
    let _v = *r;
}
