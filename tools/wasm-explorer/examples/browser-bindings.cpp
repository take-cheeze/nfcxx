// The browser bindings: each function below is an import (module env) that the page connects to a browser feature.
// The page's Console tab shows what the module logs. Run returns 3 whatever the timer and random values are.
extern "C" {
void log_i32(int value);
void log_i64(long long value);
void log_f64(double value);
void log_str(const char* s, long length);
double now_ms();
double random_f64();
void set_title(const char* s, long length);
}

static const char message[] = "hello from wasm";

int main() {
  log_str(message, sizeof(message) - 1);
  log_i32(42);
  log_i64(1LL << 40);
  log_f64(2.5);
  set_title("wasm explorer demo", 18);
  double t = now_ms();
  double r = random_f64();
  log_i32(t >= 0.0 && r < 1.0 ? 1 : 0);
  return 3;
}
