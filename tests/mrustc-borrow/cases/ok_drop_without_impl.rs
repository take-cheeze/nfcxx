// rustc: ok
// nfcxx: ok
// err_drop_impl_dangling without the Drop impl: the struct has no drop glue, so nothing uses the
// reference after the inner block (NLL).
struct Holder<'a> {
    r: &'a i32,
}
fn main() {
    let h;
    {
        let x = 5;
        h = Holder { r: &x };
    }
}
