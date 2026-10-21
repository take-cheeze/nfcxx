#!/usr/bin/env ruby
# frozen_string_literal: true

# Checks tools/bc2cpp/native_ast_returns.rb: the return kind of each function in a small C++ fixture, from the clang AST
# (`clang -fsyntax-only -Xclang -ast-dump=json`). Covers a constructor, `self` (also through a copy), a local, a
# conditional, a join of two kinds, a call to a function in the same file, a recursive cycle, and an identity call
# (mrb_obj_freeze returns its value), and a string guard that narrows a local to String only where
# no later statement reassigns it. Skips when clang is
# not installed.
#
#   ruby scripts/bc2cpp/native_ast_returns_check.rb

require 'json'
require 'open3'
require 'tmpdir'
require_relative '../../tools/bc2cpp/native_ast_returns'

unless system('clang --version', out: File::NULL, err: File::NULL)
  puts 'SKIP native_ast_returns_check: clang is not installed'
  exit 0
end

FIXTURE = <<~CPP
  struct mrb_value { int v; };
  mrb_value mrb_fixnum_value(int);
  mrb_value mrb_nil_value();
  mrb_value mrb_ary_new(int);
  bool test(int);

  mrb_value int_fn(mrb_value self) { return mrb_fixnum_value(1); }
  mrb_value self_fn(mrb_value self) { return self; }
  mrb_value local_fn(mrb_value self) { mrb_value r = mrb_ary_new(0); return r; }
  mrb_value cond_fn(mrb_value self, int c) { return c ? mrb_fixnum_value(1) : mrb_fixnum_value(2); }
  mrb_value mixed_fn(mrb_value self, int c) { return c ? mrb_fixnum_value(1) : mrb_nil_value(); }
  mrb_value call_fn(mrb_value self) { return int_fn(self); }
  mrb_value rec_fn(mrb_value self) { return rec_fn(self); }
  struct mrb_state;
  mrb_value mrb_obj_freeze(struct mrb_state *mrb, mrb_value self);
  mrb_value mrb_str_new(struct mrb_state *mrb, const char *p, int len);
  enum { MRB_TT_STRING = 7 };
  mrb_value get_thing(struct mrb_state *mrb);
  mrb_value mrb_str_new_cstr(struct mrb_state *mrb, const char *s);
  mrb_value guard_fn(struct mrb_state *mrb, mrb_value self) { mrb_value m = get_thing(mrb); if (!(m.v == MRB_TT_STRING)) { return mrb_str_new_cstr(mrb, 0); } return m; }
  mrb_value guard_late_fn(struct mrb_state *mrb, mrb_value self) { mrb_value m = get_thing(mrb); if (!(m.v == MRB_TT_STRING)) { return mrb_str_new_cstr(mrb, 0); } m = get_thing(mrb); return m; }
  mrb_value pre_fn(struct mrb_state *mrb, mrb_value self) { mrb_value m = get_thing(mrb); if (m.v == 1) { return m; } if (!(m.v == MRB_TT_STRING)) { return mrb_str_new_cstr(mrb, 0); } return m; }
  mrb_value class_name_str(struct mrb_state *mrb, mrb_value c);
  mrb_value named_fn(struct mrb_state *mrb, mrb_value self) { return class_name_str(mrb, self); }
  struct mrb_class;
  struct mrb_state { struct mrb_class *string_class; };
  struct mrb_class *mrb_obj_class_of(struct mrb_state *mrb, mrb_value v);
  mrb_value mrb_str_dup(struct mrb_state *mrb, mrb_value v);
  mrb_value self_str_fn(struct mrb_state *mrb, mrb_value self) { if (mrb_obj_class_of(mrb, self) != mrb->string_class) { return mrb_str_dup(mrb, self); } return self; }
  mrb_value frozen_fn(struct mrb_state *mrb, mrb_value self) { return mrb_obj_freeze(mrb, mrb_str_new(mrb, 0, 0)); }
CPP

EXPECTED = {
  'int_fn' => 'Integer', 'self_fn' => 'self', 'local_fn' => 'Array', 'cond_fn' => 'Integer',
  'mixed_fn' => nil, 'call_fn' => 'Integer', 'rec_fn' => nil, 'frozen_fn' => 'String',
  'guard_fn' => 'String', 'guard_late_fn' => nil, 'pre_fn' => nil, 'named_fn' => 'String', 'self_str_fn' => 'String'
}.freeze

failures = []
Dir.mktmpdir('native_ast_returns_check') do |dir|
  source = File.join(dir, 'fixture.cxx')
  File.write(source, FIXTURE)
  ast, err, status = Open3.capture3('clang', '-fsyntax-only', '-Xclang', '-ast-dump=json', '-x', 'c++', source)
  abort "clang failed: #{err}" unless status.success?

  kinds = NativeAstReturns.analyze(JSON.parse(ast), source)
  EXPECTED.each do |fn, want|
    got = kinds[fn]
    failures << "#{fn}: expected #{want.inspect}, got #{got.inspect}" unless got == want
  end
  failures << "functions found #{kinds.keys.sort.inspect}, expected #{EXPECTED.keys.sort.inspect}" unless kinds.keys.sort == EXPECTED.keys.sort
end

if failures.empty?
  puts "native AST returns check: #{EXPECTED.size} functions classified"
else
  failures.each { |failure| warn "  #{failure}" }
  abort "native AST returns check: #{failures.size} failure(s)"
end
