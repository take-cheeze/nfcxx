// rustc: E0505
// nfcxx: error
// diag: loan-conflict
// A move of a whole enum while a reference to it is still used. The enum is not Copy, so the
// assignment moves its bytes, tag included.
enum Token {
    Num(i32),
    End,
}
fn main() {
    let t = Token::Num(3);
    let r = &t;
    let u = t;
    let a = match r {
        Token::Num(n) => *n,
        Token::End => 0,
    };
    let b = match u {
        Token::Num(n) => n,
        Token::End => 0,
    };
    println!("{}", a + b);
}
