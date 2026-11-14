#include <cstdio>

// element-wise over arrays: the vectorizer's shape
void add(float *a, const float *b, const float *c, int n) {
	for (int i = 0; i < n; i++)
		a[i] = b[i] + c[i];
}

void scale(double *a, const double *b, int n) {
	for (int i = 0; i < n; i++)
		a[i] = b[i] * 2.5 + 1.0;
}

int main() {
	float a[40], b[40], c[40];
	double x[40], y[40];
	int bad = 0;
	for (int n = 0; n <= 37; n++) {
		for (int i = 0; i < 40; i++) {
			a[i] = -1; b[i] = i * 1.5f; c[i] = i * 0.25f;
			x[i] = -1; y[i] = i * 0.5;
		}
		add(a, b, c, n);
		scale(x, y, n);
		for (int i = 0; i < 40; i++) {
			if (a[i] != (i < n ? b[i] + c[i] : -1.0f)) bad++;
			if (x[i] != (i < n ? y[i] * 2.5 + 1.0 : -1.0)) bad++;
		}
	}
	std::printf("bad=%d\n", bad);
	return bad != 0;
}
