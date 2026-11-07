#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# STEP_KEYWORDS (codegen_method.rb, codegen_resumable.rb resumable_dyn_kw_function): a method with keyword parameters, alone or next
# to optional, rest and block ones, is a step with a keyword dispatcher and a call carrying keywords reaches it. Compiled fiber
# bodies print what the interpreted run prints, including the ArgumentErrors for missing/unknown keywords and wrong counts.
#
# Usage: MRBC=path/to/mrbc [BC2CPP_MRUBY_FULL=dir | BC2CPP_FULL_BUILD_DIR=dir] ruby scripts/bc2cpp/step_keywords_check.rb

require_relative 'fixture_runtime'

suite = Bc2cppStepCheck.new('bc2cpp step keywords check')

# Every scenario is a method returning the Fiber to run, so the bodies, the methods they call and their blocks are compiled.
SRC = <<~'RUBY'
  class StepKw
    # Each method yields its bound parameters, then calls its block when it has one (a block that suspends is a step too).
    def kw_req(a, k:, &blk)
      Fiber.yield [a, k]
      blk.call(:blk) if blk
      :req_done
    end

    def kw_opt(a, k: 10, j: 20, &blk)
      Fiber.yield [a, k, j]
      blk.call(:blk) if blk
      :opt_done
    end

    def opt_kw(a, b = 2, k: 3, &blk)
      Fiber.yield [a, b, k]
      blk.call(:blk) if blk
      :opt_kw_done
    end

    def rest_kw(*rest, k: 1, &blk)
      Fiber.yield [rest, k]
      blk.call(:blk) if blk
      :rest_kw_done
    end

    def opt_rest_kw(a = 1, *rest, k: 2, &blk)
      Fiber.yield [a, rest, k]
      blk.call(:blk) if blk
      :orkb_done
    end

    def mixed(a, b = 5, *rest, x:, y: 6, &blk)
      Fiber.yield [a, b, rest, x, y]
      blk.call(:blk) if blk
      :mixed_done
    end

    def kw_call(a, k: 1, j: 2, &blk)
      blk.call([a, k, j])
    end

    def kw_only(step: 1)
      Fiber.yield step
      step + 1
    end

    # Calls by name: the call carries keywords (or none), with no literal block (a block cannot go with keywords).
    def required_keyword
      Fiber.new { [kw_req(1, k: 2), :after] }
    end

    def optional_keywords
      Fiber.new { [kw_opt(1), kw_opt(1, j: 3), kw_opt(1, j: 3, k: 4)] }
    end

    def optional_and_keyword
      Fiber.new { [opt_kw(1), opt_kw(1, 9), opt_kw(1, k: 7), opt_kw(1, 9, k: 7)] }
    end

    def rest_and_keyword
      Fiber.new { [rest_kw, rest_kw(1, 2, 3), rest_kw(1, k: 5)] }
    end

    def optional_rest_keyword
      Fiber.new { [opt_rest_kw, opt_rest_kw(5), opt_rest_kw(5, 6, 7, k: 8)] }
    end

    def mixed_shape
      Fiber.new { [mixed(1, x: 2), mixed(1, 2, 3, 4, y: 5, x: 6)] }
    end

    def keyword_only
      Fiber.new { [kw_only, kw_only(step: 5)] }
    end

    # A literal block and no keywords: the defaults of every keyword shape.
    def with_block
      Fiber.new do
        [kw_opt(1) { |x| Fiber.yield [:blk, x] }, opt_kw(1) { |x| Fiber.yield [:blk, x] },
         rest_kw { |x| Fiber.yield [:blk, x] }, opt_rest_kw(2, 3) { |x| Fiber.yield [:blk, x] }]
      end
    end

    # Keywords and a literal block in one call: in a step (the block suspends or not), and in a plain method.
    def block_and_keywords
      Fiber.new do
        [kw_opt(1, k: 3) { |x| Fiber.yield [:blk, x] }, opt_rest_kw(5, 6, k: 8) { |x| x }, send(:kw_req, 1, k: 2) { |x| x },
         kw_call(1, k: 2) { |x| break :broke }]
      end
    end

    def block_and_splat
      opts = { j: 30 }
      Fiber.new { [kw_opt(2, **opts) { |x| Fiber.yield x }, kw_opt(3, k: 1, **opts) { |x| x }] }
    end

    def block_and_bad_keyword
      Fiber.new { kw_req(1, k: 1, z: 3) { |x| x } }
    end

    def plain_block_and_keywords
      opts = { j: 30 }
      t = 0
      [kw_call(1, k: 3) { |x| t += x.size }, kw_call(1, k: 2) { |x| break :broke }, kw_call(2, **opts, &:size), t]
    end

    def plain_return_through_keywords
      kw_call(1, k: 7) { |x| return x }
      :not_reached
    end

    def plain_missing_keyword
      kw_req(1) { |x| x }
    end

    def plain_unknown_keyword
      kw_call(1, z: 3) { |x| x }
    end

    def by_send
      Fiber.new do
        [send(:kw_req, 1, k: 2), public_send(:opt_rest_kw, 3, 4, k: 5), __send__(:kw_opt, 7), send(:kw_only, step: 3)]
      end
    end

    def by_splat
      opts = { j: 30 }
      Fiber.new { [send(:kw_opt, 1, **opts), kw_opt(2, **opts)] }
    end

    def missing_keyword
      Fiber.new { kw_req(1) }
    end

    def unknown_keyword
      Fiber.new { kw_req(1, k: 2, z: 3) }
    end

    def missing_by_send
      Fiber.new { send(:kw_req, 1) }
    end

    def unknown_by_send
      Fiber.new { send(:kw_opt, 1, z: 3) }
    end

    def too_few
      Fiber.new { kw_req(k: 2) }
    end

    def too_many
      Fiber.new { opt_kw(1, 2, 3, k: 4) }
    end

    def too_few_by_send
      Fiber.new { send(:mixed, x: 1) }
    end
  end
RUBY

code = suite.generate(SRC, %w[StepKw])
%w[kw_req kw_opt opt_kw rest_kw opt_rest_kw mixed kw_only].each do |name|
  suite.check("StepKw##{name} is a step with a keyword dispatcher", code.include?("static mrb_value StepKw_#{name}_step(mrb_state* M") &&
                                                                      code.include?("StepKw_#{name}_impl_dyn_reg = (bc2cpp_dyn_register_kw("))
end
suite.check('no method stays interpreted', !suite.err.include?('stays interpreted'))

DRIVER = Bc2cppStepCheck::SHOW + Bc2cppStepCheck::DRAIN + <<~'RUBY'
  o = StepKw.new
  show('required keyword') { drain(o.required_keyword) }
  show('optional keywords') { drain(o.optional_keywords) }
  show('optional and keyword') { drain(o.optional_and_keyword) }
  show('rest and keyword') { drain(o.rest_and_keyword) }
  show('optional rest keyword') { drain(o.optional_rest_keyword) }
  show('mixed shape') { drain(o.mixed_shape) }
  show('keyword only') { drain(o.keyword_only) }
  show('with block') { drain(o.with_block) }
  show('by send') { drain(o.by_send) }
  show('block and keywords') { drain(o.block_and_keywords) }
  show('block and splat') { drain(o.block_and_splat) }
  show('block and bad keyword') { drain(o.block_and_bad_keyword) }
  show('plain block and keywords') { o.plain_block_and_keywords }
  show('plain return') { o.plain_return_through_keywords }
  show('plain missing keyword') { o.plain_missing_keyword }
  show('plain unknown keyword') { o.plain_unknown_keyword }
  show('by splat') { drain(o.by_splat) }
  show('missing keyword') { drain(o.missing_keyword) }
  show('unknown keyword') { drain(o.unknown_keyword) }
  show('missing by send') { drain(o.missing_by_send) }
  show('unknown by send') { drain(o.unknown_by_send) }
  show('too few') { drain(o.too_few) }
  show('too many') { drain(o.too_many) }
  show('too few by send') { drain(o.too_few_by_send) }
  puts 'end'
RUBY

suite.behaviour(DRIVER) do |interpreted, _|
  # What Ruby prints, so a probe that stopped exercising a shape fails here and not by agreeing on a different line.
  expected = {
    'required keyword' => '[[1, 2], [:req_done, :after]]',
    'optional keywords' => '[[1, 10, 20], [1, 10, 3], [1, 4, 3], [:opt_done, :opt_done, :opt_done]]',
    'optional and keyword' => '[[1, 2, 3], [1, 9, 3], [1, 2, 7], [1, 9, 7], ' \
                              '[:opt_kw_done, :opt_kw_done, :opt_kw_done, :opt_kw_done]]',
    'rest and keyword' => '[[[], 1], [[1, 2, 3], 1], [[1], 5], [:rest_kw_done, :rest_kw_done, :rest_kw_done]]',
    'optional rest keyword' => '[[1, [], 2], [5, [], 2], [5, [6, 7], 8], ' \
                               '[:orkb_done, :orkb_done, :orkb_done]]',
    'keyword only' => '[1, 5, [2, 6]]',
    'missing keyword' => 'raised ArgumentError: missing keyword: k',
    'unknown keyword' => 'raised ArgumentError: unknown keyword: z',
    'missing by send' => 'raised ArgumentError: missing keyword: k',
    'unknown by send' => 'raised ArgumentError: unknown keyword: z',
    'block and bad keyword' => 'raised ArgumentError: unknown keyword: z',
    'plain block and keywords' => '[3, :broke, 3, 3]',
    'plain return' => '[1, 7, 2]'
  }
  expected.each do |label, line|
    ok = interpreted&.include?("#{label}: #{line}")
    suite.check("#{label} prints what Ruby does", ok)
    puts "    interpreted: #{interpreted&.find { |l| l.start_with?("#{label}: ") }}" unless ok
  end
end
suite.finish
