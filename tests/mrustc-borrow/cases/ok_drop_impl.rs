// rustc: ok
// nfcxx: ok
// A struct with a Drop impl is one obligation, dropped at the end of main. The borrow of its field
// ends before the write, and the write to a field keeps the value live.
struct Guard {
    n: i32,
}
impl Drop for Guard {
    fn drop(&mut self) {
        self.n = 0;
    }
}
fn main() {
    let mut g = Guard { n: 1 };
    let r = &g.n;
    println!("{}", r);
    g.n = 2;
}
