#!/usr/bin/env ruby
# frozen_string_literal: true

# The BLOCK_YIELD join (tools/bc2cpp/block_yielders.rb) on real bc2cpp output. Each case is a block body the codegen
# emits from a SENDB; its BLOCK_YIELD row names the one method that yields to it (key and plain arity), or the reason
# it has none. Needs a host mrbc (MRBC) and the closed-world probe environment; SKIPs without MRBC, like the other
# pipeline parts. The row is written by the instrumented output (BC2CPP_TRACE_TYPES=1), which the at-exit hook prints
# on stdout as fputs("BLOCK_YIELD\t...") lines.
#
# Usage: MRBC=path/to/mrbc ruby scripts/bc2cpp/block_yielders_check.rb

require 'open3'
require 'rbconfig'
require 'tmpdir'

ENV['BC2CPP_SIG_DIRS'] = ''
ROOT = File.expand_path('../..', __dir__)
require_relative '../../tools/bc2cpp/closed_world_env'

failures = []
check = ->(name, ok) { failures << name unless ok }

SOURCE = <<~RUBY_SRC
  class BYielder
    def each_item
      yield 1
      yield 2
    end
    def each_pair2
      yield 1, "a"
    end
  end
  class BKeeper
    def keep(&b)
      @saved = b
    end
  end
  class BCaller
    def run(y)
      y.each_item { |x| x.to_s }
    end
    def run2(y)
      y.each_pair2 { |a, b| a.to_s + b }
    end
    def run3(k)
      k.keep { |z| z }
    end
    def run4(y)
      y.each_item { |x, w| x }
    end
  end
  class BFwd
    def pass_on(&b)
      BYielder.new.each_item(&b)
    end
    def gives_up(&b)
      b.call(7)
    end
    def each_item_fwd
      yield 5
    end
  end
  class BDup1
    def dup_name
      yield 1
    end
  end
  class BDup2
    def dup_name
      2
    end
  end
  class BCaller3
    def run10(o)
      o.dup_name { |v| v }
    end
    def run11(o)
      o.map { |v| v }
    end
  end
  class BCaller2
    def run7(f)
      f.gives_up { |q| q }
    end
    def run8(f)
      f.pass_on { |p| p }
    end
    def run9(f)
      f.each_item_fwd { |p| p }
    end
  end
RUBY_SRC

# The yielded rows of one run: [body name, key, arity, reason] from the BLOCK_YIELD lines of the instrumented output.
def join_rows(text)
  text.scan(/fputs\("(BLOCK_YIELD[^"]*)"/).flatten.map do |escaped|
    line = escaped.gsub(/\\(\d{3})/) { Regexp.last_match(1).to_i(8).chr }
    _tag, _sym, fn, key, arity, reason = line.chomp.split("\t", -1)
    [fn, key == '-' ? nil : key, arity == '-' ? nil : arity.to_i, reason]
  end
end

mrbc = ENV['MRBC']
unless mrbc && File.executable?(mrbc)
  puts 'SKIP block yielder pipeline fixtures (set MRBC)'
  exit($failures.empty? ? 0 : 1)
end

def run_bc2cpp(mrbc, dir, src, extra = {})
  mrb = File.join(dir, 'fx.mrb')
  abort "mrbc failed for #{src}" unless system(mrbc, '-g', '-o', mrb, src)
  env = bc2cpp_closed_world_probe_env({ 'MRBC' => mrbc, 'OUT_SYMBOL' => 'bc2cpp_fx', 'OUT_DIR' => dir,
                                        'SKIP_UNSUPPORTED' => '1', 'BC2CPP_SELF_REGISTERING' => '1',
                                        'BC2CPP_TRACE_TYPES' => '1' }.merge(extra))
  out, err, status = Open3.capture3(env, RbConfig.ruby, File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb'), '--annotated', src,
                                    chdir: ROOT)
  abort "bc2cpp.rb failed:\n#{err[-3000..] || err}" unless status.success?
  out
end

Dir.mktmpdir('block-yielders') do |dir|
  src = File.join(dir, 'fx.rb')
  File.write(src, SOURCE)
  rows = join_rows(run_bc2cpp(mrbc, dir, src))
  # A body is named by the method it was written in: `BCaller_run_block_fallback_7_impl` is `BCaller_run`.
  by_body = rows.to_h { |fn, *rest| [fn[/\A(\w+?)_block_fallback/, 1] || fn, rest] }
  yielded = ->(name) { by_body.fetch(name) }

  check.call('a body run by each_item (one yielder, one plain parameter) joins BYielder#each_item with arity 1',
             yielded.call('BCaller_run') == ['BYielder#each_item', 1, 'ok'])
  check.call('a two-argument yield joins each_pair2 with arity 2',
             yielded.call('BCaller_run2') == ['BYielder#each_pair2', 2, 'ok'])
  check.call('a method name that two classes define is undecided: not_unique',
             yielded.call('BCaller3_run10') == [nil, nil, 'not_unique'])
  check.call('a block handed to a native method (map) is undecided: the native may keep it',
             yielded.call('BCaller3_run11') == [nil, nil, 'block_escapes'])
  check.call('a body that the callee keeps (`@saved = b`) is undecided: block_escapes',
             yielded.call('BCaller_run3') == [nil, nil, 'block_escapes'])
  check.call('a body handed to a method with an `&blk` parameter is undecided, though it only calls it',
             yielded.call('BCaller2_run7') == [nil, nil, 'yielder_block_param'])
  check.call('a body handed to a method that passes its block on (`each_item(&b)`) is undecided',
             yielded.call('BCaller2_run8') == [nil, nil, 'yielder_block_param'])
  check.call('a body yielded by a method defined in a second class joins that method',
             yielded.call('BCaller2_run9') == ['BFwd#each_item_fwd', 1, 'ok'])
  check.call('a body with two parameters joins with arity 2 (a shape the gate compares only with a 2-parameter block)',
             yielded.call('BCaller_run4')[1] == 2)

  # Without the escape world (BC2CPP_ESCAPE_ANALYSIS=0) no body has a join.
  Dir.mktmpdir('block-yielders-off') do |off|
    off_src = File.join(off, 'fx.rb')
    File.write(off_src, SOURCE)
    off_rows = join_rows(run_bc2cpp(mrbc, off, off_src, 'BC2CPP_ESCAPE_ANALYSIS' => '0'))
    check.call('without the escape world every body is undecided (no key)',
               !off_rows.empty? && off_rows.all? { |_fn, key, _arity, _reason| key.nil? })
  end
end

if failures.empty?
  puts 'block yielders check: PASS'
else
  warn "block yielders check: FAIL\n  #{failures.join("\n  ")}"
  exit 1
end
