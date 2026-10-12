#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rbconfig'
require 'stringio'
require 'tmpdir'
require_relative '../../tools/bc2cpp/irep'
require_relative '../../tools/bc2cpp/compiled_gems'

def sample_tree
  instruction = Insn.new(lineno: 1, addr: 0, op: 'LOADI_1', args: 'R1 (1)', raw: 'LOADI_1 R1')
  instruction.typed = [OperandSchema::Operand.new(:reg, 1)]
  irep = Irep.new(label: '0', nlocals: 1, nregs: 2, pool: [], syms: [], reps: [], lv: [],
                  instructions: [instruction], catch_handlers: [])
  tree = { '0' => irep }
  irep.tree = tree
  [tree, '0']
end

root = File.expand_path('../..', __dir__)
canonical = closed_world_mrblib_srcs(root)
%w[mruby-rpg2k-compiled mruby-lcf-compiled mruby-rgss-compiled].each do |gem|
  abort 'compiled-gem roots disagree on source filenames' unless closed_world_mrblib_srcs("#{root}/#{gem}/..") == canonical
end

Dir.mktmpdir('decoded-cache-check') do |dir|
  saved_cache = ENV['BC2CPP_IREP_CACHE_DIR']
  begin
    ENV['BC2CPP_IREP_CACHE_DIR'] = dir
    abort 'repository sources should be reusable' unless IrepCache.directory_for_sources(canonical) == dir
    abort 'temporary fixtures should bypass caching' if IrepCache.directory_for_sources([File.join(dir, 'fixture.rb')])
  ensure
    saved_cache ? ENV['BC2CPP_IREP_CACHE_DIR'] = saved_cache : ENV.delete('BC2CPP_IREP_CACHE_DIR')
  end
  calls = 0
  decode = -> { calls += 1; sample_tree }
  first = IrepCache.fetch('world', dir, &decode)
  path = Dir[File.join(dir, '*.marshal')].first
  first[0]['0'].pool << 'caller mutation'
  first[0]['0'].instructions.first.typed.first.value = 99
  second = IrepCache.fetch('world', dir, &decode)
  abort 'cache miss for identical bytecode' unless calls == 1
  abort 'caller mutation leaked into cached tree' unless second[0]['0'].pool.empty? && second[0]['0'].instructions.first.reg == '1'
  abort 'tree cycle was not restored' unless second[0]['0'].tree.equal?(second[0])
  abort 'operand lists lost their read-only contract' unless second[0]['0'].instructions.first.typed.frozen?

  IrepCache.fetch('changed world', dir, &decode)
  abort 'bytecode content did not invalidate the cache' unless calls == 2
  original_mode = ENV['BC2CPP_EXT_PREFIX']
  begin
    ENV['BC2CPP_EXT_PREFIX'] = InsnDecoder.fold_ext_prefix? ? '0' : '1'
    IrepCache.fetch('world', dir, &decode)
    abort 'decoder mode did not invalidate the cache' unless calls == 3
  ensure
    original_mode ? ENV['BC2CPP_EXT_PREFIX'] = original_mode : ENV.delete('BC2CPP_EXT_PREFIX')
  end
  original_fingerprint = IrepCache.fingerprint
  begin
    IrepCache.instance_variable_set(:@fingerprint, 'changed decoder sources')
    IrepCache.fetch('world', dir, &decode)
    abort 'decoder source signature did not invalidate the cache' unless calls == 4
  ensure
    IrepCache.instance_variable_set(:@fingerprint, original_fingerprint)
  end

  File.binwrite(path, 'broken snapshot')
  log = StringIO.new
  saved_stderr = $stderr
  begin
    $stderr = log
    IrepCache.fetch('world', dir, &decode)
  ensure
    $stderr = saved_stderr
  end
  abort 'corrupt snapshot was not rebuilt visibly' unless calls == 5 && log.string.include?('[bc2cpp]') && log.string.include?('rebuilding')

  failure = nil
  begin
    IrepCache.fetch('failed decode', dir) { raise 'decoder failure' }
  rescue RuntimeError => e
    failure = e.message
  end
  abort 'decoder failure disappeared' unless failure == 'decoder failure'
end

Dir.mktmpdir('decoded-cache-race') do |dir|
  marker = File.join(dir, 'decodes')
  script = <<~'CHILD'
    require ARGV.shift
    dir, marker = ARGV
    IrepCache.fetch('concurrent world', dir) do
      File.open(marker, 'a') { |f| f.puts 'decoded' }
      sleep 0.1
      irep = Irep.new(label: '0', instructions: [])
      tree = { '0' => irep }
      irep.tree = tree
      [tree, '0']
    end
  CHILD
  loader = File.expand_path('../../tools/bc2cpp/irep', __dir__)
  children = 4.times.map { Process.spawn(RbConfig.ruby, '-e', script, loader, dir, marker) }
  statuses = children.map { |pid| Process.wait2(pid).last }
  abort 'concurrent cache reader failed' unless statuses.all?(&:success?)
  abort 'concurrent readers decoded the same input repeatedly' unless File.readlines(marker).size == 1
end
puts 'decoded tree cache check: PASS'
