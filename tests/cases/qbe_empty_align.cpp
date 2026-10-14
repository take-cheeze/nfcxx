// EXPECT: 0
// std::optional<long> is { storage, bool engaged }, and its storage is a union whose first alternative is an empty class
// (_Empty_byte). QBE gave an empty class no alignment (-1), so a struct made of an empty member and a bool got a size of 8 and
// its 16-byte return value (the optional) came back in RAX only: the engaged flag read whatever RDX held. A nullopt then looked
// engaged, and an optional whose value is set could look empty. Returns 0 when has_value is right on both paths
// (scripts/qbe-empty-align.patch, docs/notes/qbe-empty-align.md).
#include <optional>

__attribute__((noinline)) std::optional<long> maybe(bool s) {
  if (s) return std::nullopt;
  return 5;
}

int main() {
  int bad = 0;
  if (maybe(true).has_value()) bad |= 1;
  if (!maybe(false).has_value()) bad |= 2;
  if (maybe(false).value() != 5) bad |= 4;
  return bad;
}
