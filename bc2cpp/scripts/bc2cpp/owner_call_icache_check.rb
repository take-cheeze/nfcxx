#!/usr/bin/env ruby
# frozen_string_literal: true

# OWNER_CALL_ICACHE (tools/bc2cpp/symbol_cache.rb): an owner call keeps its last checked (class, argc) -> method
# and reuses it only while mruby's own method cache holds the same entry.
#
#   1. generated code: the owner-call helper carries the per-site slot, and BC2CPP_OWNER_ICACHE=0 compiles it out;
#   2. run on a full-core mruby, compiled against interpreted, with -DBC2CPP_OWNER_ICACHE_STATS:
#      - repeated calls with one receiver class hit the slot (the hit counter grows), and give the same values;
#      - after a Ruby redefinition of Array#pack, the new body answers (no stale hit);
#      - visibility made private after hits raises NoMethodError, as interpreted;
#      - a singleton `def obj.pack` and a module prepended to a subclass are definers the closed world does not
#        list: the compiled run raises the owner violation (no stale hit to the old Array#pack);
#      - classes created and collected in a loop (GC between) answer as interpreted;
#      - the same rows with -DBC2CPP_NO_OWNER_ICACHE: no hit, same values.
#
# Usage: MRBC=path/to/host/mrbc [BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/owner_call_icache_check.rb

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
    def pk(o, f); o.pack(f); end
    def pk_loop(o, f, n)
      i = 0
      r = nil
      while i < n
        r = o.pack(f)
        i += 1
      end
      r
    end
  end
RUBY
OWNERS = %w[Probe].freeze

HARNESS = <<~'CPP'
  #include <string>
  struct Call { mrb_value obj; mrb_sym mid; mrb_int argc; mrb_value argv[2]; };
  static mrb_value call_body(mrb_state* M, void* ud) {
    Call* c = (Call*)ud;
    return mrb_funcall_argv(M, c->obj, c->mid, c->argc, c->argv);
  }
  static unsigned long hits_now() {
  #ifdef BC2CPP_OWNER_ICACHE_STATS
    return bc2cpp_owner_icache_hits;
  #else
    return 0;
  #endif
  }
  static void row(mrb_state* M, const char* label, mrb_value recv) {
    mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
    Call c = { probe, mrb_intern_lit(M, "pk"), 2, { recv, mrb_str_new_lit(M, "C*") } };
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
    std::printf("%s => %s\n", label, out.c_str());
  }
  static mrb_value eval(mrb_state* M, const char* src) { return mrb_load_string(M, src); }
  static int scenario(mrb_state* M) {
    unsigned long before = hits_now();
    mrb_value ary = eval(M, "[65, 66]");
    mrb_value probe = mrb_obj_new(M, mrb_class_get(M, "Probe"), 0, nullptr);
    mrb_value loop_args[] = { ary, mrb_str_new_lit(M, "C*"), mrb_int_value(M, 50) };
    call(M, "array.pack x50", probe, "pk_loop", 3, loop_args);
    if (compiled) std::printf("STAT repeat_hits=%lu\n", hits_now() - before);
    row(M, "array.pack", ary);
    row(M, "string.pack (other class)", eval(M, "'ab'"));
    row(M, "array.pack again", eval(M, "[67]"));
    for (int round = 0; round < 20; ++round) {
      eval(M, "$k = Class.new(Array); $o = $k.new; $o << 68");
      row(M, "fresh subclass", eval(M, "$o"));
      eval(M, "$k = nil; $o = nil");
      mrb_full_gc(M);
    }
    eval(M, "class Array; def pack(f) = [:redefined, f]; end");
    row(M, "array.pack after redefinition", eval(M, "[65]"));
    eval(M, "class Array; private :pack; end");
    row(M, "array.pack made private", eval(M, "[65]"));
    eval(M, "class Array; public :pack; end");
    row(M, "array.pack public again", eval(M, "[65]"));
    row(M, "rogue singleton", eval(M, "$s = [65]; def $s.pack(f) = :single; $s"));
    row(M, "rogue warm subclass", eval(M, "class SubArr < Array; end; SubArr.new([65])"));
    row(M, "rogue warm subclass", eval(M, "SubArr.new([65])"));
    row(M, "rogue prepended", eval(M, "SubArr.prepend(Module.new { def pack(f) = :prepended }); SubArr.new([65])"));
    return 0;
  }
CPP

Dir.mktmpdir('owner-call-icache') do |dir|
  code, err = runtime.generate(SOURCE, dir, only_owners: OWNERS)
  pk = code[/^mrb_value Probe_pk_impl\(mrb_state\* M[^\n]*\{\n.*?(?=^(?:static )?mrb_value \w+\(mrb_state\* M|\z)/m].to_s
  check.call('pack is an owner call', pk.include?('bc2cpp_owner_call(M, '))
  check.call('the helper keeps a per-site slot', code.include?('bc2cpp_owner_icache_hit(M, s, klass, mid, argc)') &&
                                                    code.include?('s.hit_klass = klass;'))
  check.call('the slot is checked against mruby\'s method cache', code.include?('M->cache[h]'))
  begin
    ENV['BC2CPP_OWNER_ICACHE'] = '0'
    off, = runtime.generate(SOURCE, File.join(dir, 'off').tap { |d| FileUtils.mkdir_p(d) }, only_owners: OWNERS)
    check.call('BC2CPP_OWNER_ICACHE=0 compiles the slot out', off.include?('#define BC2CPP_NO_OWNER_ICACHE 1'))
  ensure
    ENV.delete('BC2CPP_OWNER_ICACHE')
  end

  build = runtime.full_or_build
  if build
    results = {}
    { on: '-DBC2CPP_OWNER_ICACHE_STATS', off: '-DBC2CPP_OWNER_ICACHE_STATS -DBC2CPP_NO_OWNER_ICACHE' }.each do |mode, flags|
      saved = ENV['BC2CPP_CXXFLAGS']
      ENV['BC2CPP_CXXFLAGS'] = [saved, flags].compact.join(' ')
      runtime.generate(SOURCE, dir, only_owners: OWNERS)
      results[mode] = runtime.run(dir, err, OWNERS, HARNESS, build: build, full: true)
    ensure
      ENV['BC2CPP_CXXFLAGS'] = saved
    end
    results.each do |mode, (built, output)|
      sections = runtime.sections(output)
      compiled = sections['compiled'].to_a
      interpreted = sections['interpreted'].to_a
      stat = compiled.find { |l| l.start_with?('STAT ') }.to_s[/repeat_hits=(\d+)/, 1].to_i
      rogue = ->(lines) { lines.select { |l| l.start_with?('rogue') && !l.include?('warm') } }
      plain = ->(lines) { lines.reject { |l| l.start_with?('rogue', 'STAT', '  dispatches') } }
      check.call("#{mode}: built and ran", built)
      check.call("#{mode}: runtime parity (every non-rogue row)", !compiled.empty? && plain.call(compiled) == plain.call(interpreted))
      check.call("#{mode}: redefinition answers the new body", compiled.any? { |l| l.include?('after redefinition => [:redefined') })
      check.call("#{mode}: private after hits raises NoMethodError", compiled.any? { |l| l.include?('made private => raised NoMethodError') })
      check.call("#{mode}: interpreted rogue definers run", rogue.call(interpreted).all? { |l| l.match?(/:single|:prepended/) })
      check.call("#{mode}: compiled rogue definers are owner violations",
                 rogue.call(compiled).size == 2 && rogue.call(compiled).all? { |l| l.include?('closed-world owner violation') })
      check.call(mode == :on ? 'on: repeated calls hit the slot' : 'off: no hits', mode == :on ? stat >= 45 : stat.zero?)
      warn output unless failures.empty?
    end
  else
    puts '  SKIP run: no full-core mruby build'
  end
end

abort "FAILED: #{failures.join(', ')}" unless failures.empty?
puts 'bc2cpp owner call icache check: PASS'
