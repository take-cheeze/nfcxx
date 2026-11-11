// rustc: ok
// nfcxx: ok
// A returned reference borrows from the argument (an inferred alias summary).
fn first(p: &(i32, i32)) -> &i32 {
    &p.0
}
fn main() {
    let t = (3, 4);
    let r = first(&t);
    let _v = *r;
}
