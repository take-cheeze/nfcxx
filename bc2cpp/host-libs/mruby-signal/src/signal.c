/*
 * Signal.trap: the module that sets the disposition of a signal, on POSIX systems through sigaction.
 *
 * The commands that set a C-level disposition are "DEFAULT" (SIG_DFL), "SYSTEM_DEFAULT" (SIG_DFL too: mruby installs no
 * handler of its own, so the two are the same here), and "IGNORE" (SIG_IGN; "SIG_IGN", "SIG_DFL", nil and "" are accepted as
 * CRuby does). A handler that runs Ruby code (a proc, a block, or "EXIT") is NotImplementedError: mruby has no safe point at
 * which a signal can run Ruby code, and a handler run from the C signal context would corrupt the VM. Nothing here is
 * silently ignored.
 *
 * The previous handler is kept per signal in a Hash on the Signal module. A signal never set by Signal.trap reports its
 * disposition as the system has it: "DEFAULT" or "IGNORE", and nil for any other handler installed outside mruby.
 */
#include <mruby.h>
#include <mruby/hash.h>
#include <mruby/string.h>
#include <mruby/variable.h>
#include <mruby/class.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

#if !defined(_WIN32)
#include <signal.h>

#ifndef NSIG
#define NSIG 65
#endif

struct signame {
  const char *name;
  int num;
};

#define SIGNAME(s) { #s + 3, s }

static const struct signame signames[] = {
#ifdef SIGHUP
  SIGNAME(SIGHUP),
#endif
#ifdef SIGINT
  SIGNAME(SIGINT),
#endif
#ifdef SIGQUIT
  SIGNAME(SIGQUIT),
#endif
#ifdef SIGILL
  SIGNAME(SIGILL),
#endif
#ifdef SIGTRAP
  SIGNAME(SIGTRAP),
#endif
#ifdef SIGABRT
  SIGNAME(SIGABRT),
#endif
#ifdef SIGBUS
  SIGNAME(SIGBUS),
#endif
#ifdef SIGFPE
  SIGNAME(SIGFPE),
#endif
#ifdef SIGKILL
  SIGNAME(SIGKILL),
#endif
#ifdef SIGUSR1
  SIGNAME(SIGUSR1),
#endif
#ifdef SIGSEGV
  SIGNAME(SIGSEGV),
#endif
#ifdef SIGUSR2
  SIGNAME(SIGUSR2),
#endif
#ifdef SIGPIPE
  SIGNAME(SIGPIPE),
#endif
#ifdef SIGALRM
  SIGNAME(SIGALRM),
#endif
#ifdef SIGTERM
  SIGNAME(SIGTERM),
#endif
#ifdef SIGCHLD
  SIGNAME(SIGCHLD),
#endif
#ifdef SIGCONT
  SIGNAME(SIGCONT),
#endif
#ifdef SIGSTOP
  SIGNAME(SIGSTOP),
#endif
#ifdef SIGTSTP
  SIGNAME(SIGTSTP),
#endif
#ifdef SIGTTIN
  SIGNAME(SIGTTIN),
#endif
#ifdef SIGTTOU
  SIGNAME(SIGTTOU),
#endif
#ifdef SIGURG
  SIGNAME(SIGURG),
#endif
#ifdef SIGXCPU
  SIGNAME(SIGXCPU),
#endif
#ifdef SIGXFSZ
  SIGNAME(SIGXFSZ),
#endif
#ifdef SIGVTALRM
  SIGNAME(SIGVTALRM),
#endif
#ifdef SIGPROF
  SIGNAME(SIGPROF),
#endif
#ifdef SIGWINCH
  SIGNAME(SIGWINCH),
#endif
#ifdef SIGIO
  SIGNAME(SIGIO),
#endif
#ifdef SIGSYS
  SIGNAME(SIGSYS),
#endif
};

/* the signals CRuby does not let a program trap */
static int
reserved_signal_p(int signo)
{
  switch (signo) {
#ifdef SIGSEGV
    case SIGSEGV:
#endif
#ifdef SIGBUS
    case SIGBUS:
#endif
#ifdef SIGILL
    case SIGILL:
#endif
#ifdef SIGFPE
    case SIGFPE:
#endif
#ifdef SIGVTALRM
    case SIGVTALRM:
#endif
      return 1;
    default:
      return 0;
  }
}

/* the signal number of a name (with or without SIG, a String or a Symbol), or of an Integer; EXIT is signal 0 */
static int
signo_of(mrb_state *mrb, mrb_value sig, const char **namep)
{
  static char buf[64];
  const char *name;
  size_t i;

  if (mrb_fixnum_p(sig)) {
    mrb_int n = mrb_fixnum(sig);
    if (n < 0 || n >= NSIG) {
      mrb_raisef(mrb, E_ARGUMENT_ERROR, "invalid signal number (%v)", sig);
    }
    snprintf(buf, sizeof buf, "%d", (int)n);
    *namep = buf;
    return (int)n;
  }
  if (mrb_symbol_p(sig)) {
    name = mrb_sym_name(mrb, mrb_symbol(sig));
  }
  else if (mrb_string_p(sig)) {
    name = mrb_str_to_cstr(mrb, sig);
  }
  else {
    mrb_raise(mrb, E_ARGUMENT_ERROR, "bad signal type (expected a signal name or number)");
    return -1; /* not reached */
  }
  if (strncmp(name, "SIG", 3) == 0) name += 3;
  if (strcmp(name, "EXIT") == 0) {
    *namep = "EXIT";
    return 0;
  }
  for (i = 0; i < sizeof(signames) / sizeof(signames[0]); i++) {
    if (strcmp(name, signames[i].name) == 0) {
      snprintf(buf, sizeof buf, "SIG%s", signames[i].name);
      *namep = buf;
      return signames[i].num;
    }
  }
  mrb_raisef(mrb, E_ARGUMENT_ERROR, "unsupported signal 'SIG%s'", name);
  return -1; /* not reached */
}

/* the canonical command for a disposition, or NULL when the command is not one that sets it (a proc, "EXIT", ...) */
static const char *
command_of(mrb_state *mrb, mrb_value cmd, int *ignore)
{
  const char *s;
  if (mrb_nil_p(cmd)) {
    *ignore = 1;
    return "IGNORE";
  }
  if (!mrb_string_p(cmd)) {
    mrb_raise(mrb, E_NOTIMP_ERROR, "Signal.trap with a proc or block is not supported: mruby has no safe point to run Ruby code from a signal");
  }
  s = mrb_str_to_cstr(mrb, cmd);
  if (strcmp(s, "") == 0 || strcmp(s, "IGNORE") == 0 || strcmp(s, "SIG_IGN") == 0) {
    *ignore = 1;
    return "IGNORE";
  }
  if (strcmp(s, "DEFAULT") == 0 || strcmp(s, "SIG_DFL") == 0) {
    *ignore = 0;
    return "DEFAULT";
  }
  if (strcmp(s, "SYSTEM_DEFAULT") == 0) {
    *ignore = 0;
    return "SYSTEM_DEFAULT";
  }
  if (strcmp(s, "EXIT") == 0) {
    mrb_raise(mrb, E_NOTIMP_ERROR, "Signal.trap with \"EXIT\" is not supported: it needs a Ruby handler that runs from a signal");
  }
  mrb_raisef(mrb, E_ARGUMENT_ERROR, "wrong trap command: %s", s);
  return NULL; /* not reached */
}

static mrb_value
handlers_hash(mrb_state *mrb, mrb_value mod)
{
  mrb_sym sym = mrb_intern_lit(mrb, "__handlers");
  mrb_value h = mrb_iv_get(mrb, mod, sym);
  if (!mrb_hash_p(h)) {
    h = mrb_hash_new(mrb);
    mrb_iv_set(mrb, mod, sym, h);
  }
  return h;
}

/* Signal.trap(sig, command = nil): sets the disposition of sig and returns the previous handler */
static mrb_value
mrb_f_signal_trap(mrb_state *mrb, mrb_value self)
{
  mrb_value sig, cmd = mrb_undef_value(), blk = mrb_nil_value();
  mrb_value handlers, key, prev;
  const char *name = NULL, *canon;
  int signo, ignore = 0;
  struct sigaction sa, old;

  mrb_get_args(mrb, "o|o&", &sig, &cmd, &blk);
  signo = signo_of(mrb, sig, &name);

  if (reserved_signal_p(signo)) {
    mrb_raisef(mrb, E_ARGUMENT_ERROR, "can't trap reserved signal: %s", name);
  }
  if (!mrb_nil_p(blk)) {
    mrb_raise(mrb, E_NOTIMP_ERROR, "Signal.trap with a proc or block is not supported: mruby has no safe point to run Ruby code from a signal");
  }
  if (mrb_undef_p(cmd)) {
    mrb_raise(mrb, E_ARGUMENT_ERROR, "Signal.trap needs a command or a block");
  }
  canon = command_of(mrb, cmd, &ignore);

  /* signal 0 is "EXIT" and has no disposition of its own; every other signal gets sigaction */
  memset(&old, 0, sizeof old);
  if (signo != 0) {
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = ignore ? SIG_IGN : SIG_DFL;
    sigemptyset(&sa.sa_mask);
    if (sigaction(signo, &sa, &old) != 0) {
      mrb_raisef(mrb, E_ARGUMENT_ERROR, "%s: %s", name, strerror(errno));
    }
  }

  /* the previous handler: the one Signal.trap set before, else the disposition the system had */
  handlers = handlers_hash(mrb, self);
  key = mrb_fixnum_value(signo);
  prev = mrb_hash_get(mrb, handlers, key);
  if (mrb_nil_p(prev) && signo != 0) {
    if (old.sa_handler == SIG_IGN) prev = mrb_str_new_cstr(mrb, "IGNORE");
    else if (old.sa_handler == SIG_DFL) prev = mrb_str_new_cstr(mrb, "DEFAULT");
  }
  mrb_hash_set(mrb, handlers, key, mrb_str_new_cstr(mrb, canon));
  return prev;
}

void
mrb_mruby_signal_gem_init(mrb_state *mrb)
{
  struct RClass *sig = mrb_define_module(mrb, "Signal");
  mrb_define_module_function(mrb, sig, "trap", mrb_f_signal_trap, MRB_ARGS_ARG(1, 1) | MRB_ARGS_BLOCK());
}

void
mrb_mruby_signal_gem_final(mrb_state *mrb)
{
}

#else /* _WIN32: no sigaction, so no Signal.trap */

static mrb_value
mrb_f_signal_trap(mrb_state *mrb, mrb_value self)
{
  (void)self;
  mrb_raise(mrb, E_NOTIMP_ERROR, "Signal.trap is not supported on this platform");
  return mrb_nil_value();
}

void
mrb_mruby_signal_gem_init(mrb_state *mrb)
{
  struct RClass *sig = mrb_define_module(mrb, "Signal");
  mrb_define_module_function(mrb, sig, "trap", mrb_f_signal_trap, MRB_ARGS_ARG(1, 1) | MRB_ARGS_BLOCK());
}

void
mrb_mruby_signal_gem_final(mrb_state *mrb)
{
}

#endif
