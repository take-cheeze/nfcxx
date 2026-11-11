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

  source = NativeFrameUse.cpp_source(Set['IO#getbyte', 'Thing.singleton#make'])
  suite.check('the helper lists each row and calls mrb_call_direct for a member',
              source.include?('{ "IO", "getbyte" }') && source.include?('{ "Thing.singleton", "make" }') &&
              source.include?('mrb_call_direct('))
  suite.check('without rows the helper is the plain call', !NativeFrameUse.cpp_source(Set.new).include?('mrb_call_direct'))
  ENV['BC2CPP_FRAMEFREE'] = '0'
  suite.check('BC2CPP_FRAMEFREE=0 turns the rewrite off', !NativeFrameUse.cpp_source(Set['IO#getbyte']).include?('mrb_call_direct'))
  ENV.delete('BC2CPP_FRAMEFREE')
end

suite.finish!
