// nfcast: the lexer and the recursive-descent parser. The parser resolves names while it parses (a local is a frame slot, a
// captured local is boxed in a Cell, anything else is a global) and builds the AST with the node factories.
#include <cctype>
#include <cstdio>

#include "nfcast_impl.hpp"

namespace nfcast {

namespace {

enum Tok {
  // single characters stand for themselves; the rest start above 256
  TK_AND = 257, TK_BREAK, TK_DO, TK_ELSE, TK_ELSEIF, TK_END, TK_FALSE, TK_FOR, TK_FUNCTION, TK_GOTO, TK_IF, TK_IN, TK_LOCAL,
  TK_NIL, TK_NOT, TK_OR, TK_REPEAT, TK_RETURN, TK_THEN, TK_TRUE, TK_UNTIL, TK_WHILE,
  TK_IDIV, TK_CONCAT, TK_DOTS, TK_EQ, TK_GE, TK_LE, TK_NE, TK_SHL, TK_SHR, TK_DBCOLON, TK_EOS,
  TK_FLT, TK_INT, TK_NAME, TK_STRING
};

const char* const kTokNames[] = {"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
                                 "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "//",
                                 "..", "...", "==", ">=", "<=", "~=", "<<", ">>", "::", "<eof>", "<number>", "<integer>",
                                 "<name>", "<string>"};

struct ParseError {
  std::string msg;
};

struct Token {
  int type = TK_EOS;
  std::string text;  // names, strings
  Value num;         // numbers
  int line = 1;
};

const int kMaxLevels = 200;

class Lexer {
 public:
  Lexer(std::string_view src, const std::string& chunk) : s_(src), chunk_(chunk) {}

  int line = 1;
  int lastline = 1;
  Token t, ahead;
  bool has_ahead = false;

  void next() {
    lastline = line;
    if (has_ahead) {
      t = ahead;
      has_ahead = false;
    } else {
      lex(t);
    }
  }
  const Token& peek() {
    if (!has_ahead) {
      lex(ahead);
      has_ahead = true;
    }
    return ahead;
  }

  [[noreturn]] void error(const std::string& msg, int tok) {
    std::string m = chunk_ + ":" + std::to_string(line) + ": " + msg;
    if (tok) m += " near " + token_text(tok);
    throw ParseError{m};
  }
  std::string token_text(int tok) const {
    if (tok == TK_NAME || tok == TK_STRING || tok == TK_FLT || tok == TK_INT) return "'" + (buf_for_error_.empty() ? t.text : buf_for_error_) + "'";
    if (tok == TK_EOS) return "<eof>";
    return "'" + tok2str(tok) + "'";
  }
  static std::string tok2str(int tok) {
    if (tok < 257) {
      if (std::isprint(tok)) return std::string(1, static_cast<char>(tok));
      char b[32];
      std::snprintf(b, sizeof b, "<\\%d>", tok);
      return b;
    }
    return kTokNames[tok - 257];
  }

 private:
  std::string_view s_;
  std::string chunk_;
  std::size_t pos_ = 0;
  std::string buf_for_error_;

  int cur() const { return pos_ < s_.size() ? static_cast<unsigned char>(s_[pos_]) : -1; }
  int at(std::size_t k) const { return pos_ + k < s_.size() ? static_cast<unsigned char>(s_[pos_ + k]) : -1; }

  void newline() {
    int old = cur();
    ++pos_;
    int c = cur();
    if ((c == '\n' || c == '\r') && c != old) ++pos_;  // \r\n or \n\r is one line break
    ++line;
  }

  void lex(Token& tok) {
    buf_for_error_.clear();
    tok.text.clear();
    for (;;) {
      int c = cur();
      switch (c) {
        case -1: tok.type = TK_EOS; tok.line = line; return;
        case '\n':
        case '\r': newline(); continue;
        case ' ':
        case '\f':
        case '\t':
        case '\v': ++pos_; continue;
        case '-':
          if (at(1) != '-') {
            ++pos_;
            tok.type = '-';
            tok.line = line;
            return;
          }
          pos_ += 2;
          if (cur() == '[') {
            std::size_t save = pos_;
            int sep = long_sep();
            if (sep >= 2) {
              std::string dummy;
              read_long(dummy, sep, "comment");
              continue;
            }
            pos_ = save;
          }
          while (cur() != -1 && cur() != '\n' && cur() != '\r') ++pos_;
          continue;
        case '[': {
          std::size_t save = pos_;
          int sep = long_sep();
          if (sep >= 2) {
            tok.line = line;
            read_long(tok.text, sep, "string");
            tok.type = TK_STRING;
            return;
          }
          pos_ = save + 1;
          if (sep == 0) error("invalid long string delimiter", TK_STRING);
          tok.type = '[';
          tok.line = line;
          return;
        }
        case '=': return two('=', TK_EQ, '=', tok);
        case '<':
          ++pos_;
          tok.line = line;
          if (cur() == '=') {
            ++pos_;
            tok.type = TK_LE;
          } else if (cur() == '<') {
            ++pos_;
            tok.type = TK_SHL;
          } else {
            tok.type = '<';
          }
          return;
        case '>':
          ++pos_;
          tok.line = line;
          if (cur() == '=') {
            ++pos_;
            tok.type = TK_GE;
          } else if (cur() == '>') {
            ++pos_;
            tok.type = TK_SHR;
          } else {
            tok.type = '>';
          }
          return;
        case '/': return two('/', TK_IDIV, '/', tok);
        case '~': return two('=', TK_NE, '~', tok);
        case ':': return two(':', TK_DBCOLON, ':', tok);
        case '"':
        case '\'': read_string(c, tok); return;
        case '.':
          if (at(1) == '.') {
            tok.line = line;
            if (at(2) == '.') {
              pos_ += 3;
              tok.type = TK_DOTS;
            } else {
              pos_ += 2;
              tok.type = TK_CONCAT;
            }
            return;
          }
          if (!std::isdigit(at(1))) {
            ++pos_;
            tok.type = '.';
            tok.line = line;
            return;
          }
          read_numeral(tok);
          return;
        case '0': case '1': case '2': case '3': case '4': case '5': case '6': case '7': case '8': case '9':
          read_numeral(tok);
          return;
        default:
          if (std::isalpha(c) || c == '_') {
            std::size_t b = pos_;
            while (cur() != -1 && (std::isalnum(cur()) || cur() == '_')) ++pos_;
            tok.text.assign(s_.data() + b, pos_ - b);
            tok.line = line;
            tok.type = TK_NAME;
            for (int k = 0; k <= TK_WHILE - TK_AND; ++k)
              if (tok.text == kTokNames[k]) {
                tok.type = TK_AND + k;
                break;
              }
            return;
          }
          ++pos_;
          tok.type = c;
          tok.line = line;
          return;
      }
    }
  }

  void two(int second, int both, int single, Token& tok) {
    ++pos_;
    tok.line = line;
    if (cur() == second) {
      ++pos_;
      tok.type = both;
    } else {
      tok.type = single;
    }
  }

  // After a '[': the number of '=' if followed by another '[' (2 + count), 1 if it was just '[', 0 for "[=" without '['.
  int long_sep() {
    std::size_t save = pos_;
    ++pos_;  // the first '['
    std::size_t n = 0;
    while (cur() == '=') {
      ++pos_;
      ++n;
    }
    int r = cur() == '[' ? static_cast<int>(n) + 2 : (n == 0 ? 1 : 0);
    if (r < 2) pos_ = save;
    else ++pos_;  // the second '['
    return r;
  }

  void read_long(std::string& out, int sep, const char* what) {
    int count = sep - 2;
    int startline = line;
    if (cur() == '\n' || cur() == '\r') newline();  // the first newline is skipped
    for (;;) {
      int c = cur();
      if (c == -1) {
        std::string m = std::string("unfinished long ") + what + " (starting at line " + std::to_string(startline) + ")";
        error(m, TK_EOS);
      }
      if (c == ']') {
        std::size_t save = pos_;
        ++pos_;
        int n = 0;
        while (cur() == '=') {
          ++pos_;
          ++n;
        }
        if (cur() == ']' && n == count) {
          ++pos_;
          return;
        }
        pos_ = save + 1;
        out.push_back(']');
      } else if (c == '\n' || c == '\r') {
        out.push_back('\n');
        newline();
      } else {
        out.push_back(static_cast<char>(c));
        ++pos_;
      }
    }
  }

  static int hexval(int c) { return std::isdigit(c) ? c - '0' : (std::tolower(c) - 'a' + 10); }

  void utf8_encode(std::string& out, unsigned long x) {
    if (x < 0x80) {
      out.push_back(static_cast<char>(x));
      return;
    }
    char b[8];
    int n = 1;
    unsigned mfb = 0x3f;
    do {
      b[8 - (n++)] = static_cast<char>(0x80 | (x & 0x3f));
      x >>= 6;
      mfb >>= 1;
    } while (x > mfb);
    b[8 - n] = static_cast<char>((~mfb << 1) | x);
    out.append(b + 8 - n, static_cast<std::size_t>(n));
  }

  void read_string(int delim, Token& tok) {
    tok.line = line;
    tok.type = TK_STRING;
    ++pos_;
    std::string& out = tok.text;
    for (;;) {
      int c = cur();
      if (c == delim) {
        ++pos_;
        return;
      }
      switch (c) {
        case -1: buf_for_error_ = std::string(1, static_cast<char>(delim)) + out; error("unfinished string", TK_EOS);
        case '\n':
        case '\r': buf_for_error_ = std::string(1, static_cast<char>(delim)) + out; error("unfinished string", TK_STRING);
        case '\\': {
          ++pos_;
          int e = cur();
          switch (e) {
            case 'a': out.push_back('\a'); ++pos_; break;
            case 'b': out.push_back('\b'); ++pos_; break;
            case 'f': out.push_back('\f'); ++pos_; break;
            case 'n': out.push_back('\n'); ++pos_; break;
            case 'r': out.push_back('\r'); ++pos_; break;
            case 't': out.push_back('\t'); ++pos_; break;
            case 'v': out.push_back('\v'); ++pos_; break;
            case '\\': out.push_back('\\'); ++pos_; break;
            case '"': out.push_back('"'); ++pos_; break;
            case '\'': out.push_back('\''); ++pos_; break;
            case '\n':
            case '\r': out.push_back('\n'); newline(); break;
            case 'x': {
              ++pos_;
              int v = 0;
              for (int k = 0; k < 2; ++k) {
                if (!std::isxdigit(cur())) {
                  buf_for_error_ = "\\x";
                  error("hexadecimal digit expected", TK_STRING);
                }
                v = v * 16 + hexval(cur());
                ++pos_;
              }
              out.push_back(static_cast<char>(v));
              break;
            }
            case 'z': {
              ++pos_;
              while (cur() != -1 && std::isspace(cur())) {
                if (cur() == '\n' || cur() == '\r') newline();
                else ++pos_;
              }
              break;
            }
            case 'u': {
              ++pos_;
              if (cur() != '{') error("missing '{' in \\u{xxxx}", TK_STRING);
              ++pos_;
              unsigned long r = 0;
              if (!std::isxdigit(cur())) error("hexadecimal digit expected", TK_STRING);
              while (std::isxdigit(cur())) {
                r = r * 16 + static_cast<unsigned long>(hexval(cur()));
                if (r > 0x7FFFFFFFul) error("UTF-8 value too large", TK_STRING);
                ++pos_;
              }
              if (cur() != '}') error("missing '}' in \\u{xxxx}", TK_STRING);
              ++pos_;
              utf8_encode(out, r);
              break;
            }
            default: {
              if (!std::isdigit(e)) {
                buf_for_error_ = "\\" + std::string(1, static_cast<char>(e));
                error("invalid escape sequence", TK_STRING);
              }
              int v = 0;
              for (int k = 0; k < 3 && std::isdigit(cur()); ++k) {
                v = v * 10 + (cur() - '0');
                ++pos_;
              }
              if (v > 255) error("decimal escape too large", TK_STRING);
              out.push_back(static_cast<char>(v));
              break;
            }
          }
          break;
        }
        default: out.push_back(static_cast<char>(c)); ++pos_; break;
      }
    }
  }

  void read_numeral(Token& tok) {
    tok.line = line;
    std::size_t b = pos_;
    const char* expo = "Ee";
    if (cur() == '0' && (at(1) == 'x' || at(1) == 'X')) {
      expo = "Pp";
      pos_ += 2;
    }
    for (;;) {
      int c = cur();
      if (c != -1 && std::strchr(expo, c) && c != 0) {
        ++pos_;
        if (cur() == '+' || cur() == '-') ++pos_;
      } else if (c != -1 && (std::isxdigit(c) || c == '.')) {
        ++pos_;
      } else {
        break;
      }
    }
    if (cur() != -1 && (std::isalpha(cur()) || cur() == '_')) ++pos_;  // a letter right after a number is malformed
    std::string text(s_.data() + b, pos_ - b);
    Value v;
    if (!string_to_number(text, &v)) {
      buf_for_error_ = text;
      error("malformed number", TK_FLT);
    }
    tok.num = v;
    tok.text = text;
    tok.type = v.t == T_INT ? TK_INT : TK_FLT;
  }
};

// ---- the parser ---------------------------------------------------------------------------------------------------------------
struct FuncState {
  FuncState* parent = nullptr;
  Proto* proto = nullptr;
  std::vector<std::unique_ptr<VarInfo>> owned;
  std::vector<VarInfo*> actives;
  int nslots = 0;  // the next free slot
  int maxslots = 0;
  int loops = 0;
};

class Parser {
 public:
  Parser(State& S, std::string_view code, const std::string& chunk) : S_(S), lx_(code, chunk), chunk_(chunk) {}

  Proto* parse_main() {
    Proto* P = new Proto();
    P->chunk = chunk_;
    P->name = "main chunk";
    P->linedefined = 0;
    FuncState fs;
    fs.proto = P;
    P->vararg = true;
    fs_ = &fs;
    try {
      lx_.next();
      Node* body = block();
      if (lx_.t.type != TK_EOS) lx_.error("'<eof>' expected", lx_.t.type);
      finish_function(fs, body);
    } catch (...) {
      fs_ = nullptr;
      P->release();
      throw;
    }
    fs_ = nullptr;
    return P;
  }

 private:
  State& S_;
  Lexer lx_;
  std::string chunk_;
  FuncState* fs_ = nullptr;
  int levels_ = 0;

  Proto& P() { return *fs_->proto; }

  // ---- tokens ----
  bool test_next(int tok) {
    if (lx_.t.type == tok) {
      lx_.next();
      return true;
    }
    return false;
  }
  void check(int tok) {
    if (lx_.t.type != tok) lx_.error("'" + Lexer::tok2str(tok) + "' expected", lx_.t.type);
  }
  void check_next(int tok) {
    check(tok);
    lx_.next();
  }
  void check_match(int what, int who, int where) {
    if (!test_next(what)) {
      if (where == lx_.t.line) {
        lx_.error("'" + Lexer::tok2str(what) + "' expected", lx_.t.type);
      } else {
        lx_.error("'" + Lexer::tok2str(what) + "' expected (to close '" + Lexer::tok2str(who) + "' at line " + std::to_string(where) + ")",
                  lx_.t.type);
      }
    }
  }
  std::string check_name() {
    check(TK_NAME);
    std::string n = lx_.t.text;
    lx_.next();
    return n;
  }
  struct Level {
    Parser& p;
    explicit Level(Parser& pp) : p(pp) {
      if (++p.levels_ > kMaxLevels) p.lx_.error("chunk has too many syntax levels", 0);
    }
    ~Level() { --p.levels_; }
  };

  String* intern(const std::string& s) {
    String* r = S_.str(s);
    P().consts.push_back(r);
    return r;
  }

  // ---- scopes and names ----
  VarInfo* new_local(const std::string& name) {
    FuncState& fs = *fs_;
    auto vi = std::make_unique<VarInfo>();
    vi->name = name;
    vi->slot = fs.nslots++;
    if (fs.nslots > fs.maxslots) fs.maxslots = fs.nslots;
    VarInfo* r = vi.get();
    fs.owned.push_back(std::move(vi));
    return r;
  }
  void activate(VarInfo* v) { fs_->actives.push_back(v); }
  VarInfo* find_local(FuncState& fs, const std::string& name) {
    for (std::size_t i = fs.actives.size(); i > 0; --i)
      if (fs.actives[i - 1]->name == name) return fs.actives[i - 1];
    return nullptr;
  }
  int find_upvalue(FuncState& fs, const std::string& name) {
    for (std::size_t i = 0; i < fs.proto->upvals.size(); ++i)
      if (fs.proto->upvals[i].name == name) return static_cast<int>(i);
    if (!fs.parent) return -1;
    VarInfo* v = find_local(*fs.parent, name);
    UpvalDesc d;
    d.name = name;
    if (v) {
      v->captured = true;
      d.from_local = true;
      d.index = static_cast<std::uint32_t>(v->slot);
      d.is_const = v->is_const;
    } else {
      int pi = find_upvalue(*fs.parent, name);
      if (pi < 0) return -1;
      d.from_local = false;
      d.index = static_cast<std::uint32_t>(pi);
      d.is_const = fs.parent->proto->upvals[static_cast<std::size_t>(pi)].is_const;
    }
    fs.proto->upvals.push_back(d);
    return static_cast<int>(fs.proto->upvals.size()) - 1;
  }

  struct Scope {
    std::size_t nactives;
    int nslots;
  };
  Scope enter_scope() { return Scope{fs_->actives.size(), fs_->nslots}; }
  void leave_scope(const Scope& s) {
    fs_->actives.resize(s.nactives);
    fs_->nslots = s.nslots;
  }

  Node* var_node(const std::string& name, int line) {
    if (VarInfo* v = find_local(*fs_, name)) {
      if (v->is_const) {
        // reading a constant is fine; assignment is checked where it happens
      }
      return n_local(P(), line, v);
    }
    int up = find_upvalue(*fs_, name);
    if (up >= 0) return n_upval(P(), line, up, intern(name));
    return n_global(P(), line, intern(name));
  }

  // ---- statements ----
  bool block_follow(bool with_until) const {
    switch (lx_.t.type) {
      case TK_ELSE:
      case TK_ELSEIF:
      case TK_END:
      case TK_EOS: return true;
      case TK_UNTIL: return with_until;
      default: return false;
    }
  }

  Node* block() {
    Scope sc = enter_scope();
    int line = lx_.t.line;
    std::vector<Node*> stmts = statlist();
    leave_scope(sc);
    return n_block(P(), line, std::move(stmts));
  }

  std::vector<Node*> statlist() {
    std::vector<Node*> out;
    while (!block_follow(true)) {
      if (lx_.t.type == TK_RETURN) {
        out.push_back(retstat());
        break;
      }
      Node* s = statement();
      if (s) out.push_back(s);
    }
    return out;
  }

  Node* statement() {
    Level lv(*this);
    int line = lx_.t.line;
    switch (lx_.t.type) {
      case ';': lx_.next(); return nullptr;
      case TK_IF: return ifstat(line);
      case TK_WHILE: {
        lx_.next();
        Node* cond = expr();
        check_next(TK_DO);
        ++fs_->loops;
        Node* body = block();
        --fs_->loops;
        check_match(TK_END, TK_WHILE, line);
        return n_while(P(), line, cond, body);
      }
      case TK_DO: {
        lx_.next();
        Node* b = block();
        check_match(TK_END, TK_DO, line);
        return b;
      }
      case TK_FOR: return forstat(line);
      case TK_REPEAT: {
        lx_.next();
        Scope sc = enter_scope();  // the condition sees the body's locals
        ++fs_->loops;
        int bl = lx_.t.line;
        std::vector<Node*> stmts = statlist();
        --fs_->loops;
        Node* body = n_block(P(), bl, std::move(stmts));
        check_match(TK_UNTIL, TK_REPEAT, line);
        Node* cond = expr();
        leave_scope(sc);
        return n_repeat(P(), line, body, cond);
      }
      case TK_FUNCTION: return funcstat(line);
      case TK_LOCAL:
        lx_.next();
        if (test_next(TK_FUNCTION)) return localfunc(line);
        return localstat(line);
      case TK_DBCOLON: lx_.error("goto and labels are not supported", 0);
      case TK_RETURN: return retstat();
      case TK_BREAK:
        lx_.next();
        if (fs_->loops == 0) lx_.error("break outside a loop at line " + std::to_string(line), 0);
        return n_break(P(), line);
      case TK_GOTO: lx_.error("goto and labels are not supported", 0);
      default: return exprstat(line);
    }
  }

  Node* ifstat(int line) {
    std::vector<Node*> conds, blocks;
    Node* els = nullptr;
    while (lx_.t.type == TK_IF || lx_.t.type == TK_ELSEIF) {
      lx_.next();
      conds.push_back(expr());
      check_next(TK_THEN);
      blocks.push_back(block());
    }
    if (test_next(TK_ELSE)) els = block();
    check_match(TK_END, TK_IF, line);
    return n_if(P(), line, std::move(conds), std::move(blocks), els);
  }

  Node* forstat(int line) {
    lx_.next();
    std::string n1 = check_name();
    if (lx_.t.type == '=') {
      lx_.next();
      Node* start = expr();
      check_next(',');
      Node* limit = expr();
      Node* step = nullptr;
      if (test_next(',')) step = expr();
      check_next(TK_DO);
      Scope sc = enter_scope();
      VarInfo* v = new_local(n1);
      activate(v);
      ++fs_->loops;
      Node* body = block();
      --fs_->loops;
      leave_scope(sc);
      check_match(TK_END, TK_FOR, line);
      return n_fornum(P(), line, v, start, limit, step, body);
    }
    if (lx_.t.type != ',' && lx_.t.type != TK_IN) lx_.error("'=' or 'in' expected", lx_.t.type);
    std::vector<std::string> names{n1};
    while (test_next(',')) names.push_back(check_name());
    check_next(TK_IN);
    std::vector<Node*> exprs = explist();
    check_next(TK_DO);
    Scope sc = enter_scope();
    int hidden = fs_->nslots;  // three slots for the iterator function, the state and the control variable
    for (int k = 0; k < 3; ++k) {
      VarInfo* h = new_local("(for state)");
      activate(h);
    }
    std::vector<VarInfo*> vars;
    for (const std::string& n : names) vars.push_back(new_local(n));
    for (VarInfo* v : vars) activate(v);
    ++fs_->loops;
    Node* body = block();
    --fs_->loops;
    leave_scope(sc);
    check_match(TK_END, TK_FOR, line);
    return n_forin(P(), line, std::move(vars), std::move(exprs), hidden, body);
  }

  Node* funcstat(int line) {
    lx_.next();  // 'function'
    int nline = lx_.t.line;
    std::string name = check_name();
    std::string full = name;
    Node* target = var_node(name, nline);
    bool method = false;
    std::string last = name;
    while (lx_.t.type == '.' || lx_.t.type == ':') {
      bool colon = lx_.t.type == ':';
      lx_.next();
      std::string key = check_name();
      full += (colon ? ":" : ".") + key;
      last = key;
      target = n_index(P(), nline, target, n_const(P(), nline, Value::str(intern(key))));
      if (colon) {
        method = true;
        break;
      }
    }
    Node* fn = body(method, line, method ? "method '" + last + "'" : "function '" + full + "'");
    return n_assign(P(), line, std::vector<Node*>{target}, std::vector<Node*>{fn});
  }

  Node* localfunc(int line) {
    std::string name = check_name();
    VarInfo* v = new_local(name);
    activate(v);  // visible inside its own body, for recursion
    Node* fn = body(false, line, "local '" + name + "'");
    return n_localfunc(P(), line, v, fn);
  }

  Node* localstat(int line) {
    std::vector<std::string> names;
    std::vector<int> attribs;
    do {
      names.push_back(check_name());
      int attrib = 0;
      if (test_next('<')) {
        std::string a = check_name();
        if (a == "const") attrib = 1;
        else if (a == "close") lx_.error("to-be-closed variables are not supported", 0);
        else lx_.error("unknown attribute '" + a + "'", 0);
        check_next('>');
      }
      attribs.push_back(attrib);
    } while (test_next(','));
    std::vector<Node*> exprs;
    if (test_next('=')) exprs = explist();
    std::vector<VarInfo*> vars;
    for (std::size_t i = 0; i < names.size(); ++i) {
      VarInfo* v = new_local(names[i]);
      v->is_const = attribs[i] == 1;
      vars.push_back(v);
    }
    for (VarInfo* v : vars) activate(v);
    return n_localdecl(P(), line, std::move(vars), std::move(exprs));
  }

  Node* retstat() {
    int line = lx_.t.line;
    lx_.next();  // 'return'
    std::vector<Node*> exprs;
    if (!block_follow(true) && lx_.t.type != ';') exprs = explist();
    test_next(';');
    return n_return(P(), line, std::move(exprs));
  }

  bool assignable(Node* n) {
    // locals, upvalues, globals and indexed expressions are assignable; the factories tell them apart
    return n->target_kind() != 0;
  }

  void check_const_assign(Node* n) {
    if (n->target_kind() == 1) {
      VarInfo* v = n->target_var();
      if (v && v->is_const) lx_.error("attempt to assign to const variable '" + v->name + "'", 0);
    } else if (n->target_kind() == 2) {
      int idx = n->upval_index();
      if (idx >= 0 && fs_->proto->upvals[static_cast<std::size_t>(idx)].is_const)
        lx_.error("attempt to assign to const variable '" + fs_->proto->upvals[static_cast<std::size_t>(idx)].name + "'", 0);
    }
  }

  Node* exprstat(int line) {
    Node* first = suffixedexp();
    if (lx_.t.type == '=' || lx_.t.type == ',') {
      std::vector<Node*> targets{first};
      while (test_next(',')) targets.push_back(suffixedexp());
      for (Node* t : targets) {
        if (!assignable(t)) lx_.error("syntax error", lx_.t.type);
        check_const_assign(t);
      }
      check_next('=');
      std::vector<Node*> exprs = explist();
      return n_assign(P(), line, std::move(targets), std::move(exprs));
    }
    if (!first->is_call()) lx_.error("syntax error", lx_.t.type);
    return n_callstat(P(), line, first);
  }

  // ---- expressions ----
  std::vector<Node*> explist() {
    std::vector<Node*> out;
    out.push_back(expr());
    while (test_next(',')) out.push_back(expr());
    return out;
  }

  Node* primaryexp() {
    int line = lx_.t.line;
    switch (lx_.t.type) {
      case TK_NAME: {
        std::string n = lx_.t.text;
        lx_.next();
        return var_node(n, line);
      }
      case '(': {
        lx_.next();
        Node* e = expr();
        check_match(')', '(', line);
        return n_paren(P(), line, e);
      }
      default: lx_.error("unexpected symbol", lx_.t.type);
    }
  }

  Node* suffixedexp() {
    Node* e = primaryexp();
    for (;;) {
      int line = lx_.t.line;
      switch (lx_.t.type) {
        case '.': {
          lx_.next();
          std::string key = check_name();
          e = n_index(P(), line, e, n_const(P(), line, Value::str(intern(key))));
          break;
        }
        case '[': {
          lx_.next();
          Node* k = expr();
          check_next(']');
          e = n_index(P(), line, e, k);
          break;
        }
        case ':': {
          lx_.next();
          std::string name = check_name();
          int aline = lx_.t.line;
          std::vector<Node*> args = callargs();
          e = n_method(P(), aline, e, intern(name), std::move(args));
          break;
        }
        case '(':
        case TK_STRING:
        case '{': {
          std::vector<Node*> args = callargs();
          e = n_call(P(), line, e, std::move(args));
          break;
        }
        default: return e;
      }
    }
  }

  std::vector<Node*> callargs() {
    std::vector<Node*> args;
    int line = lx_.t.line;
    switch (lx_.t.type) {
      case '(': {
        lx_.next();
        if (lx_.t.type != ')') args = explist();
        check_match(')', '(', line);
        break;
      }
      case '{': args.push_back(tablecons()); break;
      case TK_STRING: {
        std::string s = lx_.t.text;
        lx_.next();
        args.push_back(n_const(P(), line, Value::str(intern(s))));
        break;
      }
      default: lx_.error("function arguments expected", lx_.t.type);
    }
    return args;
  }

  Node* tablecons() {
    int line = lx_.t.line;
    check_next('{');
    std::vector<TableItem> items;
    while (lx_.t.type != '}') {
      TableItem it{nullptr, nullptr};
      if (lx_.t.type == TK_NAME && lx_.peek().type == '=') {
        int kl = lx_.t.line;
        std::string key = lx_.t.text;
        lx_.next();
        lx_.next();  // '='
        it.key = n_const(P(), kl, Value::str(intern(key)));
        it.val = expr();
      } else if (lx_.t.type == '[') {
        lx_.next();
        it.key = expr();
        check_next(']');
        check_next('=');
        it.val = expr();
      } else {
        it.val = expr();
      }
      items.push_back(it);
      if (!test_next(',') && !test_next(';')) break;
    }
    check_match('}', '{', line);
    return n_table(P(), line, std::move(items));
  }

  Node* simpleexp() {
    int line = lx_.t.line;
    switch (lx_.t.type) {
      case TK_FLT:
      case TK_INT: {
        Value v = lx_.t.num;
        lx_.next();
        return n_const(P(), line, v);
      }
      case TK_STRING: {
        std::string s = lx_.t.text;
        lx_.next();
        return n_const(P(), line, Value::str(intern(s)));
      }
      case TK_NIL: lx_.next(); return n_const(P(), line, Value());
      case TK_TRUE: lx_.next(); return n_const(P(), line, Value::boolean(true));
      case TK_FALSE: lx_.next(); return n_const(P(), line, Value::boolean(false));
      case TK_DOTS:
        if (!fs_->proto->vararg) lx_.error("cannot use '...' outside a vararg function", TK_DOTS);
        lx_.next();
        return n_vararg(P(), line);
      case '{': return tablecons();
      case TK_FUNCTION:
        lx_.next();
        return body(false, line, "function <" + chunk_ + ":" + std::to_string(line) + ">");
      default: return suffixedexp();
    }
  }

  // Binary operator priorities: left, right.
  struct Prio {
    int left, right;
  };
  static bool binop_prio(int tok, Prio* p, int* op) {
    switch (tok) {
      case '+': *p = {10, 10}; *op = AR_ADD; return true;
      case '-': *p = {10, 10}; *op = AR_SUB; return true;
      case '*': *p = {11, 11}; *op = AR_MUL; return true;
      case '%': *p = {11, 11}; *op = AR_MOD; return true;
      case '^': *p = {14, 13}; *op = AR_POW; return true;
      case '/': *p = {11, 11}; *op = AR_DIV; return true;
      case TK_IDIV: *p = {11, 11}; *op = AR_IDIV; return true;
      case '&': *p = {6, 6}; *op = AR_BAND; return true;
      case '|': *p = {4, 4}; *op = AR_BOR; return true;
      case '~': *p = {5, 5}; *op = AR_BXOR; return true;
      case TK_SHL: *p = {7, 7}; *op = AR_SHL; return true;
      case TK_SHR: *p = {7, 7}; *op = AR_SHR; return true;
      case TK_CONCAT: *p = {9, 8}; *op = 200; return true;
      case TK_EQ: *p = {3, 3}; *op = 300 + CMP_EQ; return true;
      case TK_NE: *p = {3, 3}; *op = 300 + CMP_NE; return true;
      case '<': *p = {3, 3}; *op = 300 + CMP_LT; return true;
      case TK_LE: *p = {3, 3}; *op = 300 + CMP_LE; return true;
      case '>': *p = {3, 3}; *op = 300 + CMP_GT; return true;
      case TK_GE: *p = {3, 3}; *op = 300 + CMP_GE; return true;
      case TK_AND: *p = {2, 2}; *op = 400; return true;
      case TK_OR: *p = {1, 1}; *op = 401; return true;
      default: return false;
    }
  }
  static const int kUnaryPrio = 12;

  Node* expr() { return subexpr(0); }

  Node* subexpr(int limit) {
    Level lv(*this);
    Node* left;
    int line = lx_.t.line;
    int ut = lx_.t.type;
    if (ut == TK_NOT || ut == '-' || ut == '~' || ut == '#') {
      lx_.next();
      Node* operand = subexpr(kUnaryPrio);
      left = make_unary(ut, operand, line);
    } else {
      left = simpleexp();
    }
    Prio pr;
    int op;
    while (binop_prio(lx_.t.type, &pr, &op) && pr.left > limit) {
      int oline = lx_.t.line;
      lx_.next();
      Node* right = subexpr(pr.right);
      left = make_binary(op, left, right, oline);
    }
    return left;
  }

  Node* make_unary(int tok, Node* operand, int line) {
    Value v, folded;
    if (tok == '-') {
      if (operand->const_number(&v) && fold_arith(AR_UNM, v, v, &folded)) return n_const(P(), line, folded);
      return n_unary(P(), line, AR_UNM, operand);
    }
    if (tok == '~') {
      if (operand->const_number(&v) && fold_arith(AR_BNOT, v, v, &folded)) return n_const(P(), line, folded);
      return n_unary(P(), line, AR_BNOT, operand);
    }
    if (tok == '#') return n_unary(P(), line, OPX_LEN, operand);
    if (operand->node_kind() == 1) return n_const(P(), line, Value::boolean(operand->expkind() == 2));  // not <constant>
    return n_unary(P(), line, OPX_NOT, operand);
  }

  Node* make_binary(int op, Node* l, Node* r, int line) {
    if (op == 400) return n_and(P(), line, l, r);
    if (op == 401) return n_or(P(), line, l, r);
    if (op == 200) {  // a .. b .. c is one concatenation of three operands (right associative)
      std::vector<Node*> parts;
      parts.push_back(l);
      if (r->concat_parts(&parts)) {
      } else {
        parts.push_back(r);
      }
      return n_concat(P(), line, std::move(parts));
    }
    if (op >= 300) return n_compare(P(), line, op - 300, l, r);
    Value a, b, folded;
    if (l->const_number(&a) && r->const_number(&b) && fold_arith(op, a, b, &folded)) return n_const(P(), line, folded);
    return n_arith(P(), line, op, l, r);
  }

  // ---- functions ----
  Node* body(bool is_method, int line, const std::string& name) {
    FuncState fs;
    fs.parent = fs_;
    Proto* child = new Proto();
    child->chunk = chunk_;
    child->name = name;
    child->linedefined = line;
    fs.proto = child;
    fs_->proto->children.push_back(child);  // owned by the parent from here on
    fs_ = &fs;
    std::vector<VarInfo*> params;
    try {
      if (is_method) {
        VarInfo* s = new_local("self");
        activate(s);
        params.push_back(s);
      }
      check_next('(');
      if (lx_.t.type != ')') {
        do {
          if (lx_.t.type == TK_NAME) {
            VarInfo* v = new_local(check_name());
            activate(v);
            params.push_back(v);
          } else if (lx_.t.type == TK_DOTS) {
            lx_.next();
            child->vararg = true;
            break;
          } else {
            lx_.error("<name> or '...' expected", lx_.t.type);
          }
        } while (test_next(','));
      }
      check_next(')');
      child->nparams = static_cast<int>(params.size());
      std::vector<Node*> stmts;
      int bl = lx_.t.line;
      stmts = statlist();
      Node* bodynode = n_block(*child, bl, std::move(stmts));
      check_match(TK_END, TK_FUNCTION, line);
      for (VarInfo* p : params) (void)p;
      finish_function(fs, bodynode);
      for (VarInfo* p : params)
        if (p->captured) child->captured_params.push_back(p->slot);
    } catch (...) {
      fs_ = fs.parent;
      throw;
    }
    fs_ = fs.parent;
    return n_function(P(), line, child);
  }

  void finish_function(FuncState& fs, Node* bodynode) {
    Proto* p = fs.proto;
    p->body = bodynode;
    p->nslots = fs.maxslots;
    for (Node* n : p->patchables) n->patch();
    p->patchables.clear();
  }
};

}  // namespace

Proto* parse_chunk(State& S, std::string_view code, const std::string& chunkname, std::string* err) {
  try {
    Parser p(S, code, chunkname);
    return p.parse_main();
  } catch (const ParseError& e) {
    if (err) *err = e.msg;
    return nullptr;
  }
}

}  // namespace nfcast
