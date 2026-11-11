// rustc: E0506
// nfcxx: error
// diag: loan-conflict
// A stored format_args! keeps its borrow of `x` until it is printed, so the assignment conflicts.
fn main() {
    let mut x = 1;
    let a = format_args!("{}", x);
    x = 2;
    println!("{}", a);
    println!("{}", x);
}
