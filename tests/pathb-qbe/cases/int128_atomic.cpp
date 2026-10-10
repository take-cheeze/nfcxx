// std::atomic of a 128-bit integer (docs/notes/pathb-int128.md): the generic __atomic_* calls on 16 bytes go to libatomic
// (Path B links -latomic like the other programs). The gcc backend's own link line has no -latomic, so it cannot link this
// program (__atomic_load_16); the result is checked by the program itself instead.
// GCC: undefined
// EXPECT: 0
#include <atomic>

typedef __int128 i128;
typedef unsigned __int128 u128;

std::atomic<i128> ai(5);
std::atomic<u128> au(~(u128)0);

int main() {
  i128 t = ai.load();
  ai.store(ai.load() + 3);
  if (t != 5 || ai.load() != 8) return 1;
  i128 expected = 8;
  if (!ai.compare_exchange_strong(expected, -9) || ai.load() != -9) return 2;
  if (ai.exchange(4) != -9 || ai.load() != 4) return 3;
  if (au.load() != ~(u128)0) return 4;
  au.store((u128)1 << 127);
  if (au.load() != ((u128)1 << 127)) return 5;
  return 0;
}
