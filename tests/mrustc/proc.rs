use std::process::Command;
fn main() {
    let out = Command::new("echo").arg("from child").output().unwrap();
    println!("{} {:?}", out.status.code().unwrap(), String::from_utf8_lossy(&out.stdout));
}
