// rustc: ok
// nfcxx: ok
// A Vec<&i32> keeps the borrows pushed into it: its elements are read by indexing, by iterating it
// and through pop. x is assigned once the Vec's last use is past: dropping a Vec does not use the
// references it holds.
fn main() {
    let mut x = 1;
    let y = 2;
    let mut v: Vec<&i32> = Vec::new();
    v.push(&x);
    v.push(&y);
    let mut s = 0;
    for r in &v {
        s += **r;
    }
    for r in v.iter() {
        s += **r;
    }
    let first = v[0];
    let last = v.pop();
    println!("{} {} {} {}", s, first, v.len(), last.unwrap());
    x = 3;
    println!("{}", x);
}
