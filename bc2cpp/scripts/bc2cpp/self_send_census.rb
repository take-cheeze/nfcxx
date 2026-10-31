#!/usr/bin/env ruby
# frozen_string_literal: true

# Self-send census (docs/bc2cpp-self-send.md): every send whose receiver is `self` in the closed world's compiled
# engine Ruby (mruby-rpg2k, mruby-lcf, mruby-rgss mrblib), and what the generated C++ does with it.
#
#   MRBC=path/to/host/mrbc ruby scripts/bc2cpp/self_send_census.rb [--all] [--tsv FILE]
#
# Two steps. A bc2cpp pass runs in a child process with this file loaded by `ruby -r`: its prepended hook on CodeGen
# records the outcome of every compile_send of a self-receiver send (SSEND family, or a SEND whose receiver register
# only ever holds LOADSELF) and the compile result of every method, without changing the output (the hooked output is
# byte-identical to an unhooked run). The parent then reads the same bytecode through BytecodeIR, lists each send
# instruction, and joins it to the child's record by (irep label, instruction address). Sends with no record are
# counted as such, not guessed. --all keeps the core mruby mrblib in the table as well.
#
# The outcome of a site, from the text compile_send returned for it:
#   direct       a C++ call with no by-name dispatch and no owner-table call;
#   owner_table  bc2cpp_owner_call: a method-table lookup by name id in a closed list of owners, then the method's entry;
#   by_name      mrb_funcall*/bc2cpp_send*/bc2cpp_funcall* only;
#   guarded      a direct call with a by-name else arm;
#   refused      `#error` in the text (none in the closed world today).
# Class and module bodies are a separate kind: their sends run in the class-body load program, not in a method.

require 'json'
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'

module SelfSendCensus
  OUT_ENV = 'SELF_SEND_CENSUS_OUT'
  SELF_FAMILY = %i[SSEND SSEND0 SSENDB SSENDV SSENDVB].freeze
  SEND_FAMILY = %i[SEND SEND0 SENDB SENDV SENDVB].freeze
  BY_NAME = /\bmrb_funcall\w*\(|\bbc2cpp_send\w*\(|\bbc2cpp_funcall\w*\(|\bbc2cpp_nil_receiver\w*\(/
  OWNER_TABLE = /\bbc2cpp_owner_call\w*\(/
  DIRECT = /\w_impl\(|\b(?:mrb_\w+|bc2cpp_\w+)_direct\w*\(/
  ENGINE = %r{/mruby-(rpg2k|lcf|rgss)/}

  # Child side: the hook. Only installed when OUT_ENV is set, so the parent process is not affected.
  SITES = {}
  METHODS = {}
  STACK = []

  def self.classify(code)
    return { outcome: 'refused', reason: code[/^\s*#error (.*)$/, 1].to_s[0, 160], line: '' } if code.include?('#error')

    poly = code[/POLY_DIAG path=(\S+) receiver=(\S+)/]
    marker = code.lines.map { |l| l[%r{^\s*// ([A-Z_]+)\b}, 1] }.compact.first
    reason = poly ? poly.sub('POLY_DIAG ', '') : (marker || 'none')
    line = (code.lines.find { |l| l.match?(BY_NAME) || l.match?(OWNER_TABLE) } ||
            code.lines.find { |l| !l.start_with?('  //') } || '').strip[0, 220]
    outcome = if code.match?(BY_NAME) then code.match?(DIRECT) ? 'guarded' : 'by_name'
              elsif code.match?(OWNER_TABLE) then 'owner_table'
              else 'direct'
              end
    { outcome: outcome, reason: reason, line: line }
  end

  module Hook
    def compile_send(insn, **kwargs)
      code = super
      irep = kwargs[:irep]
      idx = kwargs[:idx]
      self_receiver = SelfSendCensus::SELF_FAMILY.include?(insn.op) ||
                      (SelfSendCensus::SEND_FAMILY.include?(insn.op) && kwargs[:call_receiver].nil? && irep && idx &&
                       receiver_loaded_self?("r#{insn.reg}", irep, idx))
      if self_receiver && irep
        result = SelfSendCensus.classify(code.to_s)
        SelfSendCensus::SITES[[irep.label, insn.addr]] = {
          label: irep.label, addr: insn.addr, op: insn.op.to_s, name: insn.sym.to_s, argc: insn.argc.to_i,
          method: SelfSendCensus::STACK.last, outcome: result[:outcome], reason: result[:reason].to_s,
          line: result[:line].to_s
        }
      end
      code
    end

    def compile_method(label)
      SelfSendCensus::STACK.push(label)
      begin
        res = super
      ensure
        SelfSendCensus::STACK.pop
      end
      code = res.is_a?(Hash) ? res[:code].to_s : ''
      SelfSendCensus::METHODS[label] = { error: code[/^\s*#error (.*)$/, 1].to_s[0, 200] }
      res
    end
  end

  def self.install_hook!
    TracePoint.new(:class) do |tp|
      next unless tp.self.is_a?(Class) && tp.self.name == 'CodeGen' && !tp.self.ancestors.include?(Hook)

      tp.self.prepend(Hook)
    end.enable
    at_exit do
      File.write("#{ENV.fetch(OUT_ENV)}/sites.jsonl", SITES.values.map { |row| JSON.generate(row) }.join("\n") + "\n")
      File.write("#{ENV.fetch(OUT_ENV)}/methods.jsonl",
                 METHODS.map { |label, row| JSON.generate(row.merge(label: label)) }.join("\n") + "\n")
    end
  end
end

SelfSendCensus.install_hook! if ENV[SelfSendCensus::OUT_ENV]

if $PROGRAM_NAME == __FILE__
  ROOT = File.expand_path('../..', __dir__)
  BC2CPP = File.join(ROOT, 'tools/bc2cpp/bc2cpp.rb')
  $LOAD_PATH.unshift(File.join(ROOT, 'tools/bc2cpp'))
  require 'compiled_gems'
  require 'nomethod_reviewed_probe'
  require 'closed_world_env'

  args = ARGV.dup
  include_core = !args.delete('--all').nil?
  tsv = nil
  if (index = args.index('--tsv'))
    tsv = args[index + 1] or abort 'usage: --tsv FILE'
    args.slice!(index, 2)
  end
  abort "usage: #{$PROGRAM_NAME} [--all] [--tsv FILE]" unless args.empty?
  mrbc = ENV.fetch('MRBC') { abort 'set MRBC to a host mrbc (for example build-closed-bc2cpp/host/mrbc/bin/mrbc)' }

  srcs = closed_world_mrblib_srcs(ROOT)
  native_srcs = bc2cpp_rgss_native_srcs(ROOT, 'closed') + core_native_srcs("#{ROOT}/3rd/mruby") +
                external_gem_native_srcs(ROOT)
  all_owners = BC2CPP_COMPILED_GEMS.values.flat_map { |g| g[:owners] }
  env = {
    'MRBC' => mrbc, 'OUT_SYMBOL' => 'coverage_report', 'ONLY_OWNERS' => all_owners.join(','),
    'NATIVE_SRCS' => Shellwords.join(native_srcs), 'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(ROOT)),
    'BC2CPP_BUILD_NAME' => 'closed', 'BC2CPP_COLLECTION_EXPORTS' => '1',
    'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.closed_gems(ROOT).map { |n, d| "#{n}=#{d}" })
  }

  Dir.mktmpdir('self_send_census') do |dir|
    # The same pass coverage_report.rb's first run makes, without SKIP_UNSUPPORTED: refused bodies stay visible.
    child_env = bc2cpp_closed_world_probe_env(env.merge('OUT_DIR' => dir)).merge(SelfSendCensus::OUT_ENV => dir)
    cmd = [RbConfig.ruby, '-r', File.expand_path(__FILE__), BC2CPP, '--annotated', *srcs]
    _out, err, status = Open3.capture3(child_env, *cmd)
    raise "bc2cpp.rb failed (exit #{status.exitstatus}):\n#{NomethodReviewedProbe.failure_tail(err)}" unless status.success?

    sites = File.readlines(File.join(dir, 'sites.jsonl'), chomp: true).reject(&:empty?).map { |l| JSON.parse(l) }
    sites = sites.to_h { |row| [[row['label'], row['addr']], row] }
    methods = File.readlines(File.join(dir, 'methods.jsonl'), chomp: true).reject(&:empty?).map { |l| JSON.parse(l) }
    refused = methods.select { |row| !row['error'].to_s.empty? }.to_h { |row| [row['label'], row['error']] }

    require_relative '../../tools/bc2cpp/bc2cpp'
    ireps, root = compile_ireps(srcs, 'coverage_report', dir, mrbc: mrbc)
    class_bodies = {}
    blocks = {}
    ireps.each_value do |irep|
      BytecodeIR.class_bodies(irep, :CLASS, :MODULE, :SCLASS).each_value { |child| class_bodies[child] = true }
      irep.each_with_op(:BLOCK, :LAMBDA) { |insn, _| (child = irep.reps[insn.block_index]) && (blocks[child] = true) }
    end
    loaded_self = lambda do |irep, idx, reg|
      defs = BytecodeIR.reaching_definitions(irep, idx, reg, through_handlers: true, shared: true)
      !defs.nil? && !defs.empty? && defs.all? { |d| !d.entry? && BytecodeIR.for(irep).source_at(d.index).op == :LOADSELF }
    end

    rows = []
    ireps.each do |label, irep|
      next unless include_core || irep.file.to_s.match?(SelfSendCensus::ENGINE)

      kind = if label == root then 'top'
             elsif class_bodies[label] then 'class_body'
             elsif blocks[label] then 'block'
             else 'method'
             end
      irep.instructions.each_with_index do |insn, idx|
        next unless insn
        next unless SelfSendCensus::SEND_FAMILY.include?(insn.op) || SelfSendCensus::SELF_FAMILY.include?(insn.op)

        self_recv = SelfSendCensus::SELF_FAMILY.include?(insn.op) ||
                    (%i[SEND SEND0 SENDB].include?(insn.op) && loaded_self.call(irep, idx, insn.reg))
        next unless self_recv

        site = sites[[label, insn.addr]]
        outcome, reason, line = if kind == 'class_body' then ['class_body', 'class or module body (load program)', '']
                                elsif site.nil? && refused.key?(label) then ['refused', refused[label], '']
                                elsif site.nil? then ['not_recorded', 'literal-block send, no compile_send call', '']
                                else [site['outcome'], site['reason'], site['line']]
                                end
        rows << { label: label, file: irep.file.to_s, kind: kind, lineno: insn.lineno, op: insn.op.to_s,
                  name: insn.sym.to_s, argc: insn.argc.to_i, outcome: outcome, reason: reason, line: line }
      end
    end

    total = rows.size
    share = ->(n) { format('%5.1f%%', total.zero? ? 0 : 100.0 * n / total) }
    short = ->(file) { file.sub(%r{.*/(mruby-[a-z0-9-]+/)}, '\1') }
    puts "self-receiver sends: #{total} (SSEND family #{rows.count { |r| r[:op].start_with?('SSEND') }}, " \
         "SEND with a LOADSELF receiver #{rows.count { |r| !r[:op].start_with?('SSEND') }})"
    puts format('%-14s %6s %7s  %s', 'outcome', 'count', 'share', 'example (file:line :name, reason)')
    rows.group_by { |r| r[:outcome] }.sort_by { |_, rs| -rs.size }.each do |outcome, rs|
      example = rs.first
      puts format('%-14s %6d %7s  %s:%d :%s, %s', outcome, rs.size, share.call(rs.size), short.call(example[:file]),
                  example[:lineno], example[:name], example[:reason])
    end
    puts
    puts 'by reason (outcome, reason, count, example):'
    rows.group_by { |r| [r[:outcome], r[:reason]] }.sort_by { |(o, rs_reason), rs| [o, -rs.size] }.each do |(o, reason), rs|
      example = rs.first
      puts format('  %-12s %-50s %5d  %s:%d :%s', o, reason.to_s[0, 50], rs.size, short.call(example[:file]),
                  example[:lineno], example[:name])
    end
    File.write(tsv, (['label file kind lineno op name argc outcome reason line'] +
                     rows.map { |r| r.values_at(:label, :file, :kind, :lineno, :op, :name, :argc, :outcome, :reason, :line).join("\t") }
                    ).join("\n") + "\n") if tsv
  end
end
