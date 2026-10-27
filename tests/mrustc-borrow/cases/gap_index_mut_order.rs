// rustc: E0502
// nfcxx: ok
// Accepted where rustc is stricter: rustc takes IndexMut's `&mut v` (not two-phase) before it
// evaluates the index, which then reads `v`. mrustc evaluates the index first, so its MIR has no
// conflict. The program is still memory-safe.
fn main() {
    let mut v: Vec<i32> = Vec::new();
    v.push(1);
    v[v.len() - 1] = 7;
    let _n = v.len();
}
