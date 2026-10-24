// A plugin that names libA and libB in DT_NEEDED, as a ruby extension names libruby.so: loaded into a bundled
// program, it must use the program's copies (the stubs of --stubs), not load the real libraries again.
int b_get(void);
void a_bump(void);
extern int a_counter;
int plugin_value(void) { a_bump(); return b_get() * 10 + a_counter; }
