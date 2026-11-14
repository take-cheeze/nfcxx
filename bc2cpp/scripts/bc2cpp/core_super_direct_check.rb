#!/usr/bin/env ruby
# frozen_string_literal: true

# Check MODULE_SUPER_SUPPORT on mruby's own core bodies: `Range#max` / `Range#min` (mruby-range-ext) call
# `super(&block)`, which reaches the compiled core `Enumerable#max` / `#min`. Their definition is a registry entry that
# block_core_index lists too; module_super_lookup counts it once, so the `super` is a direct `_impl` call.
#
#   1. generated code: Range_max_impl and Range_min_impl call Enumerable_max_impl / Enumerable_min_impl with the
#      frame's block, and neither looks the method up (no bc2cpp_super_call);
#   2. run on a full-core mruby, compiled against interpreted: max and min with a block over Ranges (empty, of
#      Strings, a block that raises) give the same value or error.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/core_super_direct_check.rb
# The run needs a full-core libmruby built from this tree's patched 3rd/mruby (BC2CPP_MRUBY_FULL, or one built here).

require 'tmpdir'
require_relative 'fixture_runtime'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
abort 'SKIP: set MRBC' unless ENV['MRBC']

SOURCE = <<~RUBY
  class Probe
    def mx(r); r.max { |a, b| b <=> a }; end
    def mn(r); r.min { |a, b| b <=> a }; end
    def bad(r); r.max { |_a, _b| raise ArgumentError, 'from the block' }; end
  end
RUBY
OWNERS = %w[Probe].freeze

body = ->(code, name) { code[/^mrb_value #{name}_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }

Dir.mktmpdir('core-super-direct') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS, core: true)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'core_super_direct.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  { 'Range_max' => 'Enumerable_max', 'Range_min' => 'Enumerable_min' }.each do |caller, target|
    text = body.call(code, caller)
    check.call("#{caller}: super calls #{target}_impl with the frame's block",
               text.match?(/r\d+ = #{target}_impl\(M, self, bc2cpp_blk\);/))
    check.call("#{caller}: no super lookup", !text.empty? && !text.include?('bc2cpp_super_call('))
  end

  harness = <<~CPP
    #include <cstdio>
    #include <string>
    struct Call { mrb_value obj; mrb_sym mid; mrb_value arg; };
    static mrb_value call_body(mrb_state* M, void* ud) {
      Call* c = (Call*)ud;
      return mrb_funcall_argv(M, c->obj, c->mid, 1, &c->arg);
    }
    static void row(mrb_state* M, const char* label, const char* meth, mrb_value arg) {
      mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
      Call c = { probe, mrb_intern_cstr(M, meth), arg };
      mrb_bool raised = FALSE;
      mrb_value v = mrb_protect_error(M, call_body, &c, &raised);
      std::string out;
      if (raised) {
        mrb_value msg = mrb_funcall(M, v, "message", 0);
        out = std::string("raised ") + mrb_obj_classname(M, v) + ": " + std::string(RSTRING_PTR(msg), RSTRING_LEN(msg));
      } else {
        mrb_value s = mrb_inspect(M, v);
        out = std::string(RSTRING_PTR(s), RSTRING_LEN(s));
      }
      std::printf("%s => %s\\n", label, out.c_str());
    }
    static int scenario(mrb_state* M) {
      const char* rs[] = {"(1..5)", "(1...5)", "(3..1)", "('a'..'e')"};
      for (const char* e : rs) {
        for (const char* m : {"mx", "mn", "bad"}) {
          row(M, (std::string(m) + " " + e).c_str(), m, mrb_load_string(M, e));
        }
      }
      return 0;
    }
  CPP
  build = runtime.full_or_build
  if build
    built, output = runtime.run(dir, err, OWNERS, harness, build: build, full: true)
    sections = runtime.sections(output)
    compiled = sections['compiled'].to_a
    interpreted = sections['interpreted'].to_a
    check.call('built and ran', built)
    check.call('runtime parity (every row)', !compiled.empty? && compiled == interpreted)
    check.call('max with a reversed block is the minimum', compiled.include?('mx (1..5) => 1'))
    warn output unless failures.empty?
  else
    puts '  SKIP run: no full-core mruby build'
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp core super direct check: PASS'
