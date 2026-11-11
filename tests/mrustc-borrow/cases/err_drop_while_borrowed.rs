// rustc: E0505
// nfcxx: error
// diag: loan-conflict
// An explicit drop of a Vec, which moves it, while a reference to it is still used.
fn main() {
    let mut v: Vec<i32> = Vec::new();
    v.push(1);
    let r = &v;
    drop(v);
    println!("{}", r.len());
}
