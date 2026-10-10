extern "C" {
int hook(int x) { return x + 99; }                // strong: replaces a.cpp's weak hook
int weak_val = 7;                                 // strong: replaces a.cpp's weak weak_val
int provided(int x) { return x * 2; }
int provided_val = 33;
}

int call_hook_in_b() { return hook(1); }
