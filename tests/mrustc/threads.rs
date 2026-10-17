use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
fn main() {
    let counter = Arc::new(AtomicUsize::new(0));
    let total = Arc::new(Mutex::new(0u64));
    let mut handles = Vec::new();
    for i in 0..4u64 {
        let c = counter.clone();
        let t = total.clone();
        handles.push(std::thread::spawn(move || {
            for _ in 0..1000 {
                c.fetch_add(1, Ordering::SeqCst);
            }
            *t.lock().unwrap() += i;
            i * 10
        }));
    }
    let rets: Vec<u64> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    println!("{} {} {:?}", counter.load(Ordering::SeqCst), *total.lock().unwrap(), rets);
}
