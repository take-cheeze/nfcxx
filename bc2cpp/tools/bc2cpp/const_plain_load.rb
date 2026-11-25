# frozen_string_literal: true

require 'set'
require_relative 'world_root'
require_relative 'core_defs'
require_relative 'const_site_cache'
require_relative 'native_owner_map'

# CONST_PLAIN_LOAD (BC2CPP_CONST_PLAIN_LOAD=0 turns it off): a CONST_SITE_CACHE read that cannot run before its gem's
# init has ended, of a slot that init is proven to fill, is a plain slot load (bc2cpp_cconstp_<N>): no empty test and
# no fill call at the site. bc2cpp_gem_init fills those slots last (bc2cpp_cconst_prefill).
#
# INIT_REACH (the site): a method body can run during gem init only when something that runs then names it. The name
# closure of MainReachability, seeded with no host roots, starts from every instruction sequence outside a method body
# (the root, class bodies and their blocks), the implicit protocol names (ALWAYS_DYNAMIC), every name a native or
# foreign Ruby source spells, and copied bodies, and follows every name a reached body sends to every owner of it. A
# reached body keeps the checked read. An unbounded reflective call, or a native by-name call whose name is not a
# literal (NATIVE_BOUNDED), reaches everything. The core gem is left out: mruby runs its gem_init last, and its methods
# run from mrb_open_core on.
#
# BOUND_AT_INIT (the slot): the lookup is fixed once its bindings exist (const_site_cache.rb), so the prefill stores the
# value every later read would find when each binding the slot waits for is made by then and one of them is visible.
# A binding counts when it is made unconditionally (no branch, early exit or rescue range can skip it) by a class body
# or root statement, or by a native class definition, of this gem, of the core, or of a gem this gem's base gem depends
# on; an assigned value must be a literal, a `new` or a frozen literal (never nil, which reads as an empty slot).
# Visible: its scope is a lexical scope of the site, or a module an unconditional `class Object; include M` of such a
# gem mixes into Object. A gem's dependencies running first is mruby's gem order, not proven here: a slot the prefill
# still finds empty stops the VM with mrb_bug, so a broken order is a deterministic abort at boot, never a nil read.
module ConstPlainLoad
  Roots = Struct.new(:names, :functions, :refusals, :native_paths, keyword_init: true)
  # Ruby operator and identifier spellings, read from a foreign source's text.
  FOREIGN_NAME = /(?<![\w@$:])[a-z_][A-Za-z0-9_]*[?!=]?|\[\]=?|<=>|===?|=~|![=~]?|[-+*\/%<>&|^~]@?|<<|>>|<=|>=|\*\*/
  # A by-name native call's name argument: a literal symbol macro, or a variable every assignment of which is one.
  SYM_LITERAL = /\A\s*MRB_[A-Z]*SYM(?:_[A-Z])?\(\s*\w+\s*\)\s*\z/
  # Writers whose value is never nil.
  LITERAL_OPS = (BytecodeIR::Ops::LOADI_OPS | Set[:LOADL, :LOADSYM, :LOADT, :LOADF, :STRING, :ARRAY, :ARRAY2, :HASH,
                                                  :LAMBDA, :RANGE_INC, :RANGE_EXC, :OCLASS, :INTERN]).freeze
  EXIT_OPS = Set[:RETURN, :RETURN_BLK, :BREAK, :RAISEIF, :STOP].freeze
  # Hooks and exception protocol the VM calls by name, beyond ALWAYS_DYNAMIC.
  VM_CALLED = %w[singleton_method_added method_removed method_undefined initialize_dup initialize_clone exception message
                 backtrace set_backtrace].freeze

  module_function

  def enabled?
    ENV['BC2CPP_CONST_PLAIN_LOAD'] != '0'
  end

  # The world facts every unit of one generation shares: reach (INIT_REACH), made, class_paths, native_owners.
  Result = Struct.new(:reach, :made, :class_paths, :native_owners, keyword_init: true)

  class << self
    attr_accessor :result
  end

  def analyze(ireps, root_label, definitions, native_paths, foreign_paths, aliases: {})
    reach = init_reach(ireps, definitions, native_paths, foreign_paths, aliases: aliases)
    warn "== constant plain loads (CONST_PLAIN_LOAD): #{reach.labels.size}/#{ireps.size} instruction sequences may " \
         'run during gem init =='
    reach.refusals.each { |reason| warn "  all checked: #{reason}" }
    self.result = if reach.refusals.empty? || ENV['BC2CPP_CPL_MEASURE_ALL'] == '1'
                    Result.new(reach: reach, made: made_bindings(ireps, root_label, native_paths),
                               class_paths: UniqueClassNames.bytecode_class_paths(ireps, root_label),
                               native_owners: ConstBindings.native_class_owners(native_paths)&.fetch(:classes))
                  end
  end

  # Rewrites the plain sites of the compiled entries of the unit +symbol+, in place.
  def apply(compiled, gen, ireps, symbol)
    base = BC2CPP_COMPILED_GEMS_CONFIG.find { |entry| entry.out_symbol == symbol }&.owners_from
    slots = gen.const_site_entries
    admitted = admitted_slots(slots, result.made, allowed_makers(base), result.class_paths, result.native_owners)
    admitted = slots.to_set { |sl| sl[:index] } if ENV['BC2CPP_CPL_MEASURE_ALL'] == '1'
    plain = 0
    compiled.each do |m|
      next unless plain_entry?(m, result.reach, ireps)

      code = rewrite(m[:code], admitted)
      plain += 1 unless code == m[:code]
      m[:code] = code
    end
    warn "== constant plain loads (CONST_PLAIN_LOAD): #{admitted.size}/#{slots.size} slots bound at init, " \
         "#{plain}/#{compiled.size} methods read them plain =="
  end

  # INIT_REACH: the labels of the bodies that may run during gem init (MainReachability::Result), with its refusals.
  def init_reach(ireps, definitions, native_paths, foreign_paths, aliases: {})
    require_relative 'main_reachability'
    names = VM_CALLED.to_set
    Array(foreign_paths).each do |path|
      File.read(path, encoding: 'UTF-8').scan(FOREIGN_NAME) { |token| names << token }
    end
    bounded = Array(native_paths).select { |path| File.file?(path) && native_bounded?(File.read(path, encoding: 'UTF-8')) }
    roots = Roots.new(names: names, functions: Set.new, refusals: [], native_paths: bounded.to_set { |p| File.realpath(p) })
    r = MainReachability.analyze(ireps, definitions, roots, native_paths: Array(native_paths), seed_named: false,
                                                        aliases: aliases)
    r
  end

  # NATIVE_BOUNDED: every by-name call in +text+ names a literal, directly, through a ternary of literals or a variable
  # assigned only literals; MainReachability then reads the names from the file's own symbol tokens.
  def native_bounded?(text)
    require_relative 'main_reachability'
    clean = StaticDispatchRegistrations.strip_c_comments(text)
    clean.to_enum(:scan, /\b(?:#{MainRoots::BRIDGES.join('|')})\b/).all? do
      token = Regexp.last_match
      opening = token.end(0)
      opening += 1 while clean[opening]&.match?(/\s/)
      next true unless clean[opening] == '('

      call = NativeOwnerMap.call_args(clean, opening)
      next true if call && NativeOwnerMap.definition?(clean, token.begin(0), call.last)

      name = call&.first&.[](MainRoots::NAME_ARGUMENT.fetch(token[0], 2))
      name && literal_name?(clean, name)
    end
  end

  def literal_name?(text, expr, depth = 0)
    return false if depth > 3

    expr = expr.strip
    return true if NativeOwnerMap.name_of(expr) || expr.match?(SYM_LITERAL)
    if (m = expr.match(/\A[^?:]+\?(?<a>[^?:]+):(?<b>[^?:]+)\z/))
      return literal_name?(text, m[:a], depth + 1) && literal_name?(text, m[:b], depth + 1)
    end
    return false unless expr.match?(/\A[A-Za-z_]\w*\z/)
    # A parameter of that name could hold anything.
    return false if text.match?(/\bmrb_sym\s+#{expr}\s*[,)]/)

    rhs = text.scan(/(?<![\w.>])#{expr}\s*=(?!=)\s*([^;]+);/).flatten
    !rhs.empty? && rhs.all? { |value| literal_name?(text, value, depth + 1) }
  end

  # The compiled entries whose constant reads may be plain: a body INIT_REACH does not reach, outside the core.
  def plain_entry?(entry, reach, ireps)
    label = entry[:label]
    return false unless label && reach && ireps.key?(label)
    return false if reach.labels.include?(label) && ENV['BC2CPP_CPL_MEASURE_ALL'] != '1'

    !CoreDefs.core_source?(ireps.fetch(label).file)
  end

  # +code+ with each CONST_SITE_CACHE call of an +admitted+ slot made a plain load.
  def rewrite(code, admitted)
    code.gsub(/\bbc2cpp_cconst_(\d+)\(M\)/) do
      index = Regexp.last_match(1)
      admitted.include?(index.to_i) ? "bc2cpp_cconstp_#{index}()" : Regexp.last_match(0)
    end
  end

  # BOUND_AT_INIT ------------------------------------------------------------------------------------------------------

  # What gem init makes: made[full path] = makers of an unconditional binding there, mixins = makers of an
  # unconditional `include M` in Object's body, per M. A maker is the gem whose init runs the statement (:core for
  # mruby's own mrblib and src, :late for Ruby the core gem's init runs, :own for a source outside every gem).
  Made = Struct.new(:made, :mixins, keyword_init: true)

  def made_bindings(ireps, root_label, native_paths)
    made = Hash.new { |hash, path| hash[path] = Set.new }
    mixins = Hash.new { |hash, name| hash[name] = Set.new }
    walk = lambda do |label, namespace, skippable|
      irep = ireps.fetch(label)
      program = BytecodeIR.for(irep)
      # The root of a multi-file compile names only its last file, so its own statements have no known maker; a class
      # body names its file.
      maker = label == root_label ? nil : ruby_maker(irep.file)
      skipped = skippable_indices(irep)
      bodies = BytecodeIR.class_bodies(irep, :CLASS, :MODULE)
      program.each_source do |insn, idx|
        uncond = !skippable && !skipped.include?(idx)
        sure = uncond && maker
        case insn.op
        when :CLASS, :MODULE
          full = BytecodeIR.class_body_path(irep, idx, namespace)
          next unless full.is_a?(String)

          opener = maker || (bodies.key?(idx) && label == root_label && ruby_maker(ireps.fetch(bodies[idx]).file))
          made[full] << opener if uncond && opener
          walk.call(bodies[idx], full, !uncond) if bodies.key?(idx)
        when :SETCONST
          full = namespace ? "#{namespace}::#{insn.const_name}" : insn.const_name
          made[full] << maker if sure && never_nil?(irep, idx, insn.regs.last)
        when *BytecodeIR::Ops::SEND
          next unless sure && namespace == 'Object' && insn.sym.to_s == 'include' && insn.argc.to_i == 1

          writers = BytecodeIR.writers_reaching(irep, idx, insn.reg.to_i + 1)
          next unless writers&.size == 1 && writers.first[1].op == :GETCONST

          mixins[writers.first[1].const_name] << maker
        end
      end
    end
    walk.call(root_label, nil, false)
    Array(native_paths).each do |path|
      next unless File.file?(path)

      owners = ConstBindings.native_class_owners([path])
      next unless owners

      maker = native_maker(path)
      owners[:classes].each do |name, scopes|
        scopes.each { |scope| made[scope.empty? ? name : "#{scope}::#{name}"] << maker } if maker
      end
    end
    Made.new(made: made, mixins: mixins)
  end

  # The instruction indices of +irep+ a forward branch, an earlier exit or a rescue range can skip.
  def skippable_indices(irep)
    program = BytecodeIR.for(irep)
    insns = program.each_source.to_a
    out = Set.new
    exited = false
    insns.each do |insn, idx|
      out << idx if exited
      exited ||= EXIT_OPS.include?(insn.op)
      target = insn.branch_target
      next unless target && target > insn.addr

      insns.each { |other, j| out << j if other.addr > insn.addr && other.addr < target }
    end
    Array(irep.catch_handlers).each do |handler|
      insns.each { |other, j| out << j if other.addr >= handler.begin_addr && other.addr < handler.end_addr }
    end
    out
  end

  # Every writer of +reg+ reaching +idx+ makes a value that is never nil: a literal, `new`, or `.freeze` of one.
  def never_nil?(irep, idx, reg, depth = 0)
    writers = BytecodeIR.writers_reaching(irep, idx, reg)
    !writers.nil? && writers.all? do |j, w|
      next true if LITERAL_OPS.include?(w.op)
      next false unless BytecodeIR::Ops::SEND.include?(w.op) && depth < 2

      case w.sym.to_s
      when 'new' then true
      when 'freeze' then w.argc.to_i.zero? && never_nil?(irep, j, w.reg, depth + 1)
      else false
      end
    end
  end

  def world_relative(path)
    full = File.expand_path(path)
    root = File.expand_path(BC2CPP_WORLD_ROOT)
    full.start_with?("#{root}/") ? full.delete_prefix("#{root}/") : nil
  end

  # The gem whose init runs a Ruby source's statements.
  def ruby_maker(file)
    rel = world_relative(file.to_s)
    return :own unless rel
    return :core if rel.start_with?('3rd/mruby/mrblib/')
    return :late if rel.start_with?('3rd/') # a core or external gem's mrblib: units of the core gem, which runs last

    rel[%r{\A([\w-]+)/mrblib(?:_rom)?/}, 1]
  end

  def native_maker(path)
    rel = world_relative(path)
    return :own unless rel
    return :core if rel.start_with?('3rd/mruby/src/')
    return rel[%r{\A3rd/mruby/mrbgems/([\w-]+)/}, 1] if rel.start_with?('3rd/mruby/mrbgems/')
    return rel[%r{\A3rd/([\w-]+)/}, 1] if rel.start_with?('3rd/')

    rel[%r{\A([\w-]+)/}, 1]
  end

  # The makers whose bindings exist when +base+'s compiled gem ends its init: the core, the gem itself and its
  # (transitive) dependencies. A run that is no compiled gem (a fixture world) has its own sources instead.
  def allowed_makers(base)
    return Set[:core, :own] unless base

    seen = Set.new
    work = [base]
    until work.empty?
      gem = work.pop
      next unless seen.add?(gem)

      rake = gem_rake(gem)
      next unless rake

      File.read(rake).scan(/add_dependency\s*\(?\s*['"]([\w-]+)['"]/) { |(dep)| work << dep }
    end
    seen << :core
  end

  def gem_rake(gem)
    root = BC2CPP_WORLD_ROOT
    [File.join(root, gem), File.join(root, '3rd/mruby/mrbgems', gem), File.join(root, '3rd', gem)]
      .map { |dir| File.join(dir, 'mrbgem.rake') }.find { |path| File.file?(path) }
  end

  # The slot indices whose binding the prefill of a gem with +allowed+ makers is proven to find. +slots+ are
  # CONST_SITE_CACHE entries (codegen_send.rb const_site_slot); +class_paths+ is UniqueClassNames.bytecode_class_paths.
  def admitted_slots(slots, made, allowed, class_paths, native_owners)
    visible_mixins = made.mixins.select { |_, makers| makers.intersect?(allowed) }.keys.to_set
    bound = ->(path) { made.made.fetch(path, nil)&.intersect?(allowed) }
    slots.select do |slot|
      name = slot[:name]
      scope = slot[:scope] == ['Object'] ? [] : slot[:scope]
      owners = if slot[:paths]
                 slot[:paths]
               elsif slot[:value] || slot[:drop]
                 made.made.keys.select { |path| path == name || path.end_with?("::#{name}") }
                     .map { |path| path == name ? '' : path.delete_suffix("::#{name}") }
               else
                 ruby = Array(class_paths[name]).grep(String).map { |p| p == name ? '' : p.delete_suffix("::#{name}") }
                 native = native_owners ? native_owners.fetch(name, []).to_a : []
                 (ruby + native).uniq
               end
      next false if owners.empty?
      # A single-binding slot has one path; CONST_BINDING_CACHE waits for all of its paths.
      next false if !slot[:paths] && owners.size != 1

      full = ->(owner) { owner.empty? ? name : "#{owner}::#{name}" }
      next false unless owners.all? { |owner| bound.call(full.call(owner)) }
      next false unless (1..scope.size).all? { |k| bound.call(scope[0, k].join('::')) }

      owners.any? do |owner|
        owner.empty? || scope[0, owner.split('::').size] == owner.split('::') ||
          visible_mixins.include?(owner) || visible_mixins.include?("Object::#{owner}")
      end
    end.to_set { |slot| slot[:index] }
  end
end
