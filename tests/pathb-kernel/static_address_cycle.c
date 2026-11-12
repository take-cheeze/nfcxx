// Two static objects that point at each other (the 8250 serial driver: `serial8250_reg.cons = &univ8250_console` and
// `univ8250_console.data = &serial8250_reg`). The emitter's data of a global names the data of every global it takes the
// address of, and a cycle of two was taken as "not emitted", so every function using either was refused
// (univ8250_console_init: global "univ8250_console").
struct console;
struct driver { int major; struct console *cons; };
struct console { char name[16]; int index; void *data; };

static struct driver reg;
static struct console con = { .name = "ttyS", .index = -1, .data = &reg };
static struct driver reg = { .major = 4, .cons = &con };

__attribute__((noinline)) static int init(void)
{
  struct driver *d = con.data;
  return d->major + d->cons->name[2] + (d->cons == &con) + (reg.cons->data == &reg) + con.index;
}

int main(void)
{
  return init() & 0x7f;
}
