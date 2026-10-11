#!/usr/bin/env ruby
# frozen_string_literal: true

# Shadow check for codegen_rescue.rb's ensure/rescue recognizers: bc2cpp is run
# over the real closed world with a hook that also evaluates the frozen
# pre-BytecodeIR implementations (the Legacy module below) on every call to
# recognize_ensure_region, recognize_rescue_class_handler and
# jmpuw_is_plain_jump?, and fails on any differing answer. The Legacy code is a
# verbatim copy of the hand-rolled control-flow reasoning those methods used
# before it moved onto BytecodeIR queries; it is never called by the compiler.
#
# Usage: MRBC=path/to/host/mrbc ruby scripts/bc2cpp/rescue_shadow_check.rb

if ENV['BC2CPP_RESCUE_SHADOW_CHILD']
  # Hook mode (ruby -r this_file bc2cpp.rb): prepend the comparing wrappers once
  # codegen_rescue.rb has defined its methods.
  module RescueShadowLegacy
    def legacy_jmpuw_is_plain_jump?(irep)
      irep.catch_handlers.nil? || irep.catch_handlers.empty?
    end

    def legacy_recognize_ensure_region(irep)
      return nil if irep.catch_handlers.nil?
      return nil unless irep.catch_handlers.size == 1

      ch = irep.catch_handlers.first
      return nil unless ch.type == :ensure
      return nil unless ch.end_addr == ch.target

      program = BytecodeIR.for(irep)
      b, t = ch.begin_addr, ch.target
      return nil unless program.insn_at_addr(b)

      exc = program.insn_at_addr(t)
      return nil unless exc && exc.op == 'EXCEPT'

      exc_reg = exc.regs.first
      return nil unless exc_reg

      after = irep.instructions_at((t + 1)..)
      raiseif = after.find { |i| i.op == 'RAISEIF' && i.regs.first == exc_reg }
      return nil unless raiseif

      body = irep.instructions_at((t + 1)...raiseif.addr)
      return nil if body.any? do |i|
        %w[RETURN RETURN_BLK BREAK BLOCK SENDB SSENDB LAMBDA EXCEPT RAISEIF].include?(i.op)
      end
      return nil if body.any? do |i|
        jt = i.branch_target
        jt && !(jt > t && jt <= raiseif.addr)
      end

      protected_range = (b...ch.end_addr)
      except_jump_srcs = []
      program.branch_edges.each do |edge|
        next if ((t + 1)...raiseif.addr).cover?(edge.src)

        if edge.target == t
          return nil unless protected_range.cover?(edge.src)

          except_jump_srcs << edge.src
          next
        end
        return nil if protected_range.cover?(edge.src) != protected_range.cover?(edge.target)
      end
      { begin_addr: b, except_addr: t, raiseif_addr: raiseif.addr, body_insns: body,
        except_jump_srcs: except_jump_srcs }
    end

    def legacy_recognize_rescue_class_handler(irep, program, except_i, exc_reg)
      clause_idx = irep.index_of_addr(except_i.addr)
      return nil unless clause_idx

      clause_idx += 1
      cls_names = []
      first_match_addr = nil

      loop do
        getconst_i = irep.instructions[clause_idx]
        return nil unless getconst_i && getconst_i.op == 'GETCONST'

        cls_reg = getconst_i.reg
        cls_name = getconst_i.const_name
        return nil unless cls_reg && cls_name
        return nil if cls_reg == exc_reg

        seg_idx = clause_idx + 1
        while (seg_i = irep.instructions[seg_idx]) && seg_i.op == 'GETMCNST'
          return nil unless seg_i.reg == cls_reg && seg_i.paren_reg == cls_reg && seg_i.mcnst_name

          cls_name = "#{cls_name}::#{seg_i.mcnst_name}"
          seg_idx += 1
        end

        rescue_i, jmpif_i, jmp_i = irep.instructions[seg_idx, 3]
        return nil unless rescue_i && jmpif_i && jmp_i
        return nil unless rescue_i.op == 'RESCUE' && rescue_i.regs == [exc_reg, cls_reg]
        return nil unless jmpif_i.op == 'JMPIF' && jmpif_i.reg == cls_reg

        match_addr = jmpif_i.uint_operand.to_i
        return nil unless match_addr && match_addr > jmpif_i.addr
        return nil unless jmp_i.op == 'JMP'

        next_addr = jmp_i.jmp_addr
        return nil unless next_addr > jmp_i.addr

        cls_names << cls_name
        first_match_addr ||= match_addr

        next_i = program.insn_at_addr(next_addr)
        return nil unless next_i

        if next_i.op == 'RAISEIF'
          return nil unless next_i.reg == exc_reg

          return { kind: :rescue_class, cls_name: cls_names.join(', '),
                   match_addr: first_match_addr, raise_addr: next_addr }
        end

        return nil unless next_i.op == 'GETCONST'

        clause_idx = irep.index_of_addr(next_i.addr)
        return nil unless clause_idx
      end
    end
  end

  module RescueShadow
    STATS = Hash.new(0)
    MISMATCHES = []

    def self.compare(name, new, old, key)
      STATS["#{name} calls"] += 1
      STATS["#{name} #{new ? 'accepted' : 'rejected'}"] += 1
      MISMATCHES << "#{name} #{key}: new=#{new.inspect[0, 200]} old=#{old.inspect[0, 200]}" unless new == old
      new
    end

    def jmpuw_is_plain_jump?(irep)
      RescueShadow.compare('jmpuw_is_plain_jump?', super, legacy_jmpuw_is_plain_jump?(irep), irep.label)
    end

    def recognize_ensure_region(irep)
      RescueShadow.compare('recognize_ensure_region', super, legacy_recognize_ensure_region(irep), irep.label)
    end

    def recognize_rescue_class_handler(irep, program, except_i, exc_reg)
      RescueShadow.compare('recognize_rescue_class_handler', super,
                           legacy_recognize_rescue_class_handler(irep, program, except_i, exc_reg),
                           "#{irep.label}@#{except_i.addr}")
    end
  end

  installed = false
  TracePoint.new(:end) do |tp|
    next if installed || tp.self.name != 'CodeGen'

    next unless tp.self.method_defined?(:recognize_rescue_class_handler)

    installed = true
    tp.disable
    tp.self.include(RescueShadowLegacy)
    tp.self.prepend(RescueShadow)
  end.enable

  at_exit do
    File.write(ENV.fetch('BC2CPP_RESCUE_SHADOW_REPORT'),
               Marshal.dump([installed, RescueShadow::STATS.to_a, RescueShadow::MISMATCHES]))
  end
else
  require 'open3'
  require 'shellwords'
  require 'tmpdir'
  require_relative '../../tools/bc2cpp/compiled_gems'
  require_relative '../../tools/bc2cpp/nomethod_reviewed_probe'

  root = File.expand_path('../..', __dir__)
  srcs = closed_world_mrblib_srcs(root)
  native_srcs = Dir["#{root}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{root}/3rd/mruby") +
                external_gem_native_srcs(root)
  owners = BC2CPP_COMPILED_GEMS.values.flat_map { |g| g[:owners] }

  Dir.mktmpdir do |dir|
    report = File.join(dir, 'report.bin')
    env = {
      'MRBC' => ENV['MRBC'] || 'mrbc', 'OUT_SYMBOL' => 'rescue_shadow', 'OUT_DIR' => dir,
      'ONLY_OWNERS' => owners.join(','), 'NATIVE_SRCS' => Shellwords.join(native_srcs),
      'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(root)),
      'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
      'BC2CPP_BUILD_GEMS' => Shellwords.join(NomethodReviewedProbe.wio_gems(root).map { |n, d| "#{n}=#{d}" }),
      NomethodReviewed::ALLOW_ENV => 'allow',
      'BC2CPP_RESCUE_SHADOW_CHILD' => '1', 'BC2CPP_RESCUE_SHADOW_REPORT' => report
    }
    cmd = [RbConfig.ruby, "-r#{File.expand_path(__FILE__)}", File.join(root, 'tools/bc2cpp/bc2cpp.rb'), *srcs]
    _out, err, status = Open3.capture3(env, *cmd)
    abort("bc2cpp failed (exit #{status.exitstatus}):\n#{err[-4000..]}") unless status.success?

    installed, stats, mismatches = Marshal.load(File.binread(report))
    stats = stats.to_h
    abort('bc2cpp_rescue_shadow_check FAILED: hook never installed') unless installed
    # A vacuous run (nothing recognized) would prove nothing.
    %w[recognize_ensure_region\ accepted recognize_rescue_class_handler\ accepted
       jmpuw_is_plain_jump?\ calls].each do |k|
      abort("bc2cpp_rescue_shadow_check FAILED: no #{k} observed (#{stats})") unless stats[k].to_i.positive?
    end
    abort("bc2cpp_rescue_shadow_check FAILED:\n#{mismatches.first(20).join("\n")}") unless mismatches.empty?
    puts "bc2cpp_rescue_shadow_check OK #{stats.sort.map { |k, v| "#{k}=#{v}" }.join(', ')}"
  end
end
