#!/usr/bin/env ruby
# frozen_string_literal: true

# Check SYM_CALL_CHAIN (codegen_loop_inline.rb sym_call_chain): the per-element call of an inlined `&:sym` loop is
# the ordinary send of `sym` to a receiver of unknown class, an exact-class chain with the closed-world else, where
# SYM_DEVIRT alone has no target (more definitions than its cap).
#
#   1. generated code: `map(&:tag)` over six definers is a SYM_CALL_CHAIN with a direct arm per definer and no
#      mrb_funcall; the private definer gets its arm too (Symbol#to_proc sends with __send__ semantics); the chain is
#      indented past the loop's closing brace and its owner call, if any, is level 0;
#   2. covered_block_sites reads the loop as covered, a proven nomethod in it included;
#   3. run on a full-core mruby, compiled against interpreted: map/select/reject/count/find/each over every definer,
#      a private definer, a subclass, and an element that answers nothing give the same value or error.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/sym_call_chain_check.rb
# The run needs a full-core libmruby built from this tree's patched 3rd/mruby (BC2CPP_MRUBY_FULL, or one built here).

require 'tmpdir'
require_relative 'fixture_runtime'
require_relative '../../tools/bc2cpp/static_dispatch_registrations'

ENV['BC2CPP_SIG_DIRS'] ||= ''
runtime = Bc2cppFixtureRuntime
failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end
abort 'SKIP: set MRBC' unless ENV['MRBC']

SOURCE = <<~RUBY
  class SymA; def tag; :a; end; end
  class SymB; def tag; :b; end; end
  class SymC; def tag; nil; end; end
  class SymD; def tag; false; end; end
  class SymE
    def initialize; @n = 0; end
    def tag; @n += 1; @n; end
  end
  class SymF
    def tag; :f; end
    private :tag
  end
  class SymA2 < SymA; end
  class SymNone; end
  class SymProbe
    def mp(a); a.map(&:tag); end
    def sl(a); a.select(&:tag).map { |x| x.class }; end
    def rj(a); a.reject(&:tag).map { |x| x.class }; end
    def ct(a); a.count(&:tag); end
    def fd(a); x = a.find(&:tag); x && x.class; end
    def ea(a); a.each(&:tag).size; end
  end
RUBY
OWNERS = %w[SymA SymB SymC SymD SymE SymF SymA2 SymNone SymProbe].freeze

body = ->(code, name) { code[/^mrb_value SymProbe_#{name}_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s }

Dir.mktmpdir('sym-call-chain') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS, core: true)
  File.write(File.join(ENV['BC2CPP_KEEP_DIR'], 'sym_call_chain.cxx'), code) if ENV['BC2CPP_KEEP_DIR']
  mp = body.call(code, 'mp')
  check.call('map(&:tag): inlined loop', mp.include?('inlined &:tag'))
  check.call('map(&:tag): SYM_CALL_CHAIN', mp.include?('// SYM_CALL_CHAIN &:tag'))
  %w[SymA SymB SymC SymD SymE SymF].each do |owner|
    check.call("map(&:tag): direct arm for #{owner}", mp.include?("#{owner}_tag_impl(M, bc2cpp_sym_e_"))
  end
  check.call('map(&:tag): no by-name send per element', !mp.match?(/mrb_funcall\(M, bc2cpp_sym_e_/))
  check.call('map(&:tag): any owner call in the chain is level 0',
             mp.scan(/bc2cpp_owner_call(?:_named)?\(M, bc2cpp_sym_e_\w+, (?:"tag"|\d+), (\d+)/).flatten.all?('0'))
  loop_lines = mp[%r{// SYM_SITE .*?^    \}$}m].to_s.lines
  check.call('map(&:tag): the chain is indented past the loop brace',
             loop_lines.any? { |l| l.include?('SYM_CALL_CHAIN') } && loop_lines[0..-2].none? { |l| l.match?(/\A    \}\s*\z/) })
  ea = body.call(code, 'ea')
  check.call('each(&:tag): SYM_CALL_CHAIN, result discarded', ea.include?('// SYM_CALL_CHAIN &:tag'))

  # The proof's reading: a loop whose body holds only the chain's direct arms and a proven nomethod is covered.
  covered_src = <<~CPP
    // SYM_SITE irep1 7
    for (;;) {
      {
        if (bc2cpp_class_is(M, e, bc2cpp_owner_class_1(M))) {
          r9 = SymA_tag_impl(M, e);
        } else {
          BC2CPP_COLD_ARM r9 = bc2cpp_nomethod(M, e, 3); /* CLOSED_WORLD nomethod: recv.tag */
        }
      }
    }
  CPP
  sdr = StaticDispatchRegistrations
  check.call('covered_block_sites: a proven nomethod is no by-name call',
             sdr.covered_block_sites([covered_src], Set.new)[['irep1', 7]] == 1)
  check.call('covered_block_sites: a by-name send still is',
             sdr.covered_block_sites([covered_src.sub('bc2cpp_nomethod(M, e, 3)', 'mrb_funcall(M, e, "tag", 0)')], Set.new).empty?)

  harness = <<~CPP
    #include <cstdio>
    #include <string>
    struct Call { mrb_value obj; mrb_sym mid; mrb_value arg; };
    static mrb_value call_body(mrb_state* M, void* ud) {
      Call* c = (Call*)ud;
      return mrb_funcall_argv(M, c->obj, c->mid, 1, &c->arg);
    }
    static void row(mrb_state* M, const char* label, const char* meth, mrb_value arg) {
      mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "SymProbe"), 0, nullptr);
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
      std::printf("%s %s => %s\\n", meth, label, out.c_str());
    }
    static mrb_value eval(mrb_state* M, const char* src) { return mrb_load_string(M, src); }
    static int scenario(mrb_state* M) {
      const char* lists[] = {
        "[SymA.new, SymB.new, SymC.new, SymD.new, SymE.new, SymA2.new]",
        "[SymF.new, SymA.new]",
        "[SymC.new, SymD.new]",
        "[SymA.new, SymNone.new]",
        "[SymNone.new]",
        "[]",
        "[SymE.new, SymE.new]",
      };
      const char* meths[] = {"mp", "sl", "rj", "ct", "fd", "ea"};
      for (const char* m : meths) {
        for (const char* l : lists) row(M, l, m, eval(M, l));
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
    check.call('a private definer answers (__send__ semantics)', compiled.any? { |l| l.start_with?('mp [SymF.new') && l.include?('[:f, :a]') })
    check.call('an element answering nothing raises NoMethodError', compiled.any? { |l| l.start_with?('mp [SymNone.new]') && l.include?('NoMethodError') })
    warn output unless failures.empty?
  else
    puts '  SKIP run: no full-core mruby build'
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp sym call chain check: PASS'
