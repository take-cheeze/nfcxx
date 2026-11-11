// rustc: ok
// nfcxx: ok
// String::new, push_str of a literal, push, as_str, len, String::from and to_string, a function
// that takes `&str`, and printing Strings and `&str`s. The `&str` of the String is dead before the
// next push.
fn count(s: &str) -> usize {
    s.len()
}

fn main() {
    let mut st = String::new();
    st.push_str("ab");
    let t: &str = st.as_str();
    println!("{} {}", t, count(t));
    st.push('c');
    let u = "lit";
    println!("{} {} {} {}", st, u, st.len(), count(u));
    let o = String::from("xy");
    let o2 = "z".to_string();
    println!("{} {}", o, o2);
}
