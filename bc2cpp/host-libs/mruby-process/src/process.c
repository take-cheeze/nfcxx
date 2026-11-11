/* Process primitives for mruby-process. BC2CPPProcess.run(argv, env, stdin_data) spawns argv (no shell), with env
 * overrides ([[name, value_or_nil], ...]) applied in the child, feeds stdin_data (or nothing), and returns
 * [stdout, stderr, status] once the child exits; status is the exit code, or 128 + the signal number. pid and
 * monotonic give Process.pid and Process.clock_gettime(CLOCK_MONOTONIC). */
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/string.h>
#include <mruby/value.h>
#include <errno.h>
#include <mruby/error.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static void close_pair(int fd[2])
{
  if (fd[0] >= 0) close(fd[0]);
  if (fd[1] >= 0) close(fd[1]);
}

static void apply_env(mrb_state *mrb, mrb_value env)
{
  if (mrb_nil_p(env)) return;
  mrb_int n = RARRAY_LEN(env);
  for (mrb_int i = 0; i < n; i++) {
    mrb_value pair = mrb_ary_ref(mrb, env, i);
    mrb_value name = mrb_ary_ref(mrb, pair, 0);
    mrb_value value = mrb_ary_ref(mrb, pair, 1);
    if (mrb_nil_p(value)) {
      unsetenv(RSTRING_PTR(name));
    } else {
      mrb_value text = mrb_obj_as_string(mrb, value);
      setenv(RSTRING_PTR(name), RSTRING_PTR(text), 1);
    }
  }
}

static mrb_value proc_run(mrb_state *mrb, mrb_value self)
{
  mrb_value argv, env, input;
  mrb_get_args(mrb, "AAo", &argv, &env, &input);
  mrb_int argc = RARRAY_LEN(argv);
  if (argc < 1) mrb_raise(mrb, E_ARGUMENT_ERROR, "run: no command");

  char **args = mrb_malloc(mrb, sizeof(char *) * (argc + 1));
  for (mrb_int i = 0; i < argc; i++) {
    mrb_value a = mrb_obj_as_string(mrb, mrb_ary_ref(mrb, argv, i));
    args[i] = RSTRING_PTR(a);
  }
  args[argc] = NULL;

  const char *data = NULL;
  mrb_int data_len = 0;
  if (!mrb_nil_p(input)) {
    mrb_value s = mrb_obj_as_string(mrb, input);
    data = RSTRING_PTR(s);
    data_len = RSTRING_LEN(s);
  }

  int in_p[2] = {-1, -1}, out_p[2] = {-1, -1}, err_p[2] = {-1, -1};
  if (pipe(in_p) < 0 || pipe(out_p) < 0 || pipe(err_p) < 0) {
    close_pair(in_p); close_pair(out_p); close_pair(err_p);
    mrb_free(mrb, args);
    mrb_raise(mrb, E_RUNTIME_ERROR, "Open3: pipe failed");
  }

  fflush(NULL);
  pid_t pid = fork();
  if (pid < 0) {
    close_pair(in_p); close_pair(out_p); close_pair(err_p);
    mrb_free(mrb, args);
    mrb_raise(mrb, E_RUNTIME_ERROR, "Open3: fork failed");
  }
  if (pid == 0) {
    dup2(in_p[0], 0);
    dup2(out_p[1], 1);
    dup2(err_p[1], 2);
    close(in_p[1]); close(out_p[0]); close(err_p[0]);
    apply_env(mrb, env);
    execvp(args[0], args);
    _exit(127);
  }
  close(in_p[0]); close(out_p[1]); close(err_p[1]);
  mrb_free(mrb, args);

  /* Feed stdin and collect stdout and stderr together, so neither pipe can fill and stall the child. */
  mrb_value out = mrb_str_new_cstr(mrb, "");
  mrb_value err = mrb_str_new_cstr(mrb, "");
  mrb_int written = 0;
  int out_open = 1, err_open = 1;
  int in_open = data_len > 0 ? 1 : 0;
  if (!in_open) { close(in_p[1]); in_p[1] = -1; }
  char buf[4096];
  while (out_open || err_open || in_open) {
    struct pollfd fds[3];
    int n = 0, idx_in = -1, idx_out = -1, idx_err = -1;
    if (in_open) { idx_in = n; fds[n].fd = in_p[1]; fds[n].events = POLLOUT; n++; }
    if (out_open) { idx_out = n; fds[n].fd = out_p[0]; fds[n].events = POLLIN; n++; }
    if (err_open) { idx_err = n; fds[n].fd = err_p[0]; fds[n].events = POLLIN; n++; }
    if (poll(fds, n, -1) < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (idx_in >= 0 && fds[idx_in].revents) {
      ssize_t w = write(in_p[1], data + written, data_len - written);
      if (w > 0) written += w;
      if (w <= 0 || written == data_len) { close(in_p[1]); in_p[1] = -1; in_open = 0; }
    }
    if (idx_out >= 0 && fds[idx_out].revents) {
      ssize_t r = read(out_p[0], buf, sizeof buf);
      if (r > 0) mrb_str_cat(mrb, out, buf, r); else { out_open = 0; close(out_p[0]); out_p[0] = -1; }
    }
    if (idx_err >= 0 && fds[idx_err].revents) {
      ssize_t r = read(err_p[0], buf, sizeof buf);
      if (r > 0) mrb_str_cat(mrb, err, buf, r); else { err_open = 0; close(err_p[0]); err_p[0] = -1; }
    }
  }
  if (in_p[1] >= 0) close(in_p[1]);
  if (out_p[0] >= 0) close(out_p[0]);
  if (err_p[0] >= 0) close(err_p[0]);

  int status = 0;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
  int code = WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 1);

  mrb_value result = mrb_ary_new_capa(mrb, 3);
  mrb_ary_push(mrb, result, out);
  mrb_ary_push(mrb, result, err);
  mrb_ary_push(mrb, result, mrb_fixnum_value(code));
  return result;
}

static mrb_value proc_pid(mrb_state *mrb, mrb_value self)
{
  return mrb_fixnum_value((mrb_int)getpid());
}

static mrb_value proc_monotonic(mrb_state *mrb, mrb_value self)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return mrb_float_value(mrb, (mrb_float)ts.tv_sec + (mrb_float)ts.tv_nsec / 1e9);
}


/* fork(): the child gets 0, the parent the child's pid. mruby keeps no threads, so the copy is the whole process. */
static mrb_value proc_fork(mrb_state *mrb, mrb_value self)
{
  fflush(NULL);
  pid_t pid = fork();
  if (pid < 0) mrb_raise(mrb, E_RUNTIME_ERROR, "fork failed");
  return mrb_fixnum_value((mrb_int)pid);
}

/* wait(pid): [pid, exit code] of a child, waiting for it. */
static mrb_value proc_wait(mrb_state *mrb, mrb_value self)
{
  mrb_int pid;
  mrb_get_args(mrb, "i", &pid);
  int status = 0;
  pid_t got;
  while ((got = waitpid((pid_t)pid, &status, 0)) < 0 && errno == EINTR) {}
  if (got < 0) mrb_raise(mrb, E_RUNTIME_ERROR, "wait failed");
  int code = WIFEXITED(status) ? WEXITSTATUS(status) : (WIFSIGNALED(status) ? 128 + WTERMSIG(status) : 1);
  mrb_value out = mrb_ary_new_capa(mrb, 2);
  mrb_ary_push(mrb, out, mrb_fixnum_value((mrb_int)got));
  mrb_ary_push(mrb, out, mrb_fixnum_value(code));
  return out;
}

static mrb_value proc_dup(mrb_state *mrb, mrb_value self)
{
  mrb_int fd;
  mrb_get_args(mrb, "i", &fd);
  int out = dup((int)fd);
  if (out < 0) mrb_raise(mrb, E_RUNTIME_ERROR, "dup failed");
  return mrb_fixnum_value((mrb_int)out);
}

static mrb_value proc_dup2(mrb_state *mrb, mrb_value self)
{
  mrb_int src, dst;
  mrb_get_args(mrb, "ii", &src, &dst);
  if (dup2((int)src, (int)dst) < 0) mrb_raise(mrb, E_RUNTIME_ERROR, "dup2 failed");
  return mrb_nil_value();
}

/* open_file(path, mode): a descriptor for 'r' (read), 'w' (create, truncate) or 'a' (append). */
static mrb_value proc_open_file(mrb_state *mrb, mrb_value self)
{
  const char *path, *mode;
  mrb_get_args(mrb, "zz", &path, &mode);
  int flags = O_RDONLY;
  if (mode[0] == 'w') flags = O_WRONLY | O_CREAT | O_TRUNC;
  else if (mode[0] == 'a') flags = O_WRONLY | O_CREAT | O_APPEND;
  int fd = open(path, flags, 0644);
  if (fd < 0) mrb_raise(mrb, E_RUNTIME_ERROR, "open failed");
  return mrb_fixnum_value((mrb_int)fd);
}

static mrb_value proc_close(mrb_state *mrb, mrb_value self)
{
  mrb_int fd;
  mrb_get_args(mrb, "i", &fd);
  close((int)fd);
  return mrb_nil_value();
}

void mrb_mruby_process_gem_init(mrb_state *mrb)
{
  struct RClass *prim = mrb_define_module(mrb, "BC2CPPProcess");
  mrb_define_module_function(mrb, prim, "run", proc_run, MRB_ARGS_REQ(3));
  mrb_define_module_function(mrb, prim, "pid", proc_pid, MRB_ARGS_NONE());
  mrb_define_module_function(mrb, prim, "monotonic", proc_monotonic, MRB_ARGS_NONE());
  mrb_define_module_function(mrb, prim, "fork", proc_fork, MRB_ARGS_NONE());
  mrb_define_module_function(mrb, prim, "wait", proc_wait, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, prim, "dup", proc_dup, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, prim, "dup2", proc_dup2, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, prim, "open_file", proc_open_file, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, prim, "close", proc_close, MRB_ARGS_REQ(1));
}

void mrb_mruby_process_gem_final(mrb_state *mrb)
{
}
