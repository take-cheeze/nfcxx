// EXPECT: 0
// STDOUT: same
// std::ostringstream / istringstream / stringstream with manipulators (setw, setfill, hex, fixed, setprecision), number
// formatting and parsing, std::string operations, std::to_string, std::getline, and writing to std::cout / std::cerr.
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

int main() {
  std::ostringstream os;
  os << "int " << 42 << ' ' << -7 << " uint " << 4000000000u << " long " << 1234567890123LL << " bool " << true << std::boolalpha << ' ' << false;
  std::printf("%s\n", os.str().c_str());
  os.str("");
  os << std::hex << 255 << ' ' << std::showbase << 255 << ' ' << std::oct << 8 << ' ' << std::dec << 99;
  std::printf("%s\n", os.str().c_str());
  os.str("");
  os << std::setw(8) << std::setfill('*') << 123 << '|' << std::left << std::setw(6) << 45 << '|' << std::right << std::setw(6) << "ab" << '|';
  std::printf("%s\n", os.str().c_str());
  os.str("");
  os << std::fixed << std::setprecision(3) << 3.14159265 << ' ' << std::scientific << std::setprecision(2) << 12345.678 << ' ' << std::defaultfloat << 0.1 << ' ' << 1e20 << ' ' << 2.5f;
  std::printf("%s\n", os.str().c_str());
  os.str("");
  os << "ptr " << (const void *)nullptr << " char " << 'x' << " string " << std::string("s") << " cstr " << "lit";
  std::printf("%s\n", os.str().c_str());

  std::istringstream is("12 3.5 word 0x1f -9 tail of line\nsecond line\n");
  int a;
  double b;
  std::string w;
  is >> a >> b >> w;
  std::printf("parsed %d %g %s\n", a, b, w.c_str());
  int h;
  is >> std::hex >> h >> std::dec;
  int neg;
  is >> neg;
  std::printf("hex %d neg %d\n", h, neg);
  std::string rest;
  std::getline(is, rest);
  std::printf("rest '%s'\n", rest.c_str());
  std::getline(is, rest);
  std::printf("line2 '%s' eof %d\n", rest.c_str(), (int)is.eof());
  std::getline(is, rest);
  std::printf("after eof fail %d\n", (int)is.fail());

  std::stringstream ss;
  for (int i = 0; i < 5; i++) ss << i * i << ',';
  std::string tok;
  int total = 0;
  while (std::getline(ss, tok, ',')) total += std::stoi(tok);
  std::printf("stringstream total %d\n", total);

  std::printf("to_string %s %s %s %s\n", std::to_string(-12).c_str(), std::to_string(3000000000u).c_str(),
              std::to_string(1.5).c_str(), std::to_string(77LL).c_str());
  std::printf("stoi %d stol %ld stod %g stoul %lu\n", std::stoi("  -42abc"), std::stol("123456789012"), std::stod("2.5e3"), std::stoul("ff", nullptr, 16));

  std::string s = "The quick brown fox";
  std::printf("find %zu %zu rfind %zu substr '%s' npos %d\n", s.find("quick"), s.find('z'), s.rfind('o'), s.substr(4, 5).c_str(), (int)(s.find("zzz") == std::string::npos));
  s.insert(3, "!!");
  s.replace(s.find("brown"), 5, "red");
  s.append(" jumps").push_back('.');
  std::printf("edited '%s' size %zu cmp %d\n", s.c_str(), s.size(), s.compare("The"));
  std::string big(300, 'q');
  big += big;
  std::printf("big %zu cap>=%d\n", big.size(), (int)(big.capacity() >= 600));
  std::vector<std::string> parts;
  std::istringstream split("a b  c   d");
  for (std::string p; split >> p;) parts.push_back(p);
  std::printf("split %zu '%s'\n", parts.size(), parts[3].c_str());

  std::cout << "cout " << 1 << ' ' << 2.5 << ' ' << std::hex << 255 << std::dec << std::endl;
  std::cout << std::setw(5) << std::setfill('0') << 42 << '\n';
  std::cerr << "to stderr\n";
  std::cout << std::flush;
  return 0;
}
