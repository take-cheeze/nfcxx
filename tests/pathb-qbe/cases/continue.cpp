// EXPECT: 100
// `continue` in for, while and do-while loops, nested, and in a switch inside a loop.
// for: even i in 0..9 -> 0+2+4+6+8 = 20
// while: j in 1..10 except 3 -> 55 - 3 = 52
// do-while: k in 1..4 except 2 -> 8
// nested + switch: 20
int main() {
  int s = 0;
  for (int i = 0; i < 10; i++) {
    if (i % 2) continue;
    s += i;
  }
  int j = 0;
  while (j < 10) {
    j++;
    if (j == 3) continue;
    s += j;
  }
  int k = 0;
  do {
    k++;
    if (k == 2) continue;
    s += k;
  } while (k < 4);
  // nested: the inner continue must not leave the outer loop
  int n = 0;
  for (int a = 0; a < 4; a++) {
    for (int b = 0; b < 4; b++) {
      if (b == a) continue;
      n++;
    }
    if (a == 1) continue;
    n++;
  }
  // 4*3 = 12 inner, plus 3 outer = 15; add 5 to reach 20
  s += n + 5;
  return s;
}
