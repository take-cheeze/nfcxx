// rustc: ok
// nfcxx: ok
// Vec push, len, pop, indexing and writes through index_mut, loops over a range, and a function that
// reads the Vec through `&`. Each element reference is dead before the next push.
fn sum(v: &Vec<i64>) -> i64 {
    let mut s = 0;
    for i in 0..v.len() {
        s += v[i];
    }
    s
}

fn main() {
    let mut v: Vec<i64> = Vec::new();
    for i in 0..5 {
        v.push(i * i);
    }
    let first = &v[0];
    println!("{}", first);
    v.push(25);
    v[1] = 2;
    let x = &mut v[2];
    *x += 1;
    let last = v.pop();
    if last.is_some() {
        println!("{} {}", last.unwrap(), sum(&v));
    }
    println!("{} {}", v.len(), v.is_empty());
}
