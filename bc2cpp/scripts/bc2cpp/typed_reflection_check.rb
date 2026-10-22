#!/usr/bin/env ruby
# frozen_string_literal: true

# Typed embedded ivars and reflection. A typed slot (mrb_int,
# mrb_sym, mrb_bool, Integer-or-nil) is a raw C field of the RData payload.
# The RData ivar descriptor used to list boxed slots only, so a typed ivar was
# invisible to instance_variable_get/set, instance_variables, inspect, Marshal
# and dup: a read gave nil, a write went to a table nothing read. The
# descriptor now lists every slot with its kind, and the runtime (the
# mruby-rdata-ivar-slots change in the pinned 3rd/mruby fork) boxes on read and
# type-checks on write.
#
# A typed slot is also zeroed, so an ivar some path reads before #initialize
# assigns it would read 0/false where an unset ivar reads nil; such an ivar
# stays a boxed slot (ivar_assigned_before_exposure?).
#
# 1. Host only: the kind table covers every slot type, the pinned mruby declares the
#    same enumerators, and the generated descriptor lists typed slots.
# 2. With MRBC, BC2CPP_MRUBY_CORE and g++: a fixture runs against the patched
#    mruby through the C ivar API, interpreted and compiled.
#
# Usage: [MRBC=path/to/mrbc BC2CPP_MRUBY_CORE=dir] ruby scripts/bc2cpp/typed_reflection_check.rb

require 'tmpdir'
require_relative '../../tools/bc2cpp/codegen'
require_relative '../../tools/bc2cpp/codegen_emit'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

ROOT = File.expand_path('../..', __dir__)

puts '-- kinds (host)'
mruby = File.join(ROOT, '3rd/mruby')
patch = File.read(File.join(mruby, 'include/mruby/data.h')) + File.read(File.join(mruby, 'src/gc.c'))
check.call('every slot type has a descriptor kind', CodeGen::TYPE_OPS.keys.sort == CodeGen::RDATA_IVAR_KIND.keys.sort)
check.call('the pinned mruby declares each kind the generator names',
           CodeGen::RDATA_IVAR_KIND.values.all? { |kind| patch.include?("  #{kind}") })
check.call('the value kind is the zero of the enum, so a two-field descriptor entry stays boxed',
           patch.include?('  MRB_DATA_IVAR_VALUE = 0,'))
check.call('the patch lays out the int-or-nil slot as the generator does',
           patch.include?('struct mrb_data_int_or_nil {') && patch.include?('  mrb_bool present;') &&
             patch.include?('  mrb_int value;'))
check.call('the pinned mruby tells the GC to skip typed slots', patch.include?('!= MRB_DATA_IVAR_VALUE) continue;'))

if ENV['MRBC']
  require_relative 'fixture_runtime'
  runtime = Bc2cppFixtureRuntime

  FIXTURE = <<~RUBY
    class TrMixed
      def initialize
        @count = 0
        @tag = :a
        @on = true
        @opt = nil
        @name = "n"
      end

      def bump; @count = 1; end
      def retag; @tag = :b; end
      def toggle; @on = false; end
      def arm; @opt = 5; end
      def label; "\#{@name}\#{@count}\#{@tag}\#{@on}\#{@opt.inspect}"; end
    end

    class TrLate
      def initialize; @a = 1; end
      def read; @b; end
      def write; @b = 7; end
    end
  RUBY

  puts '-- generated descriptor'
  Dir.mktmpdir do |dir|
    code, = runtime.generate(FIXTURE, dir)
    slots = code[/TrMixed_ivar_slots\[\] = \{\n(.*?)\n\};/m, 1].to_s
    {
      'count' => 'MRB_DATA_IVAR_INT', 'tag' => 'MRB_DATA_IVAR_SYMBOL', 'on' => 'MRB_DATA_IVAR_BOOL',
      'opt' => 'MRB_DATA_IVAR_INT_OR_NIL', 'name' => 'MRB_DATA_IVAR_VALUE'
    }.each do |name, kind|
      check.call("@#{name} is listed with #{kind}",
                 slots.include?("{ \"@#{name}\", offsetof(TrMixed_ivars, ivar_#{name}), #{kind} }"))
    end
    check.call('the descriptor count and index cover all five', code.include?('TrMixed_ivar_slots, 5, sizeof(TrMixed_ivars), TrMixed_ivar_hash, 15 };') ||
                                                                 code.match?(/TrMixed_ivar_slots, 5, sizeof\(TrMixed_ivars\), TrMixed_ivar_hash, \d+ \};/))
    fields = code[/struct TrLate_ivars \{\n(.*?)\n\};/m, 1].to_s
    check.call('an ivar assigned outside #initialize is a boxed slot (an unset read is nil)',
               fields.include?('mrb_value ivar_b;') && fields.include?('mrb_int ivar_a;'))
  end

  core = runtime.core
  if core.nil? || !runtime.compiler?
    puts '  SKIP run: set BC2CPP_MRUBY_CORE (libmruby_core.a of the patched 3rd/mruby) and have g++'
  else
    puts '-- reflection through the ivar API, interpreted and compiled'
    Dir.mktmpdir do |dir|
      _code, err = runtime.generate(FIXTURE, dir)
      body = <<~CPP
        static mrb_sym iv(mrb_state* M, const char* n) { return mrb_intern_cstr(M, n); }
        static int collect_name(mrb_state* M, mrb_sym sym, mrb_value, void* p) {
          mrb_int len;
          const char* s = mrb_sym_name_len(M, sym, &len);
          static_cast<std::vector<std::string>*>(p)->emplace_back(s, len);
          return 0;
        }
        static void names(mrb_state* M, const char* label, mrb_value obj) {
          std::vector<std::string> out;
          mrb_iv_foreach(M, obj, collect_name, &out);
          std::sort(out.begin(), out.end());
          std::string line;
          for (auto& n : out) line += n + " ";
          std::printf("%s => %s\\n", label, line.c_str());
        }
        static void get(mrb_state* M, const char* label, mrb_value obj, const char* name) {
          show(M, label, mrb_iv_get(M, obj, iv(M, name)));
        }
        struct Store { mrb_value obj; mrb_sym sym; mrb_value v; bool remove; };
        static mrb_value do_store(mrb_state* M, void* p) {
          Store* a = static_cast<Store*>(p);
          if (a->remove) mrb_iv_remove(M, a->obj, a->sym); else mrb_iv_set(M, a->obj, a->sym, a->v);
          return mrb_nil_value();
        }
        // The raise is a C++ exception here, so it goes through mrb_protect_error.
        static void try_store(mrb_state* M, const char* label, mrb_value obj, const char* name, mrb_value v,
                              bool remove = false) {
          Store store = { obj, iv(M, name), v, remove };
          mrb_bool error = FALSE;
          mrb_value ex = mrb_protect_error(M, do_store, &store, &error);
          if (error) std::printf("%s => raised %s\\n", label, mrb_obj_classname(M, ex));
          else std::printf("%s => %s\\n", label, remove ? "removed" : "stored");
        }
        static int scenario(mrb_state* M) {
          mrb_value o = mrb_obj_new(M, mrb_class_get(M, "TrMixed"), 0, nullptr);
          get(M, "count at start", o, "@count");
          get(M, "tag at start", o, "@tag");
          get(M, "on at start", o, "@on");
          get(M, "opt at start", o, "@opt");
          get(M, "name at start", o, "@name");
          names(M, "instance_variables", o);
          call(M, "bump", o, "bump");
          call(M, "bump again", o, "bump");
          call(M, "retag", o, "retag");
          call(M, "toggle", o, "toggle");
          call(M, "arm", o, "arm");
          get(M, "count after bump", o, "@count");
          get(M, "tag after retag", o, "@tag");
          get(M, "on after toggle", o, "@on");
          get(M, "opt after arm", o, "@opt");
          std::printf("count defined => %d\\n", (int)mrb_iv_defined(M, o, iv(M, "@count")));
          std::printf("missing defined => %d\\n", (int)mrb_iv_defined(M, o, iv(M, "@missing")));
          // A write through the API is what the compiled code reads next.
          mrb_iv_set(M, o, iv(M, "@count"), mrb_fixnum_value(40));
          mrb_iv_set(M, o, iv(M, "@tag"), mrb_symbol_value(mrb_intern_lit(M, "z")));
          mrb_iv_set(M, o, iv(M, "@on"), mrb_true_value());
          mrb_iv_set(M, o, iv(M, "@opt"), mrb_nil_value());
          call(M, "label after API writes", o, "label");
          // dup keeps the typed fields and does not share them.
          mrb_value copy = mrb_obj_dup(M, o);
          get(M, "dup count", copy, "@count");
          call(M, "bump the original", o, "bump");
          get(M, "dup count after the original moved", copy, "@count");
          get(M, "original count", o, "@count");
          names(M, "dup instance_variables", copy);
          if (compiled) {
            // The payload is typed: another class is refused, as the compiled SETIV refuses it.
            try_store(M, "typed: count = String", o, "@count", mrb_str_new_lit(M, "x"));
            try_store(M, "typed: opt = String", o, "@opt", mrb_str_new_lit(M, "x"));
            try_store(M, "typed: on = 1", o, "@on", mrb_fixnum_value(1));
            get(M, "typed: count unchanged", o, "@count");
            try_store(M, "typed: remove count", o, "@count", mrb_nil_value(), true);
            try_store(M, "boxed: name = Integer", o, "@name", mrb_fixnum_value(3));
          }
          // A name that is not a slot goes to the ordinary table.
          mrb_iv_set(M, o, iv(M, "@dynamic"), mrb_fixnum_value(9));
          get(M, "dynamic", o, "@dynamic");
          names(M, "instance_variables with a dynamic name", o);
          // An unset ivar reads nil, typed or not.
          mrb_value late = mrb_obj_new(M, mrb_class_get(M, "TrLate"), 0, nullptr);
          call(M, "late before write", late, "read");
          call(M, "late write", late, "write");
          call(M, "late after write", late, "read");
          // The GC skips typed slots and keeps the boxed ones.
          mrb_value keep = mrb_ary_new(M);
          int arena = mrb_gc_arena_save(M);
          for (int i = 0; i < 3000; ++i) {
            mrb_value t = mrb_obj_new(M, mrb_class_get(M, "TrMixed"), 0, nullptr);
            mrb_iv_set(M, t, iv(M, "@name"), mrb_str_new_lit(M, "kept"));
            if (i % 100 == 0) mrb_ary_push(M, keep, t);
            mrb_gc_arena_restore(M, arena);
            if (i % 500 == 0) mrb_full_gc(M);
          }
          mrb_full_gc(M);
          show(M, "survivor name", mrb_iv_get(M, RARRAY_PTR(keep)[7], iv(M, "@name")));
          std::printf("survivors => %d\\n", (int)RARRAY_LEN(keep));
          return 0;
        }
      CPP
      body = "#include <algorithm>\n#include <string>\n#{body}"
      built, output = runtime.run(dir, err, %w[TrMixed TrLate], body, build: core)
      check.call('the fixture compiles and runs against the patched mruby', built)
      puts output unless built
      if built
        puts output if ENV['BC2CPP_CHECK_VERBOSE']
        sections = runtime.sections(output)
        interpreted = sections.fetch('interpreted', []).reject { |l| l.start_with?('  ') }
        compiled = sections.fetch('compiled', []).reject { |l| l.start_with?('  ') || l.start_with?('typed:') || l.start_with?('boxed:') }
        check.call('a typed ivar reads, writes, lists, dups and survives GC as the interpreter does',
                   !interpreted.empty? && interpreted == compiled)
        typed = sections.fetch('compiled', []).select { |l| l.start_with?('typed:') || l.start_with?('boxed:') }
        check.call('a typed slot refuses another class and cannot be removed',
                   typed == ['typed: count = String => raised TypeError', 'typed: opt = String => raised TypeError',
                             'typed: on = 1 => raised TypeError', 'typed: count unchanged => 1',
                             'typed: remove count => raised TypeError', 'boxed: name = Integer => stored'])
        check.call('the compiled code sees the instance_variables the interpreter sees',
                   compiled.include?('instance_variables => @count @name @on @opt @tag '))
      end
    end
  end
end

if failures.empty?
  puts 'bc2cpp typed reflection check: PASS'
else
  warn "bc2cpp typed reflection check: #{failures.size} failure(s)"
  exit 1
end
