fn main() {
    let v: Vec<u32> = (1..=10).collect();
    let total: u32 = v.iter().sum();
    let s = format!("{} {}", total, v.len());
    println!("{}", s);
}
