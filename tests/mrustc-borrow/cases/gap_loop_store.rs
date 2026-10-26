// rustc: E0499
// nfcxx: refused
// A borrow from one iteration stored in a variable that outlives the loop. Storing a pointer into a
// slot whose provenance is a join of several places is outside the supported subset.
fn main() {
    let mut x = 1;
    let mut keep: &mut i32 = &mut 0;
    let mut i = 0;
    while i < 2 {
        let r = &mut x;
        if i == 0 {
            keep = r;
        }
        i += 1;
    }
    *keep += 1;
}
