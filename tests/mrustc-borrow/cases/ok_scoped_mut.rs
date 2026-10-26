// rustc: ok
// nfcxx: ok
// An exclusive borrow ends with its block; a shared one follows.
fn main() {
    let mut x = 1;
    {
        let r = &mut x;
        *r += 1;
    }
    let s = &x;
    let _y = *s;
}
