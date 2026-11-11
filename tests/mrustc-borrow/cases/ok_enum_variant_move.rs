// rustc: ok
// nfcxx: ok
// Moves into an enum variant and out of one (a downcast): the payload's bytes move with the Vec,
// whose drop obligation goes with them.
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
    let n = match m {
        Msg::Data(w) => take(w),
        Msg::Empty => 0,
    };
    println!("{}", n);
}
