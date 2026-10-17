use std::collections::HashMap;
fn main() {
    let mut m = HashMap::new();
    for i in 0..1000u32 {
        m.insert(format!("k{}", i), i * i);
    }
    let sum: u64 = m.values().map(|v| *v as u64).sum();
    println!("{} {} {:?}", m.len(), sum, m.get("k31"));
}
