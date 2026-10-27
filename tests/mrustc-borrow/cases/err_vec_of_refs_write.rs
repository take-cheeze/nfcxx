// rustc: E0506
// nfcxx: error
// diag: loan-conflict
// A Vec<&i32> keeps the borrow of x pushed into it, so x cannot be assigned while the Vec is used.
// The borrow is the first of two pushed: the second push joins the references, not replaces them.
fn main() {
    let mut x = 1;
    let y = 2;
    let mut v: Vec<&i32> = Vec::new();
    v.push(&x);
    v.push(&y);
    x = 5;
    println!("{}", v[1]);
}
