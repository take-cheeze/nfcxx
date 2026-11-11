// rustc: ok
// nfcxx: ok
// A local declared in a loop body starts again on each iteration.
fn main() {
    let mut total = 0;
    let mut i = 0;
    while i < 3 {
        let step = i * 2;
        let r = &step;
        total += *r;
        i += 1;
    }
    let _t = total;
}
