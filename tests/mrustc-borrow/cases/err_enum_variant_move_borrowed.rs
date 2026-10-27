// rustc: E0505
// nfcxx: error
// diag: loan-conflict
// A move out of an enum variant while a reference to the enum is still used.
enum Msg {
    Data(Vec<i32>),
    Empty,
}
fn take(v: Vec<i32>) -> usize {
    v.len()
}
fn main() {
    let mut v: Vec<i32> = Vec::new();
    v.push(1);
    let m = Msg::Data(v);
    let r = &m;
    let n = match m {
        Msg::Data(w) => take(w),
        Msg::Empty => 0,
    };
    let k = match r {
        Msg::Data(_) => 1,
        Msg::Empty => 0,
    };
    println!("{}", n + k);
}
