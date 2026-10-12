/* EXPECT: 0
   __builtin_fabsf: the sign bit of a float is cleared, the value is unchanged otherwise. Exit status = failed checks. */
#define CHECK(c) do { if (!(c)) ++fails; } while (0)

static int fails;

union bits { float f; unsigned u; };

int main(void) {
	float a = -2.5f, z = -0.0f;
	union bits un;

	CHECK(__builtin_fabsf(a) == 2.5f);
	CHECK(__builtin_fabsf(2.5f) == 2.5f);
	CHECK(__builtin_fabsf(3) == 3.0f);
	CHECK(__builtin_fabsf(-1e-30) > 0);
	CHECK(1 / __builtin_fabsf(z) > 0);
	un.f = __builtin_fabsf(-7.0f);
	CHECK(un.u == 0x40e00000u);
	un.f = __builtin_fabsf(z);
	CHECK(un.u == 0u);
	return fails;
}
