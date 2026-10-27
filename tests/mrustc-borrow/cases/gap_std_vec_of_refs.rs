// rustc: ok
// nfcxx: refused
// diag: calls require lifetime/effect contracts
// A Vec of references keeps the borrows pushed into it, which no summary can say, so Vec's functions
// have summaries only for scalar elements and this program is refused.
fn main() {
    let x = 1;
    let mut v: Vec<&i32> = Vec::new();
    v.push(&x);
    println!("{}", v.len());
}
