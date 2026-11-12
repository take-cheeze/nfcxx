#!/usr/bin/env ruby
# frozen_string_literal: true

# FRAME_FREE (tools/bc2cpp/native_frame_use.rb): a native is called without its frame when its C body (and what it calls)
# reads the frame only through the argument readers. This holds that property on fixture C sources, one shape each, and
# the generated helper to the rows it is given.
#
#   free     arguments, a raise, a send, helpers of the same file, a helper that reads no frame
#   framed   the block, `&` in a mrb_get_args format, a format that is not a literal, yield, `mrb->c->ci`, the method id,
#            a function pointer that is a parameter, a pointer that is never assigned a function, a library function
#            that reads the frame, a callee that does
#   registrations  plain defines of a gem, attributed by the class variable or a core class field
#   C++      a lambda read where it is written, a template's callable parameter, a class's constructor and destructor
#            through a local of it, a callable member, global or `catch`; a lambda registered in place has no row
#
# Usage: ruby scripts/bc2cpp/native_frame_use_check.rb

require_relative '../../tools/bc2cpp/world_root'
require 'tmpdir'
require 'fileutils'
require_relative 'check_support'
require_relative '../../tools/bc2cpp/native_frame_use'

suite = FixtureCheck.new('native_frame_use_check')

Dir.mktmpdir('native_frame_use_check') do |dir|
  lib_dir = File.join(dir, '3rd', 'mruby', 'src')
  FileUtils.mkdir_p(lib_dir)
  File.write(File.join(lib_dir, 'lib.c'), <<~C)
    mrb_int
    lib_reads_frame(mrb_state *mrb)
    {
      return mrb->c->ci->n;
    }

    mrb_value
    lib_reads_nothing(mrb_state *mrb, mrb_value v)
    {
      return mrb_str_new_lit(mrb, "x");
    }

    void
    mrb_collect_something(mrb_state *mrb)
    {
      mrb_callinfo *ci = mrb->c->ci;
      (void)ci;
    }

    mrb_value
    alloc_user(mrb_state *mrb)
    {
      mrb_collect_something(mrb);
      return mrb_nil_value();
    }
  C
  File.write(File.join(lib_dir, 'gc.c'), <<~C)
    void
    mrb_full_gc(mrb_state *mrb)
    {
      mrb_callinfo *ci = mrb->c->ci;
      (void)ci;
    }
  C
  gem = File.join(dir, 'gem.c')
  File.write(gem, <<~C)
    static mrb_value
    helper_reads_args(mrb_state *mrb)
    {
      mrb_int n;
      mrb_get_args(mrb, "i", &n);
      return mrb_int_value(mrb, n);
    }

    static mrb_value
    n_args(mrb_state *mrb, mrb_value self)
    {
      return helper_reads_args(mrb);
    }

    static mrb_value
    n_raise(mrb_state *mrb, mrb_value self)
    {
      mrb_raise(mrb, E_RUNTIME_ERROR, "x");
      return self;
    }

    static mrb_value
    n_send(mrb_state *mrb, mrb_value self)
    {
      return mrb_funcall(mrb, self, "to_s", 0);
    }

    static mrb_value
    n_plain(mrb_state *mrb, mrb_value self)
    {
      return lib_reads_nothing(mrb, self);
    }

    static mrb_value
    n_block(mrb_state *mrb, mrb_value self)
    {
      return mrb_bool_value(mrb_block_given_p(mrb));
    }

    static mrb_value
    n_amp(mrb_state *mrb, mrb_value self)
    {
      mrb_value b;
      mrb_get_args(mrb, "&", &b);
      return b;
    }

    static mrb_value
    n_dynamic_format(mrb_state *mrb, mrb_value self)
    {
      const char *fmt = "i";
      mrb_int n;
      mrb_get_args(mrb, fmt, &n);
      return self;
    }

    static mrb_value
    n_yield(mrb_state *mrb, mrb_value self)
    {
      mrb_value b;
      mrb_get_args(mrb, "o", &b);
      return mrb_yield(mrb, b, self);
    }

    static mrb_value
    n_ci(mrb_state *mrb, mrb_value self)
    {
      return mrb_int_value(mrb, mrb->c->ci->mid);
    }

    static mrb_value
    n_lib_frame(mrb_state *mrb, mrb_value self)
    {
      return mrb_int_value(mrb, lib_reads_frame(mrb));
    }

    static mrb_value
    n_via_alloc(mrb_state *mrb, mrb_value self)
    {
      return alloc_user(mrb);
    }

    static mrb_value
    n_alloc(mrb_state *mrb, mrb_value self)
    {
      mrb_full_gc(mrb);
      return self;
    }

    static mrb_value
    n_callback(mrb_state *mrb, mrb_value self, mrb_value (*cb)(mrb_state*, mrb_value))
    {
      return cb(mrb, self);
    }

    static mrb_value
    n_table(mrb_state *mrb, mrb_value self)
    {
      mrb_value (*pick)(mrb_state*, mrb_value) = mrb_int_p(self) ? helper_a : helper_b;
      return pick(mrb, self);
    }

    static mrb_value
    n_unassigned(mrb_state *mrb, mrb_value self)
    {
      mrb_value (*pick)(mrb_state*, mrb_value);
      return pick(mrb, self);
    }

    static mrb_value
    helper_a(mrb_state *mrb, mrb_value self)
    {
      return self;
    }

    static mrb_value
    helper_b(mrb_state *mrb, mrb_value self)
    {
      return mrb_block_given_p(mrb) ? self : mrb_nil_value();
    }

    void
    mrb_gem_init(mrb_state *mrb)
    {
      struct RClass *thing = mrb_define_class(mrb, "Thing", mrb->object_class);
      mrb_define_method(mrb, thing, "args", n_args, MRB_ARGS_REQ(1));
      mrb_define_method(mrb, thing, "raise_it", n_raise, MRB_ARGS_NONE());
      mrb_define_method(mrb, thing, "send_it", n_send, MRB_ARGS_NONE());
      mrb_define_method(mrb, thing, "plain", n_plain, MRB_ARGS_NONE());
      mrb_define_method(mrb, thing, "block", n_block, MRB_ARGS_NONE());
      mrb_define_method(mrb, mrb->array_class, "pick", n_table, MRB_ARGS_NONE());
      mrb_define_class_method(mrb, thing, "make", n_plain, MRB_ARGS_NONE());
    }
  C

  corpus = [File.join(lib_dir, 'lib.c'), File.join(lib_dir, 'gc.c'), gem]
  effects = NativeFrameUse.effects(NativeFrameUse.definitions(corpus))
  free = ->(name) { NativeFrameUse.frame_free?(effects.fetch(name)) }

  %w[helper_reads_args n_args n_raise n_send n_plain lib_reads_nothing helper_a n_alloc].each do |name|
    suite.check("#{name} is frame-free (#{effects.fetch(name).to_a.sort.join(',')})", free.call(name))
  end
  %w[n_block n_amp n_dynamic_format n_yield n_ci n_lib_frame n_via_alloc n_callback n_unassigned helper_b].each do |name|
    suite.check("#{name} is framed (#{effects.fetch(name).to_a.sort.join(',')})", !free.call(name))
  end
  suite.check('a pointer assigned only named functions reads their effects (n_table: helper_b reads the block)',
              !free.call('n_table'))
  suite.check('the collector walks every frame and is no read of the running one (n_alloc)', free.call('n_alloc'))

  rows = NativeFrameUse.rows([gem], corpus)
  suite.check('a plain define is attributed by its class variable', rows.include?(%w[Thing args n_args]))
  suite.check('a raise and a send are free rows', rows.include?(%w[Thing raise_it n_raise]) && rows.include?(%w[Thing send_it n_send]))
  suite.check('a class method is the owner\'s singleton', rows.include?(%w[Thing.singleton make n_plain]))
  suite.check('a framed native has no row', rows.none? { |_o, _n, f| f == 'n_block' || f == 'n_table' })
  suite.check('a function the corpus does not define has no row', NativeFrameUse.rows([gem], []).empty?)

  cxx = File.join(dir, 'gem.cxx')
  File.write(cxx, <<~CXX)
    #include <vector>
    #define HELPER(x) do { if (x) { mrb_raise(M, E_RUNTIME_ERROR, "{"); } } while (0)
    typedef void (*hook_fn)(const char*);
    hook_fn g_log_hook;
    void (*g_raw_hook)(int);
    namespace {
    struct Box {
      int f;
      Box() { mrb_full_gc(nullptr); }
      ~Box() {}
      int get() const { return f; }
    };
    struct CbBox {
      int (*cb)(int);
      int call_cb(int v) { return cb(v); }
    };
    struct Guard {
      mrb_state* M;
      ~Guard() { (void)M->c->ci; }
    };
    template <class F> int apply(F&& fn) { return fn(1); }
    int helper_b_like(int) { return 0; }
    mrb_value cx_args(mrb_state* M, mrb_value self) {
      mrb_int n;
      mrb_get_args(M, "i", &n);
      std::vector<int> v;
      v.push_back(1);
      return mrb_int_value(M, v.size() + n);
    }
    mrb_value cx_lambda(mrb_state* M, mrb_value self) {
      return mrb_int_value(M, apply([&](int x) { return x + 1; }));
    }
    mrb_value cx_lambda_block(mrb_state* M, mrb_value self) {
      return mrb_int_value(M, apply([&](int x) { return mrb_block_given_p(M) ? x : 0; }));
    }
    mrb_value cx_box(mrb_state* M, mrb_value self) {
      Box b;
      return mrb_int_value(M, b.get());
    }
    mrb_value cx_guard(mrb_state* M, mrb_value self) {
      Guard g{M};
      return self;
    }
    mrb_value cx_member_cb(mrb_state* M, mrb_value self) {
      CbBox b;
      return mrb_int_value(M, b.cb(2));
    }
    mrb_value cx_global_hook(mrb_state* M, mrb_value self) {
      if (g_log_hook) g_log_hook("x");
      return self;
    }
    mrb_value cx_store_hook(mrb_state* M, mrb_value self) {
      g_raw_hook = nullptr;
      return self;
    }
    mrb_value cx_catch(mrb_state* M, mrb_value self) {
      try { mrb_raise(M, E_RUNTIME_ERROR, "x"); } catch (...) {}
      return self;
    }
    mrb_value cx_callback_value(mrb_state* M, mrb_value self) {
      return mrb_int_value(M, apply(helper_b_like));
    }
    }  // namespace
    extern "C" void mrb_cx_gem_init(mrb_state* M) {
      RClass* k = mrb_define_class(M, "Cx", M->object_class);
      mrb_define_method(M, k, "args", cx_args, MRB_ARGS_REQ(1));
      mrb_define_method(M, k, "hook", cx_global_hook, MRB_ARGS_NONE());
      mrb_define_method(M, k, "inline", [](mrb_state* M, mrb_value self) { return self; }, MRB_ARGS_NONE());
    }
  CXX
  cxx_corpus = corpus + [cxx]
  cxx_effects = NativeFrameUse.effects(NativeFrameUse.definitions(cxx_corpus), NativeFrameUse.callable_names(cxx_corpus))
  cxx_free = ->(name) { cxx_effects.key?(name) && NativeFrameUse.frame_free?(cxx_effects.fetch(name)) }
  kinds = ->(name) { cxx_effects.fetch(name, Set[:undefined]).to_a.sort.join(',') }
  # A local of a class takes every member's effects (cpp_definitions): Box has no framed member, CbBox has call_cb.
  %w[cx_args cx_lambda cx_box cx_store_hook cx_callback_value].each do |name|
    suite.check("C++ #{name} is frame-free (#{kinds.call(name)})", cxx_free.call(name))
  end
  %w[cx_lambda_block cx_guard cx_member_cb cx_global_hook cx_catch].each do |name|
    suite.check("C++ #{name} is framed (#{kinds.call(name)})", !cxx_free.call(name))
  end
  suite.check('a member function reading a plain field is frame-free (Box#get)', cxx_free.call('get'))
  suite.check('a member function calling its own callable member is framed (CbBox#call_cb)', !cxx_free.call('call_cb'))
  suite.check('a brace inside a macro or a string opens no scope (cx_args is found)', cxx_effects.key?('cx_args'))
  cxx_rows = NativeFrameUse.rows([cxx], cxx_corpus)
  suite.check('a C++ plain define is a row', cxx_rows.include?(%w[Cx args cx_args]))
  suite.check('a native calling a global hook has no row', cxx_rows.none? { |_o, n, _f| n == 'hook' })
  suite.check('a lambda registered in place names no function and has no row', cxx_rows.none? { |_o, n, _f| n == 'inline' })

  source = NativeFrameUse.cpp_source(Set['IO#getbyte', 'Thing.singleton#make'])
  suite.check('the helper lists each row and installs the frame-free hook mrb_funcall_with_method consults',
              source.include?('{ "IO", "getbyte" }') && source.include?('{ "Thing.singleton", "make" }') &&
              source.include?('M->frame_free_p = bc2cpp_frame_free_hook'))
  suite.check('the found call defers the decision to mrb_funcall_with_method', !source.include?('mrb_call_direct('))
  owner, name, wrapper, = OwnerCallDirect::NATIVE_ROWS.first
  handed = NativeFrameUse.wrappers_source(Set["#{owner}##{name}"])
  suite.check('a frame-free row\'s owner-call wrapper is handed to the set', handed.include?("{ #{wrapper} }") &&
              NativeFrameUse.cpp_source(Set["#{owner}##{name}"]).include?('bc2cpp_ff_add(bc2cpp_ff_wrapper_fns[i])'))
  suite.check('a framed row\'s wrapper is not', NativeFrameUse.wrappers_source(Set['IO#getbyte']).empty?)
  compiled = [{ label: 'synth:Font#bold', entry: 'Font_bold', arity: 0 }, { label: 'synth:Font#bold=', entry: 'Font_bold_eq', arity: 1 },
              { label: 'Font#size', entry: 'Font_size', arity: 0 }]
  suite.check('FRAME_FREE_READERS: only a synthesized reader is handed over',
              NativeFrameUse.reader_entries(compiled) == ['Font_bold'])
  suite.check('FRAME_FREE_READERS: the readers go to the set with no frame-free wrapper row',
              NativeFrameUse.wrappers_source(Set['IO#getbyte'], ['Font_bold']).include?('{ Font_bold }'))
  chained = NativeFrameUse.cpp_source(Set['IO#getbyte'])
  suite.check('each gem\'s hook keeps the one installed before it',
              chained.include?('if (M->frame_free_p != bc2cpp_frame_free_hook) bc2cpp_ff_prev = M->frame_free_p;') &&
              chained.include?('return bc2cpp_frame_free_p(M, f) || (bc2cpp_ff_prev && bc2cpp_ff_prev(M, f));'))
  suite.check('without rows no hook is installed', !NativeFrameUse.cpp_source(Set.new).include?('frame_free_p'))
  ENV['BC2CPP_FRAMEFREE'] = '0'
  suite.check('BC2CPP_FRAMEFREE=0 turns the rewrite off', !NativeFrameUse.cpp_source(Set['IO#getbyte']).include?('frame_free_p'))
  ENV.delete('BC2CPP_FRAMEFREE')
end

suite.finish!
