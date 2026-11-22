#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# NATIVE_ARG_OK facts for pack and unpack (tools/bc2cpp/escape_analysis.rb). The template argument of Array#pack
# and String#unpack is read once and never kept, so a String template passed to them is confined. The facts are
# checked against the native registrations of the names: a Ruby definition of the name on the receiver's class
# (or an unknown receiver) keeps the template, and so does a template of any class but String.
#
# Verdict half (needs host mrbc): the escape report (BC2CPP_ESCAPE_REPORT) gives each creation site its verdict.
# Behaviour half (needs a full-core libmruby, see Bc2cppFixtureRuntime.full_or_build): the compiled and interpreted
# runs print the same results for the confined shapes.
#
# STACK_STRINGS half (generation, then the behaviour run): a confined literal template whose only readers are the
# audited natives is a frame-local String (codegen_stack_strings.rb); a receiver call, a closure read, a store or a
# Ruby definition of the name keeps the heap String, and BC2CPP_STACK_STRINGS=0 places none.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/send_arg_facts_check.rb

require 'tmpdir'
require_relative 'fixture_runtime'

# The fixture is checked against no shipped signature files: they name engine classes it lacks.
ENV['BC2CPP_SIG_DIRS'] ||= ''

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless Bc2cppFixtureRuntime.mrbc && system(Bc2cppFixtureRuntime.mrbc, '--version', out: File::NULL, err: File::NULL)
  puts '  SKIP: no host mrbc (set MRBC); the escape verdicts need it'
  exit 0
end

VERDICT_SRC = <<~'RUBY'
  class SABox
    def initialize; @v = 1; end
  end

  class SAKeep
    def pack(t); @k = t; nil; end
    def unpack(t); @k = t; nil; end
  end

  class SAFacts
    # Confined: the template is a String and every callee of the name is the native one.
    def s_pack_literal
      [1, 2].pack('C*')
    end

    def s_pack_local
      a = [1, 2]
      t = 'C*'
      a.pack(t)
    end

    def s_unpack_local
      s = 'AB'
      t = 'C*'
      s.unpack(t)
    end

    # Escapes: a Ruby definition of the name on the receiver's class keeps the template.
    def n_user_receiver
      k = SAKeep.new
      t = 'C'
      k.pack(t)
      nil
    end

    def n_user_unpack_receiver
      k = SAKeep.new
      t = 'C*'
      k.unpack(t)
      nil
    end

    # Escapes: an unknown receiver may be SAKeep, whose pack keeps its argument.
    def n_unknown_receiver(r)
      t = 'C'
      r.pack(t)
    end

    # Escapes: the template is not a String, so the native's audit does not cover its class.
    def n_object_template
      a = [1]
      o = SABox.new
      a.pack(o)
    end
  end
RUBY

# The program the behaviour half compiles and runs: the confined shapes, with results that show the template
# was read correctly, and a user receiver that keeps its template.
RUN_SRC = <<~'RUBY'
  class SABox
    def initialize; @v = 1; end
  end

  class SAKeep
    def pack(t); @k = t; nil; end
  end

  class SARun
    def p_pack_literal; [1, 2].pack('C*'); end
    def p_pack_local; a = [65, 66]; t = 'C*'; a.pack(t); end
    def p_unpack_local; s = 'AB'; t = 'C*'; s.unpack(t); end
    def p_unpack_wide; s = "\x01\x02\x03"; t = 'n'; s.unpack(t); end
    def p_user_keeps; k = SAKeep.new; t = 'C'; k.pack(t); k.instance_variable_get(:@k); end
  end

  class SAStack
    def s_loop(n); out = []; i = 0; while i < n; out << [65 + i].pack('C*'); i += 1; end; out; end
    def s_branch(f); t = 'C*'; t2 = t; f ? [66].pack(t2) : [67].pack(t); end
    def s_block(a); t = 'C*'; n = 0; a.each { |v| n += v }; [a.pack(t), n]; end
    def n_receiver; t = 'C*'; [t.size, [68].pack(t)]; end
    def n_closure; t = 'C*'; [69].map { |v| [v].pack(t) }; end
    def n_kept; t = 'C*'; [[70].pack(t), t]; end
    def n_mutated; t = 'C'; t << '*'; [71, 72].pack(t); end
  end
RUBY
# The methods whose template is a frame-local String (STACK_STRINGS), and those that keep the heap one.
STACK_PLACED = {
  'SARun' => %w[p_pack_literal p_pack_local p_unpack_local p_unpack_wide], 'SAStack' => %w[s_loop s_branch s_block]
}.freeze
STACK_REFUSED = { 'SARun' => %w[p_user_keeps], 'SAStack' => %w[n_receiver n_closure n_kept n_mutated] }.freeze

DRIVER = <<~'RUBY'
  fx = SARun.new
  st = SAStack.new
  [[:p_pack_literal], [:p_pack_local], [:p_unpack_local], [:p_unpack_wide], [:p_user_keeps], [:s_loop, 300, st],
   [:s_branch, true, st], [:s_branch, false, st], [:s_block, [73, 74], st], [:n_receiver, nil, st],
   [:n_closure, nil, st], [:n_kept, nil, st], [:n_mutated, nil, st]].each do |name, arg, recv|
    out = begin
      r = (recv || fx).__send__(name, *(arg.nil? ? [] : [arg]))
      name == :s_loop ? [r.size, r.first, r.last, r.uniq.size].inspect : r.inspect
    rescue NoMethodError, ArgumentError, TypeError => e
      "#{e.class}: #{e.message}"
    end
    puts "#{name}: #{out}"
  end
  puts 'end'
RUBY

# [kind, verdict, reason] of each creation site of method +name+ in the escape report.
def verdicts(rows, name)
  rows.select { |r| r[0] == 'site' && r[2] == "SAFacts##{name}" }.map { |r| [r[5], r[6], r[7]] }
end

def site?(rows, name, kind, verdict, reason = nil)
  verdicts(rows, name).any? { |k, v, why| k == kind && v == verdict && (reason.nil? || why == reason) }
end

puts '-- escape verdicts (generation)'
verdict_dir = Dir.mktmpdir('bc2cpp-send-arg-facts')
begin
  tsv = File.join(verdict_dir, 'escape.tsv')
  saved = ENV.fetch('BC2CPP_ESCAPE_REPORT', nil)
  ENV['BC2CPP_ESCAPE_REPORT'] = tsv
  begin
    Bc2cppFixtureRuntime.generate(VERDICT_SRC, verdict_dir, core: true, only_owners: %w[SAFacts SAKeep])
  ensure
    saved.nil? ? ENV.delete('BC2CPP_ESCAPE_REPORT') : ENV['BC2CPP_ESCAPE_REPORT'] = saved
  end
  rows = File.readlines(tsv, chomp: true).map { |line| line.split("\t", -1) }
  check.call('the report has the SAFacts creation sites', rows.count { |r| r[2].to_s.start_with?('SAFacts#') } >= 6)

  check.call('s_pack_literal: the literal template is confined', site?(rows, 's_pack_literal', 'string', 'confined'))
  check.call('s_pack_local: the String template of Array#pack is confined', site?(rows, 's_pack_local', 'string', 'confined'))
  check.call('s_unpack_local: the String template of String#unpack is confined',
             site?(rows, 's_unpack_local', 'string', 'confined'))

  check.call('n_user_receiver: a Ruby pack on the receiver class keeps the template (send_argument)',
             site?(rows, 'n_user_receiver', 'string', 'escapes', 'send_argument'))
  check.call('n_user_unpack_receiver: a Ruby unpack on the receiver class keeps the template (send_argument)',
             site?(rows, 'n_user_unpack_receiver', 'string', 'escapes', 'send_argument'))
  check.call('n_unknown_receiver: an unknown receiver keeps the template (send_argument)',
             site?(rows, 'n_unknown_receiver', 'string', 'escapes', 'send_argument'))
  check.call('n_object_template: a template of a user class is not covered (send_argument)',
             site?(rows, 'n_object_template', 'object', 'escapes', 'send_argument'))
ensure
  FileUtils.remove_entry(verdict_dir)
end

puts '-- behaviour (needs a full-core libmruby)'
build = Bc2cppFixtureRuntime.full_or_build
if build.nil?
  puts '  SKIP behavioural comparison: needs a full-core libmruby (BC2CPP_MRUBY_FULL, or rake, g++ and 3rd/mruby)'
else
  run_dir = Dir.mktmpdir('bc2cpp-send-arg-facts-run')
  begin
    code, run_err = Bc2cppFixtureRuntime.generate(RUN_SRC, run_dir, core: true, only_owners: %w[SARun SAKeep SAStack])
    chunk = lambda do |text, owner, name|
      text.split(%r{^(?=// \S+#\S+ \(compiled from)}).find { |c| c.start_with?("// #{owner}##{name} (") }.to_s
    end
    STACK_PLACED.each do |owner, names|
      names.each do |name|
        check.call("STACK_STRINGS: #{owner}##{name} builds its template as a frame-local String",
                   chunk.call(code, owner, name).include?('bc2cpp_stack_str(M, '))
      end
    end
    STACK_REFUSED.each do |owner, names|
      names.each do |name|
        text = chunk.call(code, owner, name)
        check.call("STACK_STRINGS: #{owner}##{name} keeps the heap String",
                   !text.empty? && !text.include?('bc2cpp_stack_str(M, '))
      end
    end
    saved_ss = ENV.fetch('BC2CPP_STACK_STRINGS', nil)
    ENV['BC2CPP_STACK_STRINGS'] = '0'
    off_code = Dir.mktmpdir('bc2cpp-stack-strings-off') do |off|
      Bc2cppFixtureRuntime.generate(RUN_SRC, off, core: true, only_owners: %w[SARun SAKeep SAStack]).first
    end
    saved_ss.nil? ? ENV.delete('BC2CPP_STACK_STRINGS') : ENV['BC2CPP_STACK_STRINGS'] = saved_ss
    check.call('kill switch: BC2CPP_STACK_STRINGS=0 places no frame-local String',
               !off_code.to_s.include?('bc2cpp_stack_str(M, '))
    body = <<~CPP
      static int scenario(mrb_state* M) {
        std::fflush(stdout);
        const char* src = R"BID(#{DRIVER})BID";
        mrb_load_string(M, src);
        std::fflush(stdout);
        if (M->exc) { mrb_print_error(M); M->exc = nullptr; return 1; }
        return 0;
      }
    CPP
    built, output = Bc2cppFixtureRuntime.run(run_dir, run_err, %w[SARun SAKeep SAStack], body, build: build, full: true)
    check.call('the fixtures build and run', built)
    sections = Bc2cppFixtureRuntime.sections(output)
    interpreted = sections['interpreted']
    compiled = sections['compiled']
    check.call('the driver finishes in both runs', interpreted&.last == 'end' && compiled&.last == 'end')
    check.call('interpreted and compiled runs print the same', interpreted == compiled)
    if interpreted && compiled
      interpreted.zip(compiled).reject { |a, b| a == b }.first(10).each { |a, b| puts "    interpreted: #{a}\n    compiled:    #{b}" }
      check.call('p_pack_literal packs the literal template', interpreted.include?('p_pack_literal: "\x01\x02"'))
      check.call('p_pack_local packs through the confined template', interpreted.include?('p_pack_local: "AB"'))
      check.call('p_unpack_local unpacks through the confined template', interpreted.include?('p_unpack_local: [65, 66]'))
      check.call('p_unpack_wide reads the template as big-endian 16-bit', interpreted.include?('p_unpack_wide: [258]'))
      check.call('p_user_keeps: the user receiver keeps its template', interpreted.include?('p_user_keeps: "C"'))
      check.call('s_loop: a frame-local template reused on every iteration packs each value',
                 interpreted.include?('s_loop: [300, "A", "l", 256]'))
      check.call('n_mutated: the appended template packs two bytes', interpreted.include?('n_mutated: "GH"'))
    end
    puts output.lines.last(30).join unless built && interpreted && compiled
  ensure
    FileUtils.remove_entry(run_dir)
  end
end

if failures.empty?
  puts 'bc2cpp send-arg facts check: PASS'
else
  warn "bc2cpp send-arg facts check: #{failures.size} failure(s)"
  exit 1
end
