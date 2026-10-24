// Integer matches become SWITCHVALUE terminators, including matches producing enums.
#[derive(Clone, Copy)]
enum State { Empty, First, Rest }

#[inline(never)]
fn state(n: u8) -> State {
    match n { 0 => State::Empty, 1 => State::First, _ => State::Rest }
}

#[inline(never)]
fn signed(n: i32) -> i32 {
    match n { -7 => 1, 0 => 2, 42 => 3, _ => 4 }
}

#[inline(never)]
fn wide(n: u64) -> u8 {
    match n { 0 => 1, 9218868437227405312 => 2, 18446744073709551615 => 3, _ => 4 }
}

fn main() {
    for n in 0..4 {
        println!("{}", match state(n) { State::Empty => 10, State::First => 20, State::Rest => 30 });
    }
    println!("{} {} {} {}", signed(-7), signed(0), signed(42), signed(9));
    println!("{} {} {} {}", wide(0), wide(9218868437227405312), wide(u64::MAX), wide(7));
}
