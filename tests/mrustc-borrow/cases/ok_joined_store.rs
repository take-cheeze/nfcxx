// rustc: ok
// nfcxx: ok
// A write through a reference that may point to either of two locals, then writes to both once it is dead.
fn main() {
    let mut a = 1;
    let mut b = 2;
    let c = a < b;
    let r = if c { &mut a } else { &mut b };
    *r += 1;
    a += 1;
    b += 1;
}
