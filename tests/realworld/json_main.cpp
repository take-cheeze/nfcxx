// nlohmann/json real-world driver: parse, mutate, dump with indentation, iterate, round-trip,
// to_json/from_json for a user struct, exceptions on bad input. Single translation unit. The output is
// compared byte for byte with the host g++ build (tests/realworld/run_json.sh).
#include <nlohmann/json.hpp>
#include <cstdio>
#include <iostream>
#include <map>
#include <string>
#include <vector>

using nlohmann::json;

struct Person {
  std::string name;
  int age = 0;
  std::vector<std::string> tags;
  double score = 0;
};
static void to_json(json &j, const Person &p) {
  j = json{{"name", p.name}, {"age", p.age}, {"tags", p.tags}, {"score", p.score}};
}
static void from_json(const json &j, Person &p) {
  j.at("name").get_to(p.name);
  j.at("age").get_to(p.age);
  j.at("tags").get_to(p.tags);
  j.at("score").get_to(p.score);
}

int main() {
  json doc = json::parse(R"({
    "title": "nfcxx", "version": 3, "pi": 3.14159, "ok": true, "none": null,
    "list": [1, 2, 3, "four", [5, 6], {"seven": 7}],
    "nested": {"a": {"b": {"c": "deep"}}}, "esc": "tab\t quote\" unié €"
  })");
  std::cout << doc["title"] << ' ' << doc["version"] << ' ' << doc["pi"] << ' ' << doc["ok"] << ' '
            << doc["none"] << '\n';
  std::cout << doc["nested"]["a"]["b"]["c"].get<std::string>() << ' ' << doc["list"].size() << '\n';

  // mutate
  doc["version"] = doc["version"].get<int>() + 1;
  doc["added"] = {{"x", 1}, {"y", {1, 2, 3}}};
  doc["list"].push_back("tail");
  doc["list"][0] = 100;
  doc.erase("none");
  doc["nested"]["a"]["b"]["d"] = 2.5e10;
  doc["big"] = 9007199254740993LL;
  doc["neg"] = -123456789012LL;
  doc["u64"] = 18446744073709551615ULL;
  std::cout << doc.dump(2) << '\n';
  std::cout << doc.dump() << '\n';

  // iterate
  for (auto it = doc.begin(); it != doc.end(); ++it)
    std::cout << it.key() << ':' << it->type_name() << ' ';
  std::cout << '\n';
  for (auto &el : doc["list"]) std::cout << el.dump() << ';';
  std::cout << '\n';
  for (auto &[k, v] : doc["added"].items()) std::cout << k << '=' << v << ',';
  std::cout << '\n';

  // round trip
  std::string s = doc.dump();
  json again = json::parse(s);
  std::cout << (again == doc ? "roundtrip equal" : "roundtrip DIFFERENT") << '\n';
  std::vector<std::uint8_t> cbor = json::to_cbor(doc), mp = json::to_msgpack(doc);
  std::cout << "cbor " << cbor.size() << " msgpack " << mp.size() << " "
            << (json::from_cbor(cbor) == doc) << (json::from_msgpack(mp) == doc) << '\n';

  // user struct
  Person p{"Ada", 36, {"math", "code"}, 99.5};
  json pj = p;
  std::cout << pj.dump() << '\n';
  Person q = json::parse(R"({"name":"Bob","age":41,"tags":[],"score":1.25})").get<Person>();
  std::cout << q.name << ' ' << q.age << ' ' << q.tags.size() << ' ' << q.score << '\n';
  std::vector<Person> ps{p, q};
  std::cout << json(ps).dump(1) << '\n';
  std::map<std::string, int> m{{"a", 1}, {"b", 2}};
  std::cout << json(m) << ' ' << json(std::vector<int>{3, 1, 2}) << '\n';

  // errors
  const char *bad[] = {"{\"a\": }", "[1, 2,", "{\"a\" 1}", "nul", "\"unterminated", "[1] x", ""};
  for (const char *b : bad) {
    try {
      (void)json::parse(b);
      std::cout << "parsed?! " << b << '\n';
    } catch (const json::parse_error &e) {
      std::cout << "parse_error " << e.id << ": " << e.what() << '\n';
    }
  }
  try {
    doc.at("missing");
  } catch (const json::out_of_range &e) {
    std::cout << "out_of_range " << e.id << ": " << e.what() << '\n';
  }
  try {
    doc["title"].get<int>();
  } catch (const json::type_error &e) {
    std::cout << "type_error " << e.id << ": " << e.what() << '\n';
  }
  try {
    json::parse(R"({"name":"x"})").get<Person>();
  } catch (const json::exception &e) {
    std::cout << "exception " << e.id << ": " << e.what() << '\n';
  }
  json sloppy = json::parse("[1, /*c*/ 2]", nullptr, false, true);
  std::cout << sloppy << ' ' << json::parse("{bad", nullptr, false).is_discarded() << '\n';
  std::cout << json::parse("1e400", nullptr, false).dump() << ' ' << json(0.1 + 0.2) << ' '
            << json(1.0 / 3) << ' ' << json(-0.0) << ' ' << json(1e-7) << ' ' << json(123456789.0) << '\n';
  std::cout << json::diff(json::parse("[1,2,3]"), json::parse("[1,5,3,4]")).dump() << '\n';
  json patched = json::parse(R"({"a":1})").patch(json::parse(R"([{"op":"add","path":"/b","value":[1]}])"));
  std::cout << patched << ' ' << doc.flatten().size() << '\n';
  return 0;
}
