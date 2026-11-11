// rustc: E0505
// nfcxx: error
// diag: loan-conflict
// A Vec moved on one branch while a reference to it is still used after the branch.
fn take(v: Vec<i32>) -> usize {
    v.len()
}
fn main() {
    let mut v: Vec<i32> = Vec::new();
    v.push(1);
    let r = &v;
    let c = r.len() > 0;
    if c {
        take(v);
    }
    println!("{}", r.len());
}
