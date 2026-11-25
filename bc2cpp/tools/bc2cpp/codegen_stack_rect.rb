# frozen_string_literal: true

require 'set'
require_relative 'world_root'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_containers'
require_relative 'escape_analysis'

# STACK_RECT: a `Rect.new(x, y, w, h)` whose only uses are rect arguments of the RGSS Bitmap draws in
# STACK_RECT_CONSUMERS keeps its four fields in a frame-local rgss::RectFields instead of a heap RGSS::Rect, and the
# draw takes the fields (include/rgss_construct.hxx, the *_rects_direct entries).
#
# A site is placed only when all of these hold (refusal is always the answer when unsure):
#   construction  the site's own text is the unconditional direct construction
#                 `rL = rgss::rect_new_direct(M, rgss::native_rect_class(), ...)`, so its class is proven RGSS::Rect
#                 and the four fields are converted exactly where the Rect would have been made
#   closures      the irep builds no BLOCK or LAMBDA, which could read the frame's register by pointer
#   uses          every instruction that reads a register which may hold the Rect is a MOVE or a consumer send
#                 reading it at one of its rect positions, and every reaching definition of that register there is
#                 the site (through MOVEs and handler edges)
#   params        no parameter register may hold it (ARGARY / zsuper read those without naming them)
#   consumer      the consumer's text is that draw's direct native call (bitmap_*_direct): its receiver class is
#                 proven or guarded exactly as without the plan. A guarded call's else arm materialises the Rect
#                 from the fields before the dispatch it already makes, so only a site with a single consumer may
#                 have a guarded one (no second object is ever made for it)
#   entries       the world's include/rgss_construct.hxx declares every *_rects_direct entry
# The consumers are non-retaining by their C++ source: each reads the Rect's fields into a `const Rect&` and keeps
# neither the object nor a pointer (scripts/bc2cpp/stack_rect_check.rb audits mruby-rgss/src/lib.cxx).
#
# A planned instruction a path bypasses (suppressed, glued, behind a guarded prefix, in a resumable or shifted body),
# or whose text is not the shape above, drops its site and the method compiles again without it.
class CodeGen
  # name => { argc: accepted counts, slots: rect argument positions, entry: the fields entry point }
  STACK_RECT_CONSUMERS = {
    'blt' => { argc: [4, 5], slots: [3], direct: 'bitmap_blt_direct', entry: 'bitmap_blt_rects_direct' },
    'stretch_blt' => { argc: [3, 4], slots: [0, 2], direct: 'bitmap_stretch_blt_direct',
                       entry: 'bitmap_stretch_blt_rects_direct' },
    'copy_blt' => { argc: [4], slots: [3], direct: 'bitmap_copy_blt_direct', entry: 'bitmap_copy_blt_rects_direct' }
  }.freeze
  STACK_RECT_HEADER = 'include/rgss_construct.hxx'

  # One placed Rect.new: +lead+ its register, +consumers+ {instruction index => [slot, ...]}.
  StackRectSite = Struct.new(:idx, :lead, :consumers, keyword_init: true)

  def stack_rect_enabled?
    ENV['BC2CPP_STACK_RECT'] != '0' && CodeGen.stack_rect_entries?
  end

  # Whether the world declares every fields entry point (an older world compiles without the plan).
  def self.stack_rect_entries?
    return @stack_rect_entries unless @stack_rect_entries.nil?

    path = File.join(BC2CPP_WORLD_ROOT, STACK_RECT_HEADER)
    text = File.exist?(path) ? File.read(path) : ''
    @stack_rect_entries = text.include?('struct RectFields') &&
                          STACK_RECT_CONSUMERS.values.all? { |c| text.match?(/\b#{c[:entry]}\(/) }
  end

  # The plan for +irep+: {Rect.new index => StackRectSite}.
  def stack_rect_plan(irep)
    return {} unless stack_rect_enabled?

    prog = BytecodeIR.for(irep)
    creations = prog.instructions.select { |ins| stack_rect_new?(ins.source) }
    return {} if creations.empty?

    @stack_rect_where = irep.label
    return stack_rect_refuse(:closure_in_irep) || {} unless EscapeAnalysis.op_sites(irep, EscapeAnalysis::CLOSURE_OP_LIST).empty?
    return stack_rect_refuse(:cfg_or_handlers_unresolved) || {} unless prog.resolved? && prog.handlers_resolved?

    params = stack_tuple_params(irep)
    plan = {}
    creations.each do |ins|
      @stack_rect_where = "#{irep.label}##{ins.index}"
      site = stack_rect_site(irep, prog, ins.index, params)
      plan[ins.index] = site if site
    end
    plan
  end

  # Runs the block (the method's compile) under the plan; a site that was not placed whole is dropped and the method
  # compiles again, until every planned site is placed or none is left.
  def stack_rect_compile_method(label)
    irep = @ireps.fetch(label)
    plan = stack_rect_plan(irep)
    loop do
      warn "bc2cpp stack rect #{label}: #{plan.keys}" if ENV['BC2CPP_STACK_RECT_REPORT'] == '1' && !plan.empty?
      return yield if plan.empty?

      state = { label: label, plan: plan, map: stack_rect_map(plan), hooked: Set.new, missed: Set.new }
      saved = @stack_rect_state
      @stack_rect_state = state
      text = begin
        yield
      ensure
        @stack_rect_state = saved
      end
      missed = state[:missed] | plan.values.reject { |site| stack_rect_site_hooked?(state, site) }.map(&:idx)
      return text if missed.empty?

      warn "bc2cpp stack rect #{label}: not placed #{missed.sort}" if ENV['BC2CPP_STACK_RECT_REPORT'] == '1'
      plan = plan.reject { |idx, _| missed.include?(idx) }
    end
  end

  # The declarations of the placed fields of the method body +irep+ (empty without a plan).
  def stack_rect_declarations(irep)
    state = @stack_rect_state
    return '' unless state && state[:label] == irep.label

    state[:plan].keys.map { |idx| "  rgss::RectFields #{stack_rect_name(idx)} = {0, 0, 0, 0};\n" }.join
  end

  # Called from the method's instruction loop, as stack_tuple_visit.
  def stack_rect_visit(irep, idx, bypassed)
    state = @stack_rect_state
    return unless bypassed && state && state[:label] == irep.label

    Array(state[:map][idx]).each { |site| state[:missed] << site.idx }
  end

  # The text of the planned instruction +idx+, from +text+ (what every other wrapper emitted for it).
  def stack_rect_insn(irep, idx, reg_offset, text)
    state = @stack_rect_state
    return text unless state && idx && irep && state[:label] == irep.label

    sites = state[:map][idx]
    return text unless sites
    if reg_offset != 0 || @resumable || !text.is_a?(String)
      sites.each { |site| state[:missed] << site.idx }
      return text
    end

    placed = if state[:plan].key?(idx)
               stack_rect_site_text(state[:plan][idx], text)
             else
               stack_rect_consumer_text(irep, idx, sites, text)
             end
    unless placed
      sites.each { |site| state[:missed] << site.idx }
      return text
    end
    state[:hooked] << idx
    @native_construct_used << 'RGSS::Rect' << 'RGSS::Bitmap'
    placed
  end

  private

  def stack_rect_name(idx)
    "bc2cpp_srect#{idx}"
  end

  def stack_rect_refuse(reason)
    warn "bc2cpp stack rect refused at #{@stack_rect_where}: #{reason}" if ENV['BC2CPP_STACK_RECT_REPORT'] == '1'
    nil
  end

  def stack_rect_new?(insn)
    insn.op == :SEND && insn.sym == 'new' && insn.argc == 4 && !insn.keyword_arguments? && !insn.positional_splat?
  end

  def stack_rect_consumer_insn?(insn)
    spec = STACK_RECT_CONSUMERS[insn.sym]
    spec && insn.op == :SEND && spec[:argc].include?(insn.argc) && !insn.keyword_arguments? &&
      !insn.positional_splat?
  end

  # {instruction index => [StackRectSite, ...]}: each site's own instruction and its consumers.
  def stack_rect_map(plan)
    map = {}
    plan.each_value do |site|
      (map[site.idx] ||= []) << site
      site.consumers.each_key { |j| (map[j] ||= []) << site }
    end
    map
  end

  def stack_rect_site_hooked?(state, site)
    state[:hooked].include?(site.idx) && site.consumers.keys.all? { |j| state[:hooked].include?(j) }
  end

  def stack_rect_site(irep, prog, idx, params)
    lead = reg_int(prog.source_at(idx).reg)
    return stack_rect_refuse(:no_lead) unless lead

    tracked = stack_rect_tracked(irep, prog, idx, lead)
    return stack_rect_refuse(:parameter_register) if tracked.any? { |reg| reg.between?(1, params + 1) }

    consumers = {}
    prog.instructions.each do |ins|
      j = ins.index
      insn = ins.source
      next if j == idx || insn.op == :MOVE

      reads = stack_tuple_reads(insn, params)
      candidates = reads == :all ? tracked.to_a : reads.select { |reg| tracked.include?(reg) }
      candidates.each do |reg|
        prods = BytecodeIR.producers(irep, j, reg, through_handlers: true)
        return stack_rect_refuse("no_producers for r#{reg} read by #{insn.op} at #{j}") if prods.nil? || prods.empty?

        holding = prods.count { |p| !p.entry? && p.index == idx }
        next if holding.zero?
        return stack_rect_refuse(:mixed_definitions) unless holding == prods.size

        slot = stack_rect_slot(insn, reg)
        return stack_rect_refuse("read by #{insn.op} #{insn.sym} at #{j}") unless slot
        return stack_rect_refuse(:read_twice) if consumers[j]&.include?(slot)

        (consumers[j] ||= []) << slot
      end
    end
    return stack_rect_refuse(:no_consumer) if consumers.empty?
    return stack_rect_refuse(:two_slots_one_consumer) if consumers.values.any? { |slots| slots.size > 1 }

    StackRectSite.new(idx: idx, lead: lead, consumers: consumers.transform_values(&:first))
  end

  # The rect position +reg+ takes in the consumer send +insn+, or nil.
  def stack_rect_slot(insn, reg)
    return nil unless stack_rect_consumer_insn?(insn)

    k = reg - reg_int(insn.reg) - 1
    STACK_RECT_CONSUMERS.fetch(insn.sym)[:slots].include?(k) ? k : nil
  end

  # The registers that may hold the site's value: its own, and every MOVE destination copied from one of them.
  def stack_rect_tracked(irep, prog, idx, lead)
    tracked = Set[lead]
    loop do
      grown = false
      prog.instructions.each do |ins|
        insn = ins.source
        next unless insn.op == :MOVE

        dst = reg_int(insn.regs[0])
        src = reg_int(insn.regs[1])
        next if tracked.include?(dst) || !tracked.include?(src)

        prods = BytecodeIR.producers(irep, ins.index, src, through_handlers: true)
        next unless prods.nil? || prods.any? { |p| !p.entry? && p.index == idx }

        tracked << dst
        grown = true
      end
      return tracked unless grown
    end
  end

  SITE_CALL = /^(\s*)r(\d+) = rgss::rect_new_direct\(M, rgss::native_rect_class\(\), ([^,()]+), ([^,()]+), ([^,()]+), ([^,()]+)\);\n/

  # +text+ without its // and /* */ comments, which name the calls and arms they describe.
  def stack_rect_code(text)
    text.gsub(%r{/\*.*?\*/}m, '').gsub(%r{//[^\n]*}, '')
  end

  # The site's own text with the construction replaced by the fields, or nil when it is not the unconditional form.
  def stack_rect_site_text(site, text)
    code = stack_rect_code(text)
    return nil if code.scan('rect_new_direct').size != 1 || code.match?(/\b(?:if|else|goto|return|case)\b|\?/)

    m = SITE_CALL.match(text)
    return nil unless m && m[2].to_i == site.lead

    fields = "#{stack_rect_name(site.idx)} = rgss::RectFields{#{m[3]}, #{m[4]}, #{m[5]}, #{m[6]}};"
    text.sub(SITE_CALL) { "#{m[1]}// STACK_RECT: the Rect stays as its fields\n#{m[1]}#{fields} r#{site.lead} = mrb_nil_value();\n" }
  end

  # The consumer's text with its direct call taking the placed fields, or nil when it is not that call.
  def stack_rect_consumer_text(irep, j, sites, text)
    insn = BytecodeIR.for(irep).source_at(j)
    spec = STACK_RECT_CONSUMERS[insn.sym]
    code = stack_rect_code(text)
    return nil unless spec && code.scan("rgss::#{spec[:direct]}(").size == 1 && text.scan("rgss::#{spec[:direct]}(").size == 1
    return nil if code.match?(/\b(?:goto|return|case)\b|\?/)

    m = /rgss::#{spec[:direct]}\(M,\s*([^;]*?)\);/m.match(text)
    return nil unless m

    args = m[1].split(/,\s*/)
    lead = reg_int(insn.reg)
    by_slot = sites.to_h { |site| [site.consumers.fetch(j), site] }
    guarded = code.match?(/\bif\b/)
    if guarded
      # Only `if (guard) { direct call } else { dispatch }`. The else arm makes the Rect, once: so its site may have
      # no other consumer.
      return nil unless code.scan(/\bif\b/).size == 1 && code.scan(/\belse\b/).size == 1
      return nil unless code.index("rgss::#{spec[:direct]}(") < code.index(/\belse\b/)
      return nil if by_slot.values.any? { |site| site.consumers.size != 1 }
    end

    call = stack_rect_entry_call(spec, args, by_slot, lead)
    return nil unless call

    out = text.sub(m[0]) { "#{call};" }
    return out unless guarded

    made = by_slot.map do |slot, site|
      f = stack_rect_name(site.idx)
      "r#{lead + 1 + slot} = rgss::rect_new_direct(M, rgss::native_rect_class(), #{f}.x, #{f}.y, #{f}.width, " \
        "#{f}.height);"
    end
    at = out.index(/\belse \{\n/, out.index(call))
    return nil unless at

    stop = at + 'else {\n'.size
    out[0...stop] + "    #{made.join("\n    ")}\n" + out[stop..]
  end

  # The fields entry call for the direct call's +args+ (receiver first), or nil when an argument is not the expected
  # register.
  def stack_rect_entry_call(spec, args, by_slot, lead)
    recv, *rest = args
    by_slot.each_key { |slot| return nil unless rest[slot] == "r#{lead + 1 + slot}" }
    field = ->(slot) { "#{stack_rect_name(by_slot.fetch(slot).idx)}" }
    case spec[:entry]
    when 'bitmap_blt_rects_direct'
      return nil unless rest.size == 6 && by_slot.keys == [3]

      "rgss::bitmap_blt_rects_direct(M, #{recv}, #{rest[0]}, #{rest[1]}, #{rest[2]}, #{field.call(3)}, " \
        "#{rest[4]}, #{rest[5]})"
    when 'bitmap_stretch_blt_rects_direct'
      return nil unless rest.size == 5

      ptr = ->(slot) { by_slot.key?(slot) ? "&#{field.call(slot)}" : 'nullptr' }
      "rgss::bitmap_stretch_blt_rects_direct(M, #{recv}, #{rest[0]}, #{ptr.call(0)}, #{rest[1]}, #{rest[2]}, " \
        "#{ptr.call(2)}, #{rest[3]}, #{rest[4]})"
    when 'bitmap_copy_blt_rects_direct'
      return nil unless rest.size == 4 && by_slot.keys == [3]

      "rgss::bitmap_copy_blt_rects_direct(M, #{recv}, #{rest[0]}, #{rest[1]}, #{rest[2]}, #{field.call(3)})"
    end
  end
end

# Prepended to CodeGen: compile_method runs under a plan and retries without the sites that were not placed.
module StackRectCompileMethod
  def compile_method(label)
    stack_rect_compile_method(label) { super(label) }
  end
end

# Prepended to CodeGen, outermost: rewrites the text every other wrapper settled on.
module StackRectCompileInsn
  def compile_insn(insn, irep, owner_def, idx = nil, reg_offset = 0)
    stack_rect_insn(irep, idx, reg_offset, super)
  end
end

CodeGen.prepend(StackRectCompileMethod)
CodeGen.prepend(StackRectCompileInsn)
