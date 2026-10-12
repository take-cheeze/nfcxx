#!/usr/bin/env ruby
# frozen_string_literal: true

# LOOP_FLOW_POSITION (docs/adr/0398): a send compiled from an inlined loop body takes the flow position the proof
# reads, instead of being judged with no position (closed_world_site got `idx` nil there).
#   - a receiver the block defines is judged at the block's own flow position;
#   - a receiver read from a method local (GETUPVAR at level 0) is judged at the method's flow at the loop's SENDB
#     (path upvar), unless the host method or a nested block writes that local (refused upvar_written);
#   - a receiver holding the loop element is refused when the body reassigns the element register R1.
# The checks generate C++ for worlds through the closed-world generator and read the counts the generator
# prints under BC2CPP_LOOP_FLOW_REPORT=1 (accepted and refused positions, by path or reason):
#   1. positive: a receiver the block defines in an inlined `each` is judged (accepted local, proven tail);
#   2. positive: a method local read in the body is judged at the loop's SENDB (accepted upvar, proven tail);
#   3. negative: the element reassigned (refused element_reassigned);
#   4. negative: a method local the body writes is refused (upvar_written), its send stays by name;
#   5. negative: a receiver from an argument has no definition to read (its positions stay out of the proof).
# BC2CPP_LOOP_FLOW_POSITION=0 must leave every position out (no accepted, no refused count), the switch-off control.
# LFP_MUTANTS=1 (needs 1): the generator with one guard removed or a wrong position used at a time must fail a
# check: each mutant is a copy of tools/bc2cpp run through BC2CPP_TOOL.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/loop_flow_position_check.rb

require 'fileutils'
require 'open3'
require 'tmpdir'

failures = []
check = lambda do |what, condition|
  puts "  #{condition ? 'ok  ' : 'FAIL'} #{what}"
  failures << what unless condition
end

unless ENV['MRBC']
  puts '  SKIP: set MRBC (a host mrbc built from the patched 3rd/mruby)'
  exit 0
end

ENV['BC2CPP_LOOP_FLOW_REPORT'] = '1'
require_relative 'fixture_runtime'
require_relative 'mutant_pool'
runtime = Bc2cppFixtureRuntime

# The receiver classes: LfKey and LfPlain answer `wait` (the chain's candidates, so the send keeps an else arm);
# LfNone does not; LfOther's singleton `wait` is what makes the name a singleton definer (ADR 0255 / ADR 0302).
CLASSES = <<~'RUBY'
  class LfKey
    def wait; :key; end
  end
  class LfPlain
    def wait; :plain; end
  end
  class LfNone
  end
  class LfOther
    def self.wait; :other; end
  end
RUBY

# 1. The receiver is the method local `req`, read in an inlined `each` body (GETUPVAR level 0). Its set is proven
#    by the method's flow at the loop, so the send's else arm is the proven nomethod tail with that position. The
#    filler before `req` makes the method's flow at the body's own index (the block's index) carry no fact, so a
#    position read at the wrong index is refused.
POSITIVE = CLASSES + <<~'RUBY'
  class LfMapPos
    def initialize; @list = [1, 2]; end
    def pick(flag)
      return LfKey.new if flag == 1
      return LfPlain.new if flag == 2
      LfNone.new
    end
    def go(flag)
      filler_a = 1
      filler_b = filler_a + 1
      filler_c = filler_b + 1
      filler_d = filler_c + 1
      req = pick(flag)
      acc = []
      @list.each do |i|
        acc << req.wait if req.respond_to?(:wait)
      end
      acc
    end
  end
RUBY

# 1b. The receiver is defined by the block itself (`r = pick(i)`) and sent `wait` plainly: judged at the block's own
#     flow position. The block-local world is sent plainly: a receiver narrowed by `respond_to?` in a block gets no
#     position here (ADR 0398, limit).
LOCAL = CLASSES + <<~'RUBY'
  class LfMapLocal
    def initialize; @list = [1, 2]; end
    def pick(flag)
      return LfKey.new if flag == 1
      return LfPlain.new if flag == 2
      LfNone.new
    end
    def go(flag)
      acc = []
      @list.each do |i|
        r = pick(i)
        acc << r.wait
      end
      acc
    end
  end
RUBY

# 1c. The receiver is the method local `req`, sent `wait` plainly in an inlined `each` body: its set is the method's
#     flow at the loop's own SENDB (path upvar), so the else arm is the proven nomethod tail.
METHOD = CLASSES + <<~'RUBY'
  class LfMapMethod
    def initialize; @list = [1, 2]; end
    def pick(flag)
      return LfKey.new if flag == 1
      return LfPlain.new if flag == 2
      LfNone.new
    end
    def go(flag)
      req = pick(flag)
      acc = []
      @list.each do |i|
        acc << req.wait
      end
      acc
    end
  end
RUBY

# 2. The loop element is the receiver's copy, and the body reassigns the element register: refused.
ELEMENT = CLASSES + <<~'RUBY'
  class LfMapElem
    def initialize; @list = [1, 2]; end
    def go
      list = [LfKey.new, LfPlain.new]
      acc = []
      list.each do |i|
        x = i
        i = LfPlain.new
        acc << x.wait if x.respond_to?(:wait)
      end
      acc
    end
  end
RUBY

# 3. The body writes the method local the receiver reads (a nested SETUPVAR): refused.
UPVAR_WRITTEN = CLASSES + <<~'RUBY'
  class LfMapWrite
    def initialize; @list = [1, 2]; end
    def pick(flag)
      return LfKey.new if flag == 1
      LfPlain.new
    end
    def go(flag)
      req = pick(flag)
      acc = []
      @list.each do |i|
        req = LfPlain.new if i == 1
        acc << req.wait if req.respond_to?(:wait)
      end
      acc
    end
  end
RUBY

# 4. The receiver is an argument: nothing in the method proves its set, so the position proves nothing.
ARGUMENT = CLASSES + <<~'RUBY'
  class LfMapArg
    def initialize; @list = [1, 2]; end
    def go(req)
      acc = []
      @list.each do |i|
        acc << req.wait if req.respond_to?(:wait)
      end
      acc
    end
  end
RUBY

# "bc2cpp loop_flow accepted: local 1, upvar 2" and "... refused: element_reassigned 1" from one generation's stderr.
counts = lambda do |err, kind|
  line = err.to_s[/^bc2cpp loop_flow #{kind}: (.*)$/, 1].to_s
  line.split(', ').to_h { |pair| [pair.split(' ').first, pair.split(' ').last.to_i] }
end

generate = lambda do |world, owners, label|
  dir = Dir.mktmpdir("lfp-#{label}")
  code, err = runtime.generate(world, dir, only_owners: owners, skip_unsupported: false)
  [code, err, dir]
end

# The generated `wait` sends of one world: the proven nomethod tails and the kept ones (by reason).
wait_marks = lambda do |code|
  {
    proven: code.scan(/bc2cpp_nomethod\(M, \w+, \d+\); \/\* CLOSED_WORLD nomethod: recv\.wait \*\//).size,
    singleton: code.scan(/CLOSED_WORLD kept: singleton_definer \*\//).size
  }
end

puts '-- positive: an inlined-loop receiver the block defines takes the block-flow position'
code, err, dir = generate.call(LOCAL, %w[LfMapLocal LfKey LfPlain LfNone], 'local')
check.call('a local position is accepted', counts.call(err, 'accepted').fetch('local', 0).positive?)
check.call('the block-defined receiver is not refused (only the self call pick(i) is refused, self_send)',
           counts.call(err, 'refused').keys.all? { |reason| reason == 'self_send' } &&
           !counts.call(err, 'refused').key?('unproven_definition'))
check.call('the wait send takes the proven nomethod tail', wait_marks.call(code)[:proven] >= 1)
check.call('no wait send of the local world is kept as a singleton definer', wait_marks.call(code)[:singleton].zero?)
FileUtils.rm_rf(dir)

puts '-- positive: a method-local receiver read in the body takes the loop SENDB position (path upvar)'
code, err, dir = generate.call(METHOD, %w[LfMapMethod LfKey LfPlain LfNone], 'method')
check.call('an upvar position is accepted', counts.call(err, 'accepted').fetch('upvar', 0).positive?)
check.call('no method-local position is refused as upvar_narrowed', !counts.call(err, 'refused').key?('upvar_narrowed'))
check.call('the method-local wait send takes the proven nomethod tail', wait_marks.call(code)[:proven] >= 1)
check.call('no wait send of the method-local world is kept as a singleton definer', wait_marks.call(code)[:singleton].zero?)
FileUtils.rm_rf(dir)

puts '-- respond_to?-narrowed method local: judged at the SENDB position, its tail behind the narrowing guard (ADR 0398)'
code, err, dir = generate.call(POSITIVE, %w[LfMapPos LfKey LfPlain LfNone], 'pos')
check.call('the respond_to?-narrowed method local is judged (accepted upvar)', counts.call(err, 'accepted').fetch('upvar', 0).positive?)
check.call('the narrowing guard is still emitted around the wait send', code.include?('CLASS_NARROWING_GUARD :respond_to?'))
check.call('the wait send keeps its nomethod tail behind the guard', wait_marks.call(code)[:proven] >= 1)
FileUtils.rm_rf(dir)

puts '-- negative: the element reassigned in the body is refused, and its send stays by name'
code, err, dir = generate.call(ELEMENT, %w[LfMapElem LfKey LfPlain LfNone], 'elem')
check.call('element_reassigned is counted', counts.call(err, 'refused').fetch('element_reassigned', 0).positive?)
check.call('the element send stays kept as a singleton definer', wait_marks.call(code)[:singleton].positive?)
FileUtils.rm_rf(dir)

puts '-- negative: a method local the body writes is refused (upvar_written), and its send stays by name'
code, err, dir = generate.call(UPVAR_WRITTEN, %w[LfMapWrite LfKey LfPlain LfNone], 'write')
check.call('no upvar position is accepted for the written local', counts.call(err, 'accepted').fetch('upvar', 0).zero?)
check.call('upvar_written is counted', counts.call(err, 'refused').fetch('upvar_written', 0).positive?)
check.call('the written-local send stays kept', wait_marks.call(code)[:proven].zero?)
FileUtils.rm_rf(dir)

puts '-- negative: an argument receiver has no set to prove, so its send is not a proven tail'
code, err, dir = generate.call(ARGUMENT, %w[LfMapArg LfKey LfPlain LfNone], 'arg')
check.call('no send of the argument world is proven', wait_marks.call(code)[:proven].zero?)
FileUtils.rm_rf(dir)

puts '-- switch off: no position is read or refused, and the positive world keeps its singleton sends'
ENV['BC2CPP_LOOP_FLOW_POSITION'] = '0'
code, err, dir = generate.call(POSITIVE, %w[LfMapPos LfKey LfPlain LfNone], 'off')
check.call('switch off accepts and refuses nothing', counts.call(err, 'accepted').empty? && counts.call(err, 'refused').empty?)
check.call('switch off keeps the positive world send as a singleton definer', wait_marks.call(code)[:singleton] >= 1)
ENV.delete('BC2CPP_LOOP_FLOW_POSITION')
FileUtils.rm_rf(dir)

if ENV['LFP_MUTANTS'] == '1'
  puts '-- mutants: one guard removed or a wrong position read, the checks above must fail'
  root = File.expand_path('../..', __dir__)
  mutants = [
    ['wrong iteration position (the instruction before the send)', 'tools/bc2cpp/codegen_send.rb',
     'original = irep.instructions[trace_idx]', 'original = irep.instructions[trace_idx - 1]'],
    ['element reassignment guard dropped', 'tools/bc2cpp/codegen_send.rb',
     'if element && loop_element_reassigned?(irep)', 'if false'],
    ['method-local receiver path disabled (refused as upvar_narrowed)', 'tools/bc2cpp/codegen_send.rb',
     'loop_upvar_position(original, upvars, irep, trace_idx)',
     'loop_flow_refuse(irep, trace_idx, :upvar_narrowed)'],
    ['written method local accepted (upvar_written guard dropped)', 'tools/bc2cpp/codegen_send.rb',
     'if fixnum_proof_ctx(host)[:upvars].include?(k.to_s)', 'if false']
  ]
  mutants.each do |what, file, from, to|
    Dir.mktmpdir('lfp-mutant') do |tmp|
      Bc2cppMutantPool.copy_generator(root, tmp)
      target = File.join(tmp, 'bc2cpp', File.basename(file))
      text = File.read(target)
      unless text.include?(from)
        check.call("mutant (#{what}) applies", false)
        next
      end
      File.write(target, text.sub(from, to))
      out, status = Open3.capture2e({ 'LFP_MUTANTS' => nil, 'BC2CPP_LINT_CROSSCHECK' => '0',
                                      'BC2CPP_TOOL' => File.join(tmp, 'bc2cpp/bc2cpp.rb') },
                                    RbConfig.ruby, __FILE__)
      check.call("mutant (#{what}) is caught", !status.success? && out.include?('FAIL'))
    end
  end
end

if failures.empty?
  puts '  all loop-flow position checks passed'
else
  puts "  #{failures.size} check(s) failed"
  exit 1
end
