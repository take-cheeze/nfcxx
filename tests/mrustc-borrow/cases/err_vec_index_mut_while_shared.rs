// rustc: E0502
// nfcxx: error
// diag: loan-conflict
// `&mut v[0]` while a shared reference to another element is live: indexing borrows the whole Vec.
fn main() {
    let mut v: Vec<i32> = Vec::new();
    v.push(1);
    v.push(2);
    let b = &v[1];
    let a = &mut v[0];
    *a = 3;
    println!("{}", b);
}
