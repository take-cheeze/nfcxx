// Headless host for the closed bc2cpp libmruby.a
// (scripts/bc2cpp/trace_host.bash).
//
// Mirrors the PSP entry point (app/psp/main.cxx) without the device: it opens
// mruby, creates an LVGL display at RPG2k's native 320x240, sets the game
// constants, constructs RPG2k (which auto-selects New Game through
// RPG2K_NEW_GAME), and runs a bounded number of RPG2k#main_loop frames. Exits
// normally so the BC2CPP_TRACE_TYPES atexit dump runs.
//
// Usage: trace_host GAME_DIR [FRAMES]

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

#include <lvgl.h>
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/error.h>
#include <mruby/string.h>
#include <mruby/variable.h>

// mruby-rgss/src/lib.cxx: hands the display to the RGSS natives (Graphics.width
// etc.).
extern "C" void rgss_set_display(mrb_state* M, lv_display_t* display);

namespace {

constexpr int32_t kWidth = 320;
constexpr int32_t kHeight = 240;

uint32_t tick_ms() {
  timespec ts{};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return static_cast<uint32_t>(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

void delay_ms(uint32_t ms) {
  timespec ts{};
  ts.tv_sec = ms / 1000;
  ts.tv_nsec = static_cast<long>(ms % 1000) * 1000000L;
  nanosleep(&ts, nullptr);
}

// No window to draw into: the frame is discarded, but LVGL still needs the
// flush acknowledged or it stops rendering.
void flush_cb(lv_display_t* disp, const lv_area_t*, uint8_t*) {
  lv_display_flush_ready(disp);
}

void set_const(mrb_state* M, const char* name, mrb_value v) {
  mrb_const_set(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, name), v);
}

// Prints the pending Ruby exception (class and message) to stderr and clears
// it. Returns true when it was a SystemExit, which is a normal end of the game.
bool report_exception(mrb_state* M, const char* where) {
  const bool clean_exit = MRB_EXC_EXIT_P(M->exc);
  // Cleared before any Ruby call below: a pending exception would abort the
  // call.
  mrb_value exc = mrb_obj_value(M->exc);
  M->exc = nullptr;
  const char* cls_name = mrb_obj_classname(M, exc);
  mrb_value msg = mrb_funcall(M, exc, "message", 0);
  fprintf(stderr, "TRACE_HOST %s %s: %s\n", where, cls_name,
          mrb_string_p(msg) ? RSTRING_PTR(msg) : "?");
  M->exc = nullptr;
  return clean_exit;
}

void print_scene(mrb_state* M, mrb_value game, long frame) {
  mrb_value name = mrb_funcall(M, game, "current_scene_name", 0);
  fprintf(stdout, "TRACE_HOST frame=%ld scene=%s\n", frame,
          mrb_string_p(name) ? RSTRING_PTR(name) : "?");
  fflush(stdout);
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s GAME_DIR [FRAMES]\n", argv[0]);
    return 64;
  }
  const char* game_dir = argv[1];
  const long frames = argc > 2 ? strtol(argv[2], nullptr, 10) : 600;
  if (frames <= 0) {
    fprintf(stderr, "TRACE_HOST bad frame count: %s\n", argv[2]);
    return 64;
  }

  lv_init();
  lv_tick_set_cb(tick_ms);
  lv_delay_set_cb(delay_ms);
  lv_display_t* const disp = lv_display_create(kWidth, kHeight);
  if (!disp) {
    fprintf(stderr, "TRACE_HOST lv_display_create failed\n");
    return 2;
  }
  lv_display_set_color_format(disp, LV_COLOR_FORMAT_RGB565);
  const uint32_t buf_size = kWidth * kHeight * sizeof(uint16_t);
  void* const buf = calloc(1, buf_size);
  if (!buf) {
    fprintf(stderr, "TRACE_HOST framebuffer alloc failed\n");
    return 2;
  }
  lv_display_set_buffers(disp, buf, nullptr, buf_size,
                         LV_DISPLAY_RENDER_MODE_FULL);
  lv_display_set_flush_cb(disp, flush_cb);

  mrb_state* const M = mrb_open();
  if (!M) {
    fprintf(stderr, "TRACE_HOST mrb_open failed\n");
    return 2;
  }
  rgss_set_display(M, disp);

  set_const(M, "GAME_DIR", mrb_str_new_cstr(M, game_dir));
  set_const(M, "RTP_DIR", mrb_str_new_cstr(M, ""));
  set_const(M, "TEST_PLAY", mrb_false_value());
  // Auto-selects New Game on the title screen
  // (mruby-rpg2k/mrblib/scene/title.rb).
  set_const(M, "RPG2K_NEW_GAME", mrb_true_value());
  set_const(M, "RPG2K_CONTINUE", mrb_false_value());
  set_const(M, "RPG2K_PREVIEW_MAP", mrb_fixnum_value(0));
  set_const(M, "RPG2K_BATTLE_TROOP", mrb_fixnum_value(0));

  mrb_value args = mrb_ary_new(M);
  mrb_value game = mrb_obj_new(M, mrb_class_get(M, "RPG2k"), 1, &args);
  if (M->exc) {
    report_exception(M, "RPG2k.new");
    return 3;
  }
  mrb_gc_register(M, game);
  fprintf(stdout, "TRACE_HOST game=RPG2k dir=%s frames=%ld\n", game_dir,
          frames);

  for (long frame = 0; frame < frames; ++frame) {
    if (frame % 50 == 0)
      print_scene(M, game, frame);
    mrb_funcall(M, game, "main_loop", 0);
    if (M->exc) {
      const bool clean = report_exception(M, "main_loop");
      fprintf(stdout, "TRACE_HOST stopped frame=%ld reason=%s\n", frame,
              clean ? "exit" : "error");
      return clean ? 0 : 4;
    }
  }
  print_scene(M, game, frames);
  fprintf(stdout, "TRACE_HOST done frames=%ld\n", frames);
  return 0;
}
