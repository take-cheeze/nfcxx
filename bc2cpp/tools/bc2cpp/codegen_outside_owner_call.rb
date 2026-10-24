# frozen_string_literal: true

require_relative 'native_owner_map'
require_relative 'outside_ruby_owners'

# OUTSIDE_OWNER_CALL: the else of a closed-world guard chain that stayed a by-name send only
# because a core, native or outside Ruby class also defines the name (`CLOSED_WORLD kept: core_or_native`).
#
# The closed world names every such class: NativeOwnerMap reads each native registration of the name and the class
# it lands on, OutsideRubyOwners each outside Ruby definition. When every one of them has a name, the chain's else
# becomes a call checked against that list (bc2cpp_owner_call, symbol_cache.rb): the receiver's method is looked
# up once, and
#   - found on a listed owner: that method is called with the frame mruby's own dispatch pushes
#     (mrb_funcall_with_method, the NATIVE_SINGLETON_CALL mechanism, since a C function reads its
#     arguments from the call frame), after the checks OP_SEND makes (visibility, argument count / aspec);
#   - found nowhere: the NoMethodError dispatch raises (the receiver is proven method_missing-free);
#   - found on any other owner: a closed-world violation is raised. That owner is a definer the closed world did
#     not see, so the error is the finding, not a dispatch.
# The Ruby-side gates of ClosedWorld#refusal (installers, singleton and opaque definers, unlisted classes,
# method_missing) still decide whether the site may close; this lifts only the outside-definer refusal.
module OutsideOwnerCall
  # NAME_OWNER_SET: at most this many classes may answer a name for its by-name sends to become the owner call.
  # `==` and the like have dozens; a list that long is no receiver fact. 32 takes `to_s`, `inspect`, `dispose` and
  # `update` (19 to 28 owners in the closed build): the call still checks the owner it finds, once per owner and
  # site (bc2cpp_owner_set keeps 32 seen owners).
  NAME_OWNER_SET_MAX = 32

  # NAME_OWNER_SET: the receiver of a send of `name` can only be an instance of a class that answers it
  # (anything else raises NoMethodError), and in the closed world every such class is named: the program's own Ruby
  # definitions (the registry, core Ruby included) and every outside one. So any by-name send of such a name becomes
  # the owner call over that whole set, wherever it is emitted (a chain's else, a bare send, the else of the
  # registered-expression and NATIVE_OWNER_MAP arms). A block send keeps its by-name call.
  def dynamic_dispatch_line(d, recv, name, argv)
    callable = !@call_block_expr && argv.size <= CodeGen::FUNCALL_ARGC_MAX
    owners = callable && name_owner_set(name)
    return "#{outside_owner_call_line(d, recv, name, argv, owners)}\n" if owners
    return name_owner_nomethod_line(d, recv, name, argv) if callable && name_owner_set_empty?(name)

    super
  end

  # NAME_OWNER_SET_EMPTY: every gate of name_owner_set_decide passed and no class answers `name` at all (no Ruby,
  # core, native or outside definition, no native placeholder, no method_missing hook), so the send can only raise
  # NoMethodError: the proven nomethod (bc2cpp_nomethod dispatches once to raise mruby's own error, and reports a
  # violated proof if a method answered).
  def name_owner_set_empty?(name)
    name_owner_set(name)
    @name_owner_empty&.include?(name) || false
  end

  def name_owner_nomethod_line(d, recv, name, argv)
    args = argv.empty? ? '' : ", #{argv.size}, #{argv.join(', ')}"
    marker = NomethodReviewed.marker(name, self_receiver: recv == 'self', site: insn_source_site)
    "r#{d} = bc2cpp_nomethod_named(M, #{recv}, \"#{name}\"#{args}); #{marker}\n"
  end

  # Every class or module (`.singleton` for a class object) whose definition of `name` a lookup can find, or nil when
  # one cannot be named, a definer is unknown or dynamic, a method_missing hook could answer instead, an object may
  # carry a singleton class, or the set is larger than NAME_OWNER_SET_MAX.
  def name_owner_set(name)
    return nil unless owner_call_world

    @name_owner_sets ||= {}
    return @name_owner_sets[name] if @name_owner_sets.key?(name)

    @name_owner_sets[name] = name_owner_set_decide(name)
  end

  def name_owner_set_decide(name)
    return nil if %w[method_missing respond_to_missing? initialize].include?(name)
    return nil unless owner_call_world.method_missing_classes.empty?
    return nil if owner_call_world.exact_arm_refusal(name, symbol_installed_names).then { |r| r && r != :outside_ruby }

    outside = outside_owner_call_owners(name, allow_empty: true)
    return nil unless outside

    ruby = (@registry[name] || []).reject { |definition| definition.owner == '<native>' }.map(&:owner)
    ruby += (self.class.core_hidden_defs || []).select { |definition| definition.name == name }.map(&:owner)
    return nil unless ruby.all? { |owner| owner.match?(OWNER_PATH) }

    owners = (outside | ruby).uniq.sort
    if owners.empty? && (@registry[name] || []).none? { |definition| definition.owner == '<native>' }
      (@name_owner_empty ||= Set.new) << name
    end
    owners.empty? || owners.size > NAME_OWNER_SET_MAX ? nil : owners
  end

  # The world whose definers the owner set names. A core body (`@closed_world` withheld, CodeGen#compile_method) runs
  # in the same program, so the program's world names every class its receivers can have; the owner call binds no
  # body statically, it checks the one lookup finds against that list.
  def owner_call_world
    @closed_world || @core_program_world
  end

  OWNER_PATH = /\A[A-Z]\w*(?:::[A-Z]\w*)*(?:\.singleton)?\z/

  def guarded_fallback_line(d, recv, name, argv, listed, site)
    base = super
    # The by-name else became the owner call over the whole name owner set, or its proven nomethod when the set is
    # empty: not a kept dispatch.
    if base.include?('bc2cpp_owner_call_named(') || base.include?('bc2cpp_nomethod_named(')
      return base.sub(%r{ /\* CLOSED_WORLD kept: \w+ \*/}, '')
    end
    return base unless @closed_world && site && base.include?('/* CLOSED_WORLD kept: core_or_native */')

    owners = outside_owner_call_owners(name)
    return base unless owners

    lifted = @closed_world.with_outside_owner_call(name) { super }
    error = %r{r#{d} = bc2cpp_nomethod_named\(M, #{Regexp.escape(recv)}, "#{Regexp.escape(name)}"[^\n]*?\); /\* CLOSED_WORLD nomethod: (?:self|recv)\.\S+ @ \S+ \*/}
    # Another gate still keeps the else: the site dispatches by name, under that gate's reason.
    return lifted unless lifted.match?(error)

    lifted.sub(error) { outside_owner_call_line(d, recv, name, argv, owners) }
  end

  # A send with no guard chain (POLY's bare dispatch): the same closed-world question with no Ruby arm listed. The
  # chain the refusal still allows (UNLISTED_CLASS_CALL arms for Ruby definers, native arms) is kept in front of the
  # owner call; any other answer (a kept dispatch, a dead nomethod) leaves the bare send as it was.
  def outside_owner_bare_line(d, recv, name, argv, site)
    return nil unless @closed_world && site && outside_owner_call_owners(name)

    line = guarded_fallback_line(d, recv, name, argv, [], site)
    return nil unless line.include?("/* CLOSED_WORLD owner-call: #{name} */") && !line.include?('bc2cpp_nomethod')

    "// OUTSIDE_OWNER_CALL :#{name} -- no guard chain; every class answering it is a named outside owner (ADR 0468)\n" \
      "  #{line}"
  end

  # HELPER_OWNER_CALL: a shared helper's last-resort `mrb_funcall(M, x, "name", n, args...)` (the numeric slow
  # paths' else, `bc2cpp_eqq`'s default arm) is the same by-name send, so it becomes the owner call over the name's
  # whole owner set when NAME_OWNER_SET names one. Level 0: mrb_funcall checks neither visibility nor arity, nor
  # does the helper's operator site (CheckedSend never sees it).
  HELPER_FUNCALL = /\bmrb_funcall\(M, (\w+), "([^"]+)", (\d+)((?:, \w+)*)\)/

  def helper_owner_calls(code)
    code.gsub(HELPER_FUNCALL) do
      call = Regexp.last_match
      recv, name, argc, args = call.captures
      owners = argc.to_i <= CodeGen::FUNCALL_ARGC_MAX && args.count(',') == argc.to_i && name_owner_set(name)
      next call[0] unless owners

      list = owners.map { |owner| "\"#{owner}\"" }.join(', ')
      "bc2cpp_owner_call_named(M, #{recv}, \"#{name}\", 0, BC2CPP_OWNERS(#{list}), mrb_nil_value(), #{argc}#{args}) " \
        "/* CLOSED_WORLD owner-call: #{name} */"
    end
  end

  # `r = bc2cpp_owner_call_named(M, recv, "name", LEVEL, BC2CPP_OWNERS(...), blk, argc, args...)`. LEVEL is the
  # OP_SEND check level CheckedSend fills in for a real SEND instruction (0 for any other site); SymbolCache turns
  # the name into its slot.
  def outside_owner_call_line(d, recv, name, argv, owners)
    args = argv.map { |arg| ", #{arg}" }.join
    list = owners.map { |owner| "\"#{owner}\"" }.join(', ')
    "r#{d} = bc2cpp_owner_call_named(M, #{recv}, \"#{name}\", 0, BC2CPP_OWNERS(#{list}), " \
      "#{@call_block_expr || 'mrb_nil_value()'}, #{argv.size}#{args}); /* CLOSED_WORLD owner-call: #{name} */"
  end

  # BLOCK_OWNER_CALL: a by-name block send (`mrb_funcall_with_block`) as the owner call with the block as `blk`, or
  # nil when NAME_OWNER_SET names no owners. Both calls run vm.c's funcall_with_block_m (ensure_block, the block in
  # the pushed frame, a break or exception unwinding the same way); the owner call only checks the method its one
  # lookup finds against the list. Level 0: mrb_funcall_with_block checks no visibility or arity either.
  def block_owner_call_line(dest, recv, name, argv, blk)
    owners = argv.size <= CodeGen::FUNCALL_ARGC_MAX && name_owner_set(name)
    return nil unless owners

    args = argv.map { |arg| ", #{arg}" }.join
    list = owners.map { |owner| "\"#{owner}\"" }.join(', ')
    "#{dest} = bc2cpp_owner_call_named(M, #{recv}, \"#{name}\", 0, BC2CPP_OWNERS(#{list}), #{blk}, " \
      "#{argv.size}#{args}); /* CLOSED_WORLD owner-call: #{name} */"
  end

  # BLOCK_OWNER_CALL over a splat: the args are an Array's items (`argc`, `argv` are C expressions), as the
  # `mrb_funcall_with_block(M, recv, mid, ary_size(a), ary_items(a), blk)` it replaces passes them.
  def block_owner_call_argv_line(dest, recv, name, argc, argv, blk)
    owners = name_owner_set(name)
    return nil unless owners

    list = owners.map { |owner| "\"#{owner}\"" }.join(', ')
    "#{dest} = bc2cpp_owner_call_argv_named(M, #{recv}, \"#{name}\", 0, BC2CPP_OWNERS(#{list}), #{blk}, " \
      "#{argc}, #{argv}); /* CLOSED_WORLD owner-call: #{name} */"
  end

  # The sorted owners of every outside definition of `name`, or nil when one cannot be named.
  def outside_owner_call_owners(name, allow_empty: false)
    @outside_owner_call_owners ||= {}
    owners = @outside_owner_call_owners.fetch(name) { @outside_owner_call_owners[name] = outside_owner_call_decide(name) }
    return owners if owners
    return nil unless allow_empty

    # No outside owner at all is a known (empty) outside set only when nothing outside spells the name.
    owner_call_world.outside_names.include?(name) ? nil : []
  end

  def outside_owner_call_decide(name)
    # The proof is the owner map's: off with it (BC2CPP_NATIVE_OWNER_MAP=0), and in strict mode it trusts no core
    # forwarder that installs a computed name.
    mode = native_owner_map_mode
    paths = owner_call_world.native_paths
    return nil unless mode && paths

    map = CodeGen::NATIVE_OWNER_MAP_CACHE[paths] ||= NativeOwnerMap.build(paths)
    return nil if map.computed_unknown || map.refusals[:native_prepend].positive? ||
                  map.refusals[:native_unparsed_form].positive?
    return nil if mode == :strict && (map.core_dynamic_unknown.positive? || map.refusals[:core_prepend].positive?)

    native = map.by_name.fetch(name, Set.new)
    native = factory_unknown_dropped(name, paths, native) if native.include?(NativeOwnerMap::UNKNOWN)
    return nil if native.nil? || native.include?(NativeOwnerMap::UNKNOWN)

    ruby = OutsideRubyOwners.scan(Array(owner_call_world.ruby_paths))
    return nil if ruby.unknown.include?(name) || ruby.unknown.include?(:all)

    # The program's own core Ruby also defines names the registry never lists: an alias of a native-named method
    # (IO#each_line of IO#each) and a definition the core compile refuses (Enumerator#each_with_index).
    core = OutsideRubyOwners.scan(program_core_ruby_paths)
    return nil if core.unknown.include?(name) || core.unknown.include?(:all)

    # Core Ruby definitions whose name a native also registers (mruby-io's IO.open, beside StringIO's native open) are
    # moved out of the registry into core_hidden_defs, so the registry alone cannot name them.
    hidden = (self.class.core_hidden_defs || []).select { |definition| definition.name == name }.map(&:owner)
    owners = native | (map.computed - [NativeOwnerMap::UNKNOWN]) | ruby.names.fetch(name, Set.new) | ruby.wild | hidden |
             core.names.fetch(name, Set.new) | core.wild
    return nil if owners.empty? || owners.any? { |owner| !owner.match?(OWNER_PATH) }

    owners.to_a.sort
  end

  # FACTORY_UNKNOWN_NAMES: native files whose registrations on a computed class only ever land on a class their own
  # factory makes, with exactly the names they register there. mruby-struct's make_struct gives each Struct.new
  # class singleton `new`, `[]` and `members`; mruby-data's Data.define gives its class `new` and `members`.
  FACTORY_UNKNOWN_NAMES = {
    '/3rd/mruby/mrbgems/mruby-struct/src/struct.c' => %w[[] members new].freeze,
    '/3rd/mruby/mrbgems/mruby-data/src/data.c' => %w[members new].freeze
  }.freeze

  # `native` without its UNKNOWN owner when only the factory files above contribute it and the world proves no
  # factory-made class exists (ClosedWorld#factory_class_free?), else nil. A factory file whose UNKNOWN names drift
  # from the table (a new registration on a computed class) keeps the UNKNOWN.
  def factory_unknown_dropped(name, paths, native)
    return nil unless owner_call_world.factory_class_free?

    sources = paths.select { |path| native_unknown_names(path).include?(name) }
    factory = sources.all? do |path|
      key = FACTORY_UNKNOWN_NAMES.keys.find { |suffix| File.expand_path(path).end_with?(suffix) }
      key && native_unknown_names(path).sort == FACTORY_UNKNOWN_NAMES.fetch(key).sort
    end
    factory && !sources.empty? ? native - [NativeOwnerMap::UNKNOWN] : nil
  end

  # The names `path` registers on a class the owner map cannot name.
  def native_unknown_names(path)
    @native_unknown_names ||= {}
    @native_unknown_names[path] ||= NativeOwnerMap.build([path]).by_name
                                                  .select { |_, owners| owners.include?(NativeOwnerMap::UNKNOWN) }.keys
  end

  def program_core_ruby_paths
    @program_core_ruby_paths ||= @ireps.values.map(&:file).uniq.select { |file| CoreDefs.core_source?(file) }.sort
  end
end

CodeGen.prepend(OutsideOwnerCall)
