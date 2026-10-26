// __int128 passed and returned by value: a (byval) argument and an (init) result buffer, over the runtime helpers.
__int128 dbl(__int128 x) { return x + x; }
int main() {
  __int128 w = 3;
  __int128 y = dbl(w);
  return (int)y - 6;
}
