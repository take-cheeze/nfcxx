#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# GUARDED_FIBER_REACH: a report on the CORE_BLOCK_GUARD methods of the closed world (see
# docs/bc2cpp-resumable-guarded-design.md). It measures
#   - the core methods the block guard covers (CodeGen.core_guarded, CoreMethods.guarded_labels);
#   - how many of them a Fiber body can reach (YieldReach#fiber_crossable, the analysis of codegen_yield_free.rb);
#   - how many of those the guard decides by the block at run time (CodeGen#core_body_relaxable?);
#   - the closed-world call sites that can start a Fiber: Fiber.new, and the external-iteration names
#     (next, peek, next_values, peek_values, zip, feed) as sends or as literal symbols.
#
# The parent runs the closed-world analysis as a child bc2cpp.rb run with BC2CPP_TYPE_CHECK_ONLY, so nothing is
# compiled. The child loads this file through RUBYOPT and reads the CodeGen state the analysis left behind. Nothing is
# written outside a temporary directory.
#
#   MRBC=path/to/mrbc ruby scripts/bc2cpp/guarded_fiber_reach_report.rb [--list]
#
# Needs the 3rd/ submodules (mruby and its closed gems) checked out. It reports; it does not assert.

ROOT = File.expand_path('../..', __dir__)
ENTRY_NAMES = %w[next peek next_values peek_values zip feed].freeze
DYNAMIC_NAMES = %w[send __send__ public_send].freeze

if ENV['GFR_HOOK'] == '1'
  # Child: installed before bc2cpp.rb runs. Records the state of every CodeGen the analysis builds over a sound closed
  # world; the last one written is the one the driver keeps (every construction shares the same YieldReach).
  require 'json'
  require 'set'
  require File.join(ROOT, 'tools/bc2cpp/codegen')

  module GuardedFiberReachHook
    def gfr_relative(path)
      path.to_s.delete_prefix("#{ROOT}/").sub(%r{\A.*/3rd/mruby/}, '3rd/mruby/')
    end

    def gfr_census
      census = { entry_sends: Hash.new(0), entry_literals: Hash.new(0), dynamic_sends: Hash.new(0), fiber_new: [],
                 fiber_yield: Hash.new(0) }
      @ireps.each_value do |irep|
        file = gfr_relative(irep.file)
        program = BytecodeIR.for(irep)
        program.each_with_op(:SEND, :SEND0, :SENDB, :SSEND, :SSEND0, :SSENDB) do |insn, idx|
          name = insn.sym
          next unless name

          if fiber_const_receiver?(irep, idx, insn.reg)
            if name == 'new'
              census[:fiber_new] << "#{file} (irep #{irep.label})"
            else
              census[:fiber_yield]["Fiber.#{name}"] += 1
            end
          elsif ENTRY_NAMES.include?(name)
            census[:entry_sends]["#{name} #{file}"] += 1
          elsif DYNAMIC_NAMES.include?(name)
            census[:dynamic_sends][file] += 1
          end
        end
        program.each_with_op(:LOADSYM) do |insn, _idx|
          census[:entry_literals]["#{insn.sym} #{file}"] += 1 if ENTRY_NAMES.include?(insn.sym)
        end
      end
      census
    end

    def initialize(*args, **kwargs, &block)
      super
      yr = @yield_reach
      return unless yr&.sound?

      guarded = (self.class.core_guarded || Set.new).sort
      rows = guarded.map do |label|
        d = @owner_of[label]
        { label: label, key: d ? "#{d.owner}##{d.name}" : "(no definition)", file: gfr_relative(@ireps[label]&.file),
          crossable: yr.fiber_crossable.include?(label), relaxable: core_body_relaxable?(label) }
      end
      fiber_bodies = yr.fiber_body_labels.map { |label| { label: label, file: gfr_relative(@ireps[label]&.file) } }
      dump = {
        sound: true, guarded: rows.size, crossable: rows.count { |r| r[:crossable] },
        relaxable: rows.count { |r| r[:relaxable] }, crossable_relaxable: rows.count { |r| r[:crossable] && r[:relaxable] },
        fiber_bodies: fiber_bodies, fiber_roots: @fiber_roots.size, fiber_unsafe_methods: @fiber_unsafe_methods.size,
        methods: rows, census: gfr_census
      }
      File.write(ENV.fetch('GFR_DUMP'), JSON.pretty_generate(dump))
    end
  end

  CodeGen.prepend(GuardedFiberReachHook)
else
  require 'json'
  require 'rbconfig'
  require 'tmpdir'
  require_relative '../../tools/bc2cpp/closed_world_env'

  mrbc = ENV['MRBC'] || 'mrbc'
  abort 'guarded_fiber_reach_report: set MRBC to a host mrbc' unless system(mrbc, '--version', out: File::NULL, err: File::NULL)

  list = ARGV.include?('--list')
  sources = closed_world_mrblib_srcs(ROOT)
  Dir.mktmpdir('guarded_fiber_reach') do |dir|
    dump_path = File.join(dir, 'fiber.json')
    env = bc2cpp_closed_world_probe_env({
      'MRBC' => mrbc, 'OUT_SYMBOL' => 'guarded_fiber_reach', 'OUT_DIR' => dir, 'SKIP_UNSUPPORTED' => '1',
      'BC2CPP_COLLECTION_EXPORTS' => '1', 'BC2CPP_TYPE_CHECK_ONLY' => '1',
      'BC2CPP_TYPE_FACTS' => File.join(dir, 'facts.json'), 'BC2CPP_TYPE_FACTS_ROOT' => ROOT, 'BC2CPP_SIG_ROOT' => ROOT
    }, ROOT).merge('RUBYOPT' => "-r#{File.expand_path(__FILE__)}", 'GFR_HOOK' => '1', 'GFR_DUMP' => dump_path)
    err_path = File.join(dir, 'bc2cpp.stderr')
    ok = system(env, RbConfig.ruby, File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb'), '--annotated', *sources,
                out: File::NULL, err: err_path)
    abort "guarded_fiber_reach_report: bc2cpp.rb failed:\n#{File.read(err_path).lines.last(20).join}" unless ok
    abort 'guarded_fiber_reach_report: no sound closed-world analysis was recorded (see bc2cpp stderr)' unless File.file?(dump_path)

    d = JSON.parse(File.read(dump_path))
    puts "GUARDED_FIBER_REACH closed world: #{sources.size} mrblib sources"
    puts "  core methods under CORE_BLOCK_GUARD:                     #{d['guarded']}"
    puts "  Fiber bodies in the closed world:                        #{d['fiber_bodies'].size}"
    d['fiber_bodies'].each { |b| puts "    #{b['file']} (irep #{b['label']})" }
    puts "  guarded methods a Fiber body can reach:                  #{d['crossable']}"
    puts "  guarded methods whose body cannot suspend (relaxable):   #{d['relaxable']}"
    puts "  reached by a Fiber body and relaxable (block decides):   #{d['crossable_relaxable']}"
    puts "  guarded methods no Fiber body reaches:                   #{d['guarded'] - d['crossable']}"
    enumerable = d['methods'].count { |r| r['key'].start_with?('Enumerable#') }
    puts "  of the guarded methods, Enumerable# (guard also tests that each is the builtin one): #{enumerable}"
    puts "  guarded methods outside Enumerable#:                     #{d['guarded'] - enumerable}"
    puts "  Fiber roots / Fiber-unsafe methods (non-guarded):        #{d['fiber_roots']} / #{d['fiber_unsafe_methods']}"
    c = d['census']
    puts "  Fiber.new call sites:                                    #{c['fiber_new'].size}"
    c['fiber_new'].each { |s| puts "    #{s}" }
    puts "  Fiber.yield/current sites:                               #{c['fiber_yield'].values.sum}"
    puts "  external-iteration sends (#{ENTRY_NAMES.join(' ')}): #{c['entry_sends'].values.sum}"
    c['entry_sends'].sort.each { |k, v| puts "    #{k}: #{v}" }
    puts "  external-iteration literal symbols:                      #{c['entry_literals'].values.sum}"
    c['entry_literals'].sort.each { |k, v| puts "    #{k}: #{v}" }
    puts "  dynamic send sites (send, __send__, public_send):        #{c['dynamic_sends'].values.sum}"
    c['dynamic_sends'].sort.each { |k, v| puts "    #{k}: #{v}" }
    if list
      puts '  guarded methods:'
      d['methods'].sort_by { |r| [r['crossable'] ? 0 : 1, r['key']] }.each do |r|
        puts "    #{r['crossable'] ? 'reach' : 'none '} #{r['key']} (#{r['file']})"
      end
    end
  end
end
