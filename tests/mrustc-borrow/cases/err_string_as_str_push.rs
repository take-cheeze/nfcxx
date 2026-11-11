// rustc: E0502
// nfcxx: error
// diag: loan-conflict
// A &str of a String is live across a push to the String.
fn main() {
    let mut s = String::new();
    s.push_str("a");
    let t = s.as_str();
    s.push('b');
    println!("{}", t);
}
