// rustc: E0381
// nfcxx: error
// A read of a local that is assigned on one branch only.
fn main() {
    let x: i32;
    let c = 3;
    if c > 2 {
        x = 1;
    }
    let _y = x;
}
