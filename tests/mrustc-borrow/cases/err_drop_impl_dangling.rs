// rustc: E0597
// nfcxx: error
// diag: inactive-loan
// A struct with a Drop impl holds a reference to a local of an inner block, and is dropped after
// that block: its Drop may use the reference, so the drop (a deep obligation) reads through it
// after the local's storage, and the loan, have ended. ok_drop_without_impl is the same program
// without the impl.
struct Holder<'a> {
    r: &'a i32,
}
impl<'a> Drop for Holder<'a> {
    fn drop(&mut self) {
        println!("{}", self.r);
    }
}
fn main() {
    let h;
    {
        let x = 5;
        h = Holder { r: &x };
    }
}
