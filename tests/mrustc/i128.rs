fn main() {
    let a: u128 = 0xffff_ffff_ffff_ffff_ffff;
    let b: i128 = -170141183460469231731687303715884105728;
    println!("{} {} {}", a * 3, b + 1, (a >> 7) as u64);
}
