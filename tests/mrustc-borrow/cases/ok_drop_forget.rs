// rustc: ok
// nfcxx: ok
// mem::forget and mem::drop take their argument by value: the Vec is moved into the call, which
// owes its drop (or leaks it), so main owes nothing.
fn main() {
    let mut v: Vec<i32> = Vec::new();
    v.push(1);
    std::mem::forget(v);
    let w: Vec<i32> = Vec::new();
    drop(w);
}
