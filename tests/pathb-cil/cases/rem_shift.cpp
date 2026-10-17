// EXPECT: 5
// Path B CIL spike: crem (the remainder takes the sign of the dividend) and checked shifts (cshl, cshr) with
// variable counts. rem(17,5)=2, (3u<<4)>>2=12, -64>>3=-8, rem(-7,3)=-1: 2+12-8-1.
static int rem(int a, int b) { return a % b; }
static unsigned shl(unsigned x, int n) { return x << n; }
static int shr(int x, int n) { return x >> n; }
int main(void) { return rem(17, 5) + (int)(shl(3u, 4) >> 2) + shr(-64, 3) + rem(-7, 3); }
