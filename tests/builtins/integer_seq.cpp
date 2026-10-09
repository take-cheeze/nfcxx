// EXPECT: 0
// DIALECT: clang
// __make_integer_seq and __type_pack_element (the builtins libc++/libstdc++ use for index_sequence).
template <typename T, T... Is> struct seq { static const int size = sizeof...(Is); };
template <typename T, T N> using make_seq = __make_integer_seq<seq, T, N>;

template <int... Is> struct Sum { static const int value = (0 + ... + Is); };

template <typename Seq> struct Expand;
template <typename T, T... Is> struct Expand<seq<T, Is...>> {
  static const int value = (0 + ... + (int)Is);
};

template <typename... Ts> using First = __type_pack_element<0, Ts...>;
template <typename... Ts> using Last = __type_pack_element<sizeof...(Ts) - 1, Ts...>;

template <typename A, typename B> struct Same { static const bool value = false; };
template <typename A> struct Same<A, A> { static const bool value = true; };

int main() {
  int fails = 0;
  fails += make_seq<int, 5>::size != 5;
  fails += Expand<make_seq<int, 5>>::value != 10;   // 0+1+2+3+4
  fails += Expand<make_seq<unsigned, 0>>::value != 0;
  fails += !Same<First<char, int, long>, char>::value;
  fails += !Same<Last<char, int, long>, long>::value;
  fails += !Same<__type_pack_element<1, char, int, long>, int>::value;
  return fails;
}
