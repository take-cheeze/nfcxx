// rustc: E0502
// nfcxx: error
// diag: loan-conflict
// A function returns a slice of the Vec it borrows, and the slice is live across a push to the Vec.
fn view(v: &Vec<i32>) -> &[i32] {
    v.as_slice()
}

fn main() {
    let mut v: Vec<i32> = Vec::new();
    v.push(1);
    let s = view(&v);
    v.push(2);
    println!("{}", s[0]);
}
