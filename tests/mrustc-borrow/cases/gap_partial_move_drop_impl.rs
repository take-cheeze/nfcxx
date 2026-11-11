// rustc: E0509
// nfcxx: refused
// diag: copy of drop-obligated storage
// A move out of a field of a struct with a Drop impl. mrustc accepts it. The struct is one drop
// obligation, so the translator leaves the move a copy of part of it, which the checker refuses.
struct Guard {
    v: Vec<i32>,
}
impl Drop for Guard {
    fn drop(&mut self) {}
}
fn take(v: Vec<i32>) -> usize {
    v.len()
}
fn main() {
    let g = Guard { v: Vec::new() };
    take(g.v);
}
