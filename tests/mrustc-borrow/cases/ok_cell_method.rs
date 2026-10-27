// rustc: ok
// nfcxx: ok
// A `&self` method and a `&Cell` function that write a Cell, called through two shared references. Their
// parameters are `&T` (readonly), and their summaries are `read`: the writes leave nothing the checker
// tracks changed. Cell::replace and take write it too.
use std::cell::Cell;
struct Node {
    hits: Cell<u32>,
    id: u32,
}
impl Node {
    fn touch(&self) -> u32 {
        self.hits.set(self.hits.get() + 1);
        self.id
    }
}
fn bump(c: &Cell<i32>) -> i32 {
    c.set(c.get() + 1);
    c.replace(0)
}
fn main() {
    let n = Node { hits: Cell::new(0), id: 7 };
    let a = &n;
    let b = &n;
    let id = a.touch() + b.touch();
    let c = Cell::new(1);
    let x = bump(&c) + bump(&c);
    c.set(x);
    println!("{} {} {}", id, n.hits.get(), c.take());
}
