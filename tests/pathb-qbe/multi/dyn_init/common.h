// Shared by a.cpp and b.cpp: a class with a constructor that counts, an inline variable with a dynamic
// initializer (one object and one construction for the whole program) and an inline function with a
// function-local static (one guard and one construction).
struct Counted {
  Counted(int w);
  ~Counted();
  int weight;
};
extern int constructed;     // sum of the weights of the constructed objects
extern int destroyed;
inline Counted shared_inline(100);   // constructed once, by whichever unit's initialization runs first
inline int local_static_user()
{
  static Counted once(10000);          // constructed on the first call, from either unit
  return once.weight;
}
