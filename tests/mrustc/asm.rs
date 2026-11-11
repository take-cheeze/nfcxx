// Inline asm through the pipeline: cproc has no inline asm, so scripts/mrustc-prep.rb outlines each statement into a
// helper that the host C compiler builds (docs/notes/mrustc-frontend.md, section 2). The forms are portable-atomic's:
// operands in named registers, operands in registers the compiler picks (with the `x` modifier), a pointer operand,
// a byte output, and a 16-byte compare-exchange.
use std::arch::asm;

#[inline(never)]
fn add(mut x: u64, y: u64) -> u64 {
    unsafe { asm!("add {0}, {1}", inout(reg) x, in(reg) y) };
    x
}

#[inline(never)]
fn bts16(p: &mut u16, bit: u16) -> bool {
    let r: u8;
    unsafe {
        asm!("lock bts word ptr [{0}], {1:x}", "setb {2}", in(reg) p as *mut u16, in(reg) bit, out(reg_byte) r)
    };
    r != 0
}

#[inline(never)]
fn pair() -> (u64, u64) {
    let (lo, hi): (u64, u64);
    unsafe { asm!("mov rax, 3", "mov rdx, 4", out("rax") lo, out("rdx") hi) };
    (lo, hi)
}

// cmpxchg16b on a 16-aligned pair: replace (1, 2) with (5, 6); rbx is reserved, so the new low word goes through rsi.
#[repr(C, align(16))]
struct Pair(u64, u64);

#[inline(never)]
fn cas16(p: &mut Pair) -> bool {
    let ok: u8;
    unsafe {
        asm!("xchg rsi, rbx", "lock cmpxchg16b xmmword ptr [rdi]", "sete cl", "mov rbx, rsi",
             in("rdi") p as *mut Pair, inout("rax") 1u64 => _, inout("rdx") 2u64 => _,
             inout("rsi") 5u64 => _, inout("rcx") 6u64 => _, lateout("cl") ok)
    };
    ok != 0
}

fn main() {
    let mut v: u16 = 0x00f0;
    let a = bts16(&mut v, 1);
    let b = bts16(&mut v, 4);
    let mut p = Pair(1, 2);
    let c = cas16(&mut p);
    let d = cas16(&mut p);
    println!("{} {:#x} {} {} {:?} {} {} {} {}", add(40, 2), v, a, b, pair(), c, d, p.0, p.1);
}
