// rustc: E0499
// nfcxx: error
// diag: inactive-loan
// A borrow from one iteration stored in a variable that outlives the loop. Taking `&mut x` again in the next
// iteration ends it, so the write through `keep`, which may still hold it, uses an ended loan. rustc reports
// the second `&mut x` instead.
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
