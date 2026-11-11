use std::io::{Read, Write};
fn main() {
    let path = std::env::temp_dir().join("nfcxx_rt_fsio.txt");
    {
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(b"hello file\nline two\n").unwrap();
    }
    let mut s = String::new();
    std::fs::File::open(&path).unwrap().read_to_string(&mut s).unwrap();
    println!("{:?} {}", s, std::fs::metadata(&path).unwrap().len());
    std::fs::remove_file(&path).unwrap();
    println!("{}", std::fs::metadata(&path).is_err());
}
