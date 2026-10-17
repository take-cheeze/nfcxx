use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

// std::time: a monotonic clock around a sleep, the wall clock, and Duration arithmetic. The printed values are
// comparisons and fixed conversions, so the output does not depend on the time of day.
fn main() {
    let start = Instant::now();
    std::thread::sleep(Duration::from_millis(30));
    let slept = start.elapsed();
    println!("slept at least 30ms: {}", slept >= Duration::from_millis(30));
    println!("under 5s: {}", slept < Duration::from_secs(5));

    let a = Instant::now();
    let b = Instant::now();
    println!("monotonic: {}", b >= a);

    let wall = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
    println!("after 2020: {}", wall.as_secs() > 1_577_836_800);

    let d = Duration::from_millis(1500);
    println!("{} {} {}", d.as_secs(), d.subsec_millis(), d.as_millis());
    println!("{:?} {:?}", Duration::from_micros(2500), Duration::from_nanos(42));
    let later = start + Duration::from_secs(1);
    println!("{}", later.duration_since(start).as_secs());
    let epoch_plus = UNIX_EPOCH.checked_add(Duration::from_secs(10)).unwrap();
    println!("{}", epoch_plus.duration_since(UNIX_EPOCH).unwrap().as_secs());
}
