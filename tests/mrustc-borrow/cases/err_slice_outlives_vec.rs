// rustc: E0597
// nfcxx: error
// A slice of a Vec is used after the Vec's scope ends.
fn main() {
    let s: &[i32];
    {
        let mut v: Vec<i32> = Vec::new();
        v.push(1);
        s = v.as_slice();
    }
    println!("{}", s[0]);
}
