use clap::{Arg, Command};

fn main() {
    let m = Command::new("tool")
        .arg(Arg::new("count").short('c').long("count").value_name("N"))
        .arg(Arg::new("name").required(true))
        .get_matches_from(["tool", "--count", "3", "world"]);
    let count: u32 = m.get_one::<String>("count").unwrap().parse().unwrap();
    println!("{} {}", m.get_one::<String>("name").unwrap(), count * 2);
    let err = Command::new("tool")
        .arg(Arg::new("name").required(true))
        .try_get_matches_from(["tool"])
        .unwrap_err();
    println!("{:?}", err.kind());
}
