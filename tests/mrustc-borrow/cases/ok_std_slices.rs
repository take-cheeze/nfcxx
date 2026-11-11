// rustc: ok
// nfcxx: ok
// Slices and their iterators: as_slice, iter(), `for x in &v`, `for x in s`, a slice of an array,
// functions that take `&[i32]` and index and iterate it, one that returns a slice of its argument,
// len, first, and a write through as_mut_slice once the shared slices are dead.
fn view(v: &Vec<i32>) -> &[i32] {
    v.as_slice()
}

fn total(s: &[i32]) -> i32 {
    let mut t = 0;
    for x in s.iter() {
        t += *x;
    }
    t + s[0] + s.len() as i32
}

fn max(s: &[i32]) -> i32 {
    let mut m = s[0];
    for x in s {
        if *x > m {
            m = *x;
        }
    }
    m
}

fn main() {
    let mut v: Vec<i32> = Vec::new();
    v.push(1);
    v.push(2);
    let s = v.as_slice();
    let mut n = total(s) + s.len() as i32 + view(&v)[1];
    for x in &v {
        n += *x;
    }
    let arr = [3, 4, 5];
    let a: &[i32] = &arr;
    let f = a.first();
    let m = v.as_mut_slice();
    m[0] = 7;
    v.push(3);
    println!("{} {} {} {}", n, max(a), f.is_some(), v.len());
}
