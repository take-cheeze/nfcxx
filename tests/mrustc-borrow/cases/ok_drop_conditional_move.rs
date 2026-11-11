// rustc: ok
// nfcxx: ok
// A Vec moved on one branch only. mrustc drops it at the end of main under a drop flag, which the
// translator turns into a drop of the obligation where it is still live: the moved branch owes
// nothing, the other owes the drop.
fn take(v: Vec<i32>) -> usize {
    v.len()
}
fn main() {
    let mut v: Vec<i32> = Vec::new();
    v.push(1);
    let c = v.len() > 0;
    if c {
        take(v);
    }
}
