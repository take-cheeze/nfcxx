// A function the constant evaluator does not run, so the operand is only known at run time (mrustc has no black_box yet).
fn opaque<T>(v: T) -> T {
    v
}

// Checked, overflowing, wrapping and saturating arithmetic at several widths. Every operand goes through opaque, so the
// operations are compiled and run, not folded by mrustc's constant evaluator. mrustc's constant evaluator folds
// (-30000i16).checked_mul(2) to Some(5536), which opaque avoids. (1u128 << 100).checked_mul(1 << 28) gave Some(0) with
// mrustc's former 128-bit multiply helper (bit by bit, which dropped the bits it shifted out); it is None now.
fn main() {
    let one = std::env::args().count() as i32; // 1 when run without arguments
    println!("{:?}", opaque(i32::MAX - one + 1).checked_add(1));
    println!("{:?}", opaque(5i32).checked_add(7));
    println!("{:?}", opaque(i64::MAX / 2 + one as i64).checked_mul(2));
    println!("{:?}", opaque(1i64).checked_shl(70));
    println!("{:?}", opaque(i32::MIN).checked_div(-one));
    println!("{:?}", opaque(0u8).checked_sub(one as u8));
    println!("{:?}", opaque(200u8).checked_mul(2));
    println!("{:?}", opaque(100u8).checked_add(100));
    println!("{:?}", opaque(60000u16).checked_add(6000));
    println!("{:?}", opaque(-30000i16).checked_mul(2));
    println!("{:?}", opaque(usize::MAX).checked_add(one as usize));
    println!("{:?}", opaque(3usize).checked_sub(4));
    println!("{:?}", opaque(i128::MAX).checked_add(one as i128));
    println!("{:?}", opaque(1u128 << 100).checked_mul(1 << 27));
    println!("{:?}", opaque(1u128 << 100).checked_mul(1 << 28));
    println!("{:?}", opaque(7i8).overflowing_add(120));
    println!("{:?}", opaque(255u8).overflowing_add(one as u8));
    println!("{:?}", opaque(i32::MIN).overflowing_neg());
    println!("{} {}", opaque(i32::MAX).wrapping_add(one), opaque(10u8).wrapping_sub(20));
    println!("{} {}", opaque(i16::MIN).saturating_sub(one as i16), opaque(250u8).saturating_add(10));
    println!("{:?}", opaque(12345u32).checked_next_power_of_two());
    let mut acc: u32 = 1;
    let mut steps = 0;
    while let Some(next) = acc.checked_mul(3) {
        acc = next;
        steps += 1;
    }
    println!("{} {}", acc, steps);
}
