// rustc: ok
// nfcxx: ok
// The autoref'd receiver of push is two-phase, so the argument may read the Vec.
fn main() {
    let mut v: Vec<i32> = Vec::new();
    v.push(v.len() as i32);
    v.push(v.len() as i32);
    v[0] = v.len() as i32;
    let _n = v.len();
}
