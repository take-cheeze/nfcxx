// EXPECT: 42
// Float negation (lowered specially for the QBE backend), switch, loops.
double neg(double x){ return -x; }
float  negf(float x){ return -x; }
int classify(int k){ switch(k){ case 0: return 1; case 1: return 2; case 5: return 10; default: return 100; } }
int main(){
  int s = 0;
  for (int i = 0; i < 4; ++i) s += classify(i == 3 ? 5 : i);   // 1+2+100+10
  double d = neg(2.5) + 2.5;               // +0.0
  bool signbit_ok = 1.0/neg(0.0) < 0;      // -0.0 keeps its sign
  return (s == 113 && d == 0.0 && negf(1.5f) == -1.5f && signbit_ok) ? 42 : 1;
}
