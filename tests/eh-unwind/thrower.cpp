extern "C" int thrower(int v) {
	if (v > 0)
		throw v;
	return v;
}
