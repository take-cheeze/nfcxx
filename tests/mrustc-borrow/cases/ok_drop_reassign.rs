// rustc: ok
// nfcxx: ok
// An assignment to a live Vec drops its old value first, and the new one is owed from then on.
fn main() {
    let mut v: Vec<i32> = Vec::new();
    v.push(1);
    v = Vec::new();
    v.push(2);
}
