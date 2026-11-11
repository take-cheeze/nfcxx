use serde_json::Value;

fn main() {
    let v: Value = serde_json::from_str(r#"{"name":"nfcxx","tags":["c","rust"],"n":42,"ok":true,"pi":3.5}"#).unwrap();
    println!("{}", v["name"]);
    println!("{}", v["tags"][1]);
    println!("{}", v["n"].as_i64().unwrap() + 1);
    let s = serde_json::to_string(&v).unwrap();
    println!("{}", s);
    let back: Value = serde_json::from_str(&s).unwrap();
    println!("{}", back == v);
    let bad = serde_json::from_str::<Value>("{").unwrap_err();
    println!("error at line {}", bad.line());
}
