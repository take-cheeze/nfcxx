// rustc: E0597
// nfcxx: error
// A reference pushed into a Vec outlives its referent's scope, and the Vec is used after it.
fn main() {
    let x = 1;
    let mut v: Vec<&i32> = Vec::new();
    v.push(&x);
    {
        let y = 2;
        v.push(&y);
    }
    println!("{}", v.len());
}
