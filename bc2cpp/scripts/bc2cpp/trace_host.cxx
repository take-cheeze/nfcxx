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
// BC2CPP_HOST_MT_COUNT=1 prints the method-table size and exits before the game
// starts; BC2CPP_HOST_MT_HEAP=1 dumps the heap method-table entries the same
// way.
//
// BC2CPP_HOST_CLASS_MUTATIONS=DIR records what the run changes in the boot's
// classes (class_mutations.hxx).
//
// HOST_ARENA: the GC arena is restored after the boot and after every frame, as
// a device host does. A main_loop call that leaves more in the arena than
// mrb_funcall would (its result, if that is a heap object) fails the run.

#include <link.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <vector>

#include <lvgl.h>
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/error.h>
#include <mruby/gc.h>
#include <mruby/proc.h>
#include <mruby/string.h>
#include <mruby/variable.h>

#include "bc2cpp_entry.hxx"
#include "class_mutations.hxx"

// ROM_GRAPH: BC2CPP_HOST_ROM_GRAPH_DUMP=FILE writes the class graph the boot
// leaves as C (mruby's mrb_rom_graph_dump); trace_host.bash links it back in
// for BC2CPP_HOST_ROM_GRAPH=1. The classes whose tables change after the boot
// (rom_graph_ram_classes.h, beside the game's other headers) keep them in RAM.
#if __has_include(<mruby/rom_graph.h>)
#include <mruby/rom_graph.h>
#include "rom_graph_ram_classes.h"
#define TRACE_HOST_ROM_GRAPH 1
static void rom_graph_line(void* ud, const char* line) {
  fputs(line, static_cast<FILE*>(ud));
  fputc('\n', static_cast<FILE*>(ud));
}
#endif

// mruby-rgss/src/lib.cxx: hands the display to the RGSS natives (Graphics.width
// etc.).
extern "C" void rgss_set_display(mrb_state* M, lv_display_t* display);

#ifdef MRB_USE_METHOD_LOOKUP_HOOK
#include "method_lookup_survey.hxx"
#endif

// BC2CPP_HOST_GC_STRESS=N: a full GC before every Nth object allocation, as
// MRB_GC_STRESS does before every one, so a value no root keeps is freed at the
// next allocation. mruby's own pacing cannot do this: its threshold never drops
// below GC_STEP_SIZE (1024) allocations past the live count. trace_host.bash
// links with --wrap=mrb_obj_alloc, so every allocation outside gc.c comes here.
// Both ends are weak: alloc_counter.cxx's own wrapper replaces this one, and a
// host linked without the wrap (send_counter.bash) never calls it.
static long gc_stress_every = 0;
static long gc_stress_count = 0;
static long gc_stress_runs = 0;
extern "C" [[gnu::weak]] struct RBasic* __real_mrb_obj_alloc(
    mrb_state* M,
    enum mrb_vtype ttype,
    struct RClass* cls);
extern "C" [[gnu::weak]] struct RBasic* __wrap_mrb_obj_alloc(
    mrb_state* M,
    enum mrb_vtype ttype,
    struct RClass* cls) {
  if (gc_stress_every > 0 && ++gc_stress_count >= gc_stress_every) {
    gc_stress_count = 0;
    ++gc_stress_runs;
    mrb_full_gc(M);
  }
  return __real_mrb_obj_alloc(M, ttype, cls);
}

namespace {

#ifdef MRB_USE_METHOD_LOOKUP_HOOK
FILE* lookup_log = nullptr;

void log_method_lookup(mrb_state* M,
                       RClass* start,
                       RClass* owner,
                       mrb_sym mid,
                       const mrb_method_t* method) {
  mrb_int length = 0;
  const char* name = mrb_sym_name_len(M, mid, &length);
  if (fprintf(lookup_log, "%p\t%p\t%u\t", static_cast<void*>(start),
              static_cast<void*>(owner), static_cast<unsigned>(mid)) < 0) {
    perror("TRACE_HOST writing lookup log");
    abort();
  }
  for (mrb_int i = 0; i < length; ++i) {
    if (fprintf(lookup_log, "%02x", static_cast<unsigned char>(name[i])) < 0) {
      perror("TRACE_HOST writing lookup name");
      abort();
    }
  }
  if (fprintf(lookup_log, "\t%s\n",
              MRB_METHOD_UNDEF_P(*method) ? "missing" : "found") < 0) {
    perror("TRACE_HOST writing lookup result");
    abort();
  }
}

void close_lookup_log() {
  if (fclose(lookup_log) != 0) {
    perror("TRACE_HOST closing lookup log");
    abort();
  }
}
#endif

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

// BC2CPP_HOST_MT_COUNT=1: the number of method-table entries of every class,
// module and singleton class once the gems are initialised.
// scripts/bc2cpp/host_sweep.bash holds it to
// scripts/bc2cpp/method_table_threshold.txt, so a growth of the table is a
// deliberate edit, not a silent drift now that the lists behind it are
// computed.
int count_entry(mrb_state*, mrb_sym, mrb_method_t, void* total) {
  ++*static_cast<long*>(total);
  return 0;
}

int count_class_entries(mrb_state* M, struct RBasic* obj, void* total) {
  if (obj->tt == MRB_TT_CLASS || obj->tt == MRB_TT_MODULE ||
      obj->tt == MRB_TT_SCLASS) {
    mrb_mt_foreach(M, reinterpret_cast<struct RClass*>(obj), count_entry,
                   total);
  }
  return MRB_EACH_OBJ_OK;
}

// BC2CPP_HOST_MT_DUMP=1 (with BC2CPP_HOST_MT_COUNT=1): one line per
// method-table entry, "TRACE_HOST_MT <class> <method> <native|bytecode|undef>",
// the list the count sums. A singleton class is named by its attached object.
struct MtDump {
  mrb_state* M;
  struct RClass* klass;
};
int dump_entry(mrb_state* M, mrb_sym sym, mrb_method_t m, void* data) {
  auto* d = static_cast<MtDump*>(data);
  const char* name = mrb_class_name(M, d->klass);
  // The body kind: a C function (native or compiled), or a Ruby proc
  // (bytecode).
  const char* kind = MRB_METHOD_UNDEF_P(m)   ? "undef"
                     : MRB_METHOD_CFUNC_P(m) ? "native"
                                             : "bytecode";
  fprintf(stdout, "TRACE_HOST_MT %s %s %s\n", name ? name : "(anonymous)",
          mrb_sym_name(M, sym), kind);
  return 0;
}
int dump_class_entries(mrb_state* M, struct RBasic* obj, void* data) {
  if (obj->tt == MRB_TT_CLASS || obj->tt == MRB_TT_MODULE ||
      obj->tt == MRB_TT_SCLASS) {
    auto* d = static_cast<MtDump*>(data);
    d->klass = reinterpret_cast<struct RClass*>(obj);
    mrb_mt_foreach(M, d->klass, dump_entry, d);
  }
  return MRB_EACH_OBJ_OK;
}

// BC2CPP_HOST_MT_HEAP=1: the heap (mutable) method-table entries once the gems
// are initialised, one "TRACE_HOST_MT_HEAP <class> <method> <kind> <offset>"
// line each (offset: the C function's, from the load base), then a summary.
// scripts/bc2cpp/rom_method_tables_check.rb reads both.
uintptr_t load_base = 0;
int load_base_cb(struct dl_phdr_info* info, size_t, void*) {
  load_base = info->dlpi_addr;
  return 1;
}
int collect_classes(mrb_state*, struct RBasic* obj, void* data) {
  if (obj->tt == MRB_TT_CLASS || obj->tt == MRB_TT_MODULE ||
      obj->tt == MRB_TT_SCLASS ||
      (obj->tt == MRB_TT_ICLASS && (obj->flags & MRB_FL_CLASS_IS_ORIGIN)))
    static_cast<std::vector<struct RClass*>*>(data)->push_back(
        reinterpret_cast<struct RClass*>(obj));
  return MRB_EACH_OBJ_OK;
}
// A heap entry is a duplicate when a ROM layer below it holds the same name and
// function (what a registration's table replaces).
bool rom_duplicate(const mrb_mt_tbl* below, const mrb_mt_entry& e) {
  for (; below; below = below->next) {
    if (!(below->alloc & MRB_MT_READONLY_BIT))
      continue;
    for (int i = 0; i < below->size; ++i)
      if (below->ptr[i].key == e.key && below->ptr[i].val.func == e.val.func)
        return true;
  }
  return false;
}
void dump_heap_tables(mrb_state* M) {
  dl_iterate_phdr(load_base_cb, nullptr);
  std::vector<struct RClass*> classes;
  mrb_objspace_each_objects(M, collect_classes, &classes);
  M->gc.disabled = TRUE;
  long entries = 0, layers = 0, bytes = 0, rom = 0, duplicates = 0;
  const int flag_bits = MRB_MT_READONLY_BIT | MRB_MT_FROZEN_BIT;
  for (struct RClass* c : classes) {
    const char* name = c->tt == MRB_TT_ICLASS ? nullptr : mrb_class_name(M, c);
    for (const mrb_mt_tbl* t = c->mt; t; t = t->next) {
      if (t->alloc & MRB_MT_READONLY_BIT) {
        ++rom;
        continue;
      }
      ++layers;
      bytes +=
          sizeof(mrb_mt_tbl) + (t->alloc & ~flag_bits) * sizeof(mrb_mt_entry);
      for (int i = 0; i < t->size; ++i) {
        const mrb_mt_entry& e = t->ptr[i];
        ++entries;
        const bool func = e.flags & MRB_MT_FUNC;
        if (func && e.val.func && rom_duplicate(t->next, e))
          ++duplicates;
        const char* kind = MRB_MT_REMOVED_P(e)            ? "removed"
                           : func                         ? "func"
                           : !e.val.proc                  ? "undef"
                           : MRB_PROC_CFUNC_P(e.val.proc) ? "cfuncproc"
                                                          : "proc";
        uintptr_t fn = func && e.val.func ? (uintptr_t)e.val.func
                       : !func && e.val.proc && MRB_PROC_CFUNC_P(e.val.proc)
                           ? (uintptr_t)MRB_PROC_CFUNC(e.val.proc)
                           : 0;
        fprintf(stdout, "TRACE_HOST_MT_HEAP %s %s %s %lx\n",
                name ? name : "(anonymous)", mrb_sym_name(M, e.key), kind,
                fn ? (unsigned long)(fn - load_base) : 0UL);
      }
    }
  }
  fprintf(stdout,
          "TRACE_HOST heap_method_tables entries=%ld layers=%ld bytes=%ld "
          "rom_layers=%ld rom_duplicates=%ld\n",
          entries, layers, bytes, rom, duplicates);
}

void set_const(mrb_state* M, const char* name, mrb_value v) {
  mrb_const_set(M, mrb_obj_value(M->object_class), mrb_intern_cstr(M, name), v);
}

bool kernel_factory_present(mrb_state* M, const char* name) {
  if (!mrb_respond_to(M, mrb_obj_value(M->top_self), mrb_intern_cstr(M, name)))
    return false;
  fprintf(stderr, "TRACE_HOST omitted Kernel factory present: %s\n", name);
  return true;
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

// Prints the scene every 50 frames and whenever it changes.
void print_scene(mrb_state* M, mrb_value game, long frame, bool always) {
  static char last[128];
  mrb_value name = bc2cpp_entry_RPG2k_current_scene_name(M, game);
  const char* const cur = mrb_string_p(name) ? RSTRING_PTR(name) : "?";
  if (!always && strcmp(cur, last) == 0)
    return;
  snprintf(last, sizeof last, "%s", cur);
  fprintf(stdout, "TRACE_HOST frame=%ld scene=%s\n", frame, cur);
  fflush(stdout);
}

// BC2CPP_HOST_KEYS: scripted input, "FRAME:KEY,FRAME:KEY,..." with KEY an
// RGSS::Input constant name (C, B, DOWN, ...). Each key is pressed before
// that frame's main_loop and released before the next one, the same
// RGSS::Input.press / .release taps the battle-play probe uses
// (mruby-rpg2k/mrblib/main.rb).
struct KeyTap {
  long frame;
  char key[16];
};

std::vector<KeyTap> parse_keys(const char* spec) {
  std::vector<KeyTap> taps;
  while (spec && *spec) {
    KeyTap tap{};
    int used = 0;
    if (sscanf(spec, "%ld:%15[A-Z0-9_]%n", &tap.frame, tap.key, &used) != 2) {
      fprintf(stderr, "TRACE_HOST bad BC2CPP_HOST_KEYS entry: %s\n", spec);
      exit(64);
    }
    taps.push_back(tap);
    spec += used;
    if (*spec == ',')
      ++spec;
  }
  return taps;
}

void tap_keys(mrb_state* M, const std::vector<KeyTap>& taps, long frame) {
  struct RClass* const input =
      mrb_module_get_under(M, mrb_module_get(M, "RGSS"), "Input");
  for (const KeyTap& tap : taps) {
    if (tap.frame != frame && tap.frame != frame - 1)
      continue;
    const mrb_value key =
        mrb_const_get(M, mrb_obj_value(input), mrb_intern_cstr(M, tap.key));
    mrb_funcall(M, mrb_obj_value(input),
                tap.frame == frame ? "press" : "release", 1, key);
  }
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

  const char* survey_path = getenv("BC2CPP_HOST_LOOKUP_SURVEY");
#ifdef MRB_USE_METHOD_LOOKUP_HOOK
  if (survey_path) {
    lookup_survey::output_path = survey_path;
    if (atexit(lookup_survey::dump) != 0) {
      fprintf(stderr, "TRACE_HOST cannot register lookup survey dump\n");
      return 2;
    }
  }
  mrb_state* const M =
      survey_path ? mrb_open_with_method_lookup_hook(lookup_survey::observe)
                  : mrb_open();
#else
  if (survey_path) {
    fprintf(stderr, "TRACE_HOST survey requires BC2CPP_METHOD_LOOKUP_HOOK=1\n");
    return 2;
  }
  mrb_state* const M = mrb_open();
#endif
  if (!M) {
    fprintf(stderr, "TRACE_HOST mrb_open failed\n");
    return 2;
  }
  // mrb_open returns the state with mrb->exc set when a gem's init raised; every later gem is then uninitialized.
  if (M->exc) {
    report_exception(M, "mrb_open (gem init)");
    return 2;
  }
  if (const char* const graph = getenv("BC2CPP_HOST_ROM_GRAPH_DUMP")) {
#ifdef TRACE_HOST_ROM_GRAPH
    static const char* const ram_classes[] = {ROM_GRAPH_RAM_CLASSES, nullptr};
    FILE* const f = fopen(graph, "w");
    if (!f) {
      perror("TRACE_HOST rom graph dump");
      return 2;
    }
    mrb_rom_graph_dump(M, rom_graph_line, f, ram_classes);
    fclose(f);
    fprintf(stdout, "TRACE_HOST rom graph %s (%s)\n", graph,
            mrb_rom_graph_active(M) ? "on the graph" : "heap classes");
    if (getenv("BC2CPP_HOST_ROM_GRAPH_DUMP_ONLY"))
      return 0;
#else
    fprintf(stderr, "TRACE_HOST this mruby has no mruby/rom_graph.h\n");
    return 2;
#endif
  }
  if (const char* const mut = getenv("BC2CPP_HOST_CLASS_MUTATIONS")) {
    class_mutations::boot(M, mut);
    if (atexit(class_mutations::report) != 0) {
      fprintf(stderr, "TRACE_HOST cannot register class mutation report\n");
      return 2;
    }
  }
  // After the boot: the gem inits are the same in every run.
  if (const char* const stress = getenv("BC2CPP_HOST_GC_STRESS"))
    gc_stress_every = atol(stress) > 0 ? atol(stress) : 1;
#ifdef MRB_USE_METHOD_LOOKUP_HOOK
  if (survey_path)
    lookup_survey::snapshot(M);
#endif
  const char* const lookup_path = getenv("BC2CPP_HOST_LOOKUPS");
  if (lookup_path && survey_path) {
    fprintf(stderr,
            "TRACE_HOST choose raw lookup logging or the aggregate survey\n");
    return 2;
  }
  if (lookup_path) {
#ifdef MRB_USE_METHOD_LOOKUP_HOOK
    lookup_log = fopen(lookup_path, "w");
    if (!lookup_log) {
      perror("TRACE_HOST opening lookup log");
      mrb_close(M);
      return 2;
    }
    if (atexit(close_lookup_log) != 0) {
      fprintf(stderr, "TRACE_HOST cannot register lookup log close\n");
      fclose(lookup_log);
      mrb_close(M);
      return 2;
    }
    if (fprintf(lookup_log, "start\towner\tsymbol_id\tname_hex\tresult\n") <
        0) {
      perror("TRACE_HOST writing lookup header");
      mrb_close(M);
      return 2;
    }
    M->method_lookup_hook = log_method_lookup;
#else
    fprintf(stderr,
            "TRACE_HOST lookup logging requires BC2CPP_METHOD_LOOKUP_HOOK=1 at "
            "build time\n");
    mrb_close(M);
    return 2;
#endif
  }
  rgss_set_display(M, disp);

  if (getenv("BC2CPP_HOST_OMITTED_DEPS")) {
    bool present = false;
    for (const char* name : {"Marshal", "Struct", "Random"}) {
      if (mrb_const_defined_at(M, mrb_obj_value(M->object_class),
                               mrb_intern_cstr(M, name))) {
        fprintf(stderr, "TRACE_HOST omitted dependency present: %s\n", name);
        present = true;
      }
    }
    // Literal callers keep the finite probe names visible to main-root
    // analysis.
    present |= kernel_factory_present(M, "Integer");
    present |= kernel_factory_present(M, "Float");
    present |= kernel_factory_present(M, "String");
    present |= kernel_factory_present(M, "Array");
    present |= kernel_factory_present(M, "Hash");
    if (!present)
      fprintf(stdout, "TRACE_HOST omitted dependencies absent\n");
    mrb_close(M);
    return present ? 1 : 0;
  }

  if (const char* const count = getenv("BC2CPP_HOST_MT_COUNT");
      count && strcmp(count, "1") == 0) {
    long total = 0;
    mrb_objspace_each_objects(M, count_class_entries, &total);
    if (getenv("BC2CPP_HOST_MT_DUMP")) {
      MtDump dump{M, nullptr};
      mrb_objspace_each_objects(M, dump_class_entries, &dump);
    }
    fprintf(stdout, "TRACE_HOST method_table_entries=%ld\n", total);
    return 0;
  }

  if (const char* const heap = getenv("BC2CPP_HOST_MT_HEAP");
      heap && strcmp(heap, "1") == 0) {
    dump_heap_tables(M);
    return 0;
  }

  // What the boot leaves in the arena is kept by a constant or by the game,
  // which is registered below.
  const int boot_ai = mrb_gc_arena_save(M);
  set_const(M, "GAME_DIR", mrb_str_new_cstr(M, game_dir));
  set_const(M, "RTP_DIR", mrb_str_new_cstr(M, ""));
  set_const(M, "TEST_PLAY", mrb_false_value());
  // No 60 fps pacing (mruby-rgss/src/lib.cxx): every game timer runs off
  // frame_count, so the frames are the same and a timed run measures work.
  set_const(M, "NO_RENDER_WAIT", mrb_true_value());
  // Auto-selects New Game on the title screen, or Continue with
  // BC2CPP_HOST_CONTINUE=1 (mruby-rpg2k/mrblib/scene/title.rb).
  const char* const cont = getenv("BC2CPP_HOST_CONTINUE");
  const bool continue_game = cont && strcmp(cont, "1") == 0;
  set_const(M, "RPG2K_NEW_GAME", mrb_bool_value(!continue_game));
  set_const(M, "RPG2K_CONTINUE", mrb_bool_value(continue_game));
  // BC2CPP_HOST_PREVIEW_MAP starts New Game on that map's centre tile instead
  // of the project's start (mruby-rpg2k/mrblib/main.rb, #preview_map_id).
  const char* const preview = getenv("BC2CPP_HOST_PREVIEW_MAP");
  set_const(M, "RPG2K_PREVIEW_MAP",
            mrb_fixnum_value(preview ? strtol(preview, nullptr, 10) : 0));
  // BC2CPP_HOST_BATTLE_TROOP opens a headless battle against that troop right
  // after New Game; BC2CPP_HOST_BATTLE_PLAY=1 also drives it with confirm taps
  // (mruby-rpg2k/mrblib/main.rb, #headless_battle_troop and
  // #battle_play_requested?). Both off by default.
  const char* const troop = getenv("BC2CPP_HOST_BATTLE_TROOP");
  const char* const play = getenv("BC2CPP_HOST_BATTLE_PLAY");
  set_const(M, "RPG2K_BATTLE_TROOP",
            mrb_fixnum_value(troop ? strtol(troop, nullptr, 10) : 0));
  set_const(M, "RPG2K_BATTLE_PLAY",
            mrb_bool_value(play && strcmp(play, "1") == 0));

  mrb_value args = mrb_ary_new(M);
  mrb_value game = bc2cpp_entry_RPG2k_new(M, 1, &args);
  if (M->exc) {
    report_exception(M, "RPG2k.new");
    return 3;
  }
  mrb_gc_register(M, game);
  mrb_gc_arena_restore(M, boot_ai);
#ifdef MRB_CLASS_SHRINK
  // As the Wio main does once the game's constants are set.
  mrb_class_shrink(M);
#endif
  fprintf(stdout, "TRACE_HOST game=RPG2k dir=%s frames=%ld\n", game_dir,
          frames);
  // BC2CPP_ENTRY (include/bc2cpp_entry.hxx): whether new, main_loop and
  // current_scene_name call their compiled bodies directly.
  fprintf(stdout,
          "TRACE_HOST entry new=%s main_loop=%s current_scene_name=%s\n",
          BC2CPP_ENTRY_RPG2k_new ? "direct" : "by-name",
          BC2CPP_ENTRY_RPG2k_main_loop ? "direct" : "by-name",
          BC2CPP_ENTRY_RPG2k_current_scene_name ? "direct" : "by-name");

  const std::vector<KeyTap> taps = parse_keys(getenv("BC2CPP_HOST_KEYS"));
  const int frame_ai = mrb_gc_arena_save(M);
  for (long frame = 0; frame < frames; ++frame) {
    print_scene(M, game, frame, frame % 50 == 0);
    tap_keys(M, taps, frame);
    if (M->exc) {
      report_exception(M, "BC2CPP_HOST_KEYS");
      return 4;
    }
    const int entry_idx = M->gc.arena_idx;
    const mrb_value result = bc2cpp_entry_RPG2k_main_loop(M, game);
    const int left = M->gc.arena_idx - entry_idx;
    if (M->exc) {
      const bool clean = report_exception(M, "main_loop");
      fprintf(stdout, "TRACE_HOST stopped frame=%ld reason=%s\n", frame,
              clean ? "exit" : "error");
      return clean ? 0 : 4;
    }
    if (left > (mrb_immediate_p(result) ? 0 : 1)) {
      fprintf(stderr,
              "TRACE_HOST arena leak: main_loop left %d arena entries at "
              "frame=%ld\n",
              left, frame);
      return 5;
    }
    mrb_gc_arena_restore(M, frame_ai);
  }
  print_scene(M, game, frames, true);
  mrb_gc_arena_restore(M, frame_ai);
  fprintf(stdout, "TRACE_HOST done frames=%ld arena=%d\n", frames,
          M->gc.arena_idx);
  if (gc_stress_every > 0)
    fprintf(stdout, "TRACE_HOST gc_stress every=%ld full_gcs=%ld\n",
            gc_stress_every, gc_stress_runs);
  return 0;
}
