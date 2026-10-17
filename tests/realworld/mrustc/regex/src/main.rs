use regex::Regex;

fn main() {
    let re = Regex::new(r"(\d{4})-(\d{2})-(\d{2})").unwrap();
    let text = "released 2024-03-15, patched 2025-01-02";
    for caps in re.captures_iter(text) {
        println!("{} {} {}", &caps[1], &caps[2], &caps[3]);
    }
    let words = Regex::new(r"(?i)\b(rust|c\+\+)\b").unwrap();
    println!("{}", words.replace_all("Rust and C++ and RUST", "<$1>"));
    println!("{}", Regex::new(r"^a.*z$").unwrap().is_match("abcz"));
    println!("{:?}", Regex::new("[").is_err());
}
