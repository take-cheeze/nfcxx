use std::sync::atomic::{AtomicUsize, Ordering};

// A signal handler installed with the C library's signal(): raise() on this thread runs the handler before it returns.
static HITS: AtomicUsize = AtomicUsize::new(0);

const SIGUSR1: i32 = 10; // Linux

extern "C" {
    fn signal(sig: i32, handler: extern "C" fn(i32)) -> usize;
    fn raise(sig: i32) -> i32;
}

extern "C" fn on_usr1(sig: i32) {
    HITS.fetch_add(sig as usize, Ordering::SeqCst);
}

fn main() {
    unsafe {
        signal(SIGUSR1, on_usr1);
        raise(SIGUSR1);
        raise(SIGUSR1);
    }
    println!("hits {}", HITS.load(Ordering::SeqCst));
}
