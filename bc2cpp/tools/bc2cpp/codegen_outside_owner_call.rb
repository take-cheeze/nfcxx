# frozen_string_literal: true

require_relative 'native_owner_map'
require_relative 'outside_ruby_owners'

# OUTSIDE_OWNER_CALL (docs/adr/0468): the else of a closed-world guard chain that stayed a by-name send only
# because a core, native or outside Ruby class also defines the name (`CLOSED_WORLD kept: core_or_native`).
#
# The closed world names every such class: NativeOwnerMap reads each native registration of the name and the class
# it lands on, OutsideRubyOwners each outside Ruby definition. When every one of them has a name, the chain's else
# becomes a call checked against that list (bc2cpp_owner_call, symbol_cache.rb): the receiver's method is looked
# up once, and
#   - found on a listed owner: that method is called with the frame mruby's own dispatch pushes
#     (mrb_funcall_with_method, the NATIVE_SINGLETON_CALL mechanism of ADR 0416, since a C function reads its
#     arguments from the call frame), after the checks OP_SEND makes (visibility, argument count / aspec);
#   - found nowhere: the NoMethodError dispatch raises (the receiver is proven method_missing-free);
#   - found on any other owner: a closed-world violation is raised. That owner is a definer the closed world did
#     not see, so the error is the finding, not a dispatch.
# The Ruby-side gates of ClosedWorld#refusal (installers, singleton and opaque definers, unlisted classes,
# method_missing) still decide whether the site may close; this lifts only the outside-definer refusal.
module OutsideOwnerCall
  # NAME_OWNER_SET: at most this many classes may answer a name for its by-name sends to become the owner call.
  # `to_s`, `[]`, `==` and the like have dozens; a list that long is no receiver fact.
  NAME_OWNER_SET_MAX = 8

  # NAME_OWNER_SET (ADR 0468): the receiver of a send of `name` can only be an instance of a class that answers it
  # (anything else raises NoMethodError), and in the closed world every such class is named: the program's own Ruby
  # definitions (the registry, core Ruby included) and every outside one. So any by-name send of such a name becomes
  # the owner call over that whole set, wherever it is emitted (a chain's else, a bare send, the else of the
  # registered-expression and NATIVE_OWNER_MAP arms). A block send keeps its by-name call.
  def dynamic_dispatch_line(d, recv, name, argv)
    owners = !@call_block_expr && argv.size <= CodeGen::FUNCALL_ARGC_MAX && name_owner_set(name)
    return super unless owners

    "#{outside_owner_call_line(d, recv, name, argv, owners)}\n"
  end

  # Every class or module (`.singleton` for a class object) whose definition of `name` a lookup can find, or nil when
  # one cannot be named, a definer is unknown or dynamic, a method_missing hook could answer instead, an object may
  # carry a singleton class, or the set is larger than NAME_OWNER_SET_MAX.
  def name_owner_set(name)
    return nil unless @closed_world

    @name_owner_sets ||= {}
    return @name_owner_sets[name] if @name_owner_sets.key?(name)

    @name_owner_sets[name] = name_owner_set_decide(name)
  end

  def name_owner_set_decide(name)
    return nil if %w[method_missing respond_to_missing? initialize].include?(name)
    return nil unless @closed_world.method_missing_classes.empty?
    return nil if @closed_world.exact_arm_refusal(name, symbol_installed_names).then { |r| r && r != :outside_ruby }

    outside = outside_owner_call_owners(name, allow_empty: true)
    return nil unless outside

    ruby = (@registry[name] || []).reject { |definition| definition.owner == '<native>' }.map(&:owner)
    return nil unless ruby.all? { |owner| owner.match?(OWNER_PATH) }

    owners = (outside | ruby).uniq.sort
    owners.empty? || owners.size > NAME_OWNER_SET_MAX ? nil : owners
  end

  OWNER_PATH = /\A[A-Z]\w*(?:::[A-Z]\w*)*(?:\.singleton)?\z/

  def guarded_fallback_line(d, recv, name, argv, listed, site)
    base = super
    # The by-name else became the owner call over the whole name owner set: not a kept dispatch.
    return base.sub(%r{ /\* CLOSED_WORLD kept: \w+ \*/}, '') if base.include?('bc2cpp_owner_call_named(')
    return base unless @closed_world && site && base.include?('/* CLOSED_WORLD kept: core_or_native */')

    owners = outside_owner_call_owners(name)
    return base unless owners

    lifted = @closed_world.with_outside_owner_call(name) { super }
    error = %r{r#{d} = bc2cpp_nomethod_named\(M, #{Regexp.escape(recv)}, "#{Regexp.escape(name)}"[^\n]*?\); /\* CLOSED_WORLD nomethod: (?:self|recv)\.\S+ \*/}
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

  # `r = bc2cpp_owner_call_named(M, recv, "name", LEVEL, BC2CPP_OWNERS(...), blk, argc, args...)`. LEVEL is the
  # OP_SEND check level CheckedSend fills in for a real SEND instruction (0 for any other site); SymbolCache turns
  # the name into its slot.
  def outside_owner_call_line(d, recv, name, argv, owners)
    args = argv.map { |arg| ", #{arg}" }.join
    list = owners.map { |owner| "\"#{owner}\"" }.join(', ')
    "r#{d} = bc2cpp_owner_call_named(M, #{recv}, \"#{name}\", 0, BC2CPP_OWNERS(#{list}), " \
      "#{@call_block_expr || 'mrb_nil_value()'}, #{argv.size}#{args}); /* CLOSED_WORLD owner-call: #{name} */"
  end

  # The sorted owners of every outside definition of `name`, or nil when one cannot be named.
  def outside_owner_call_owners(name, allow_empty: false)
    @outside_owner_call_owners ||= {}
    owners = @outside_owner_call_owners.fetch(name) { @outside_owner_call_owners[name] = outside_owner_call_decide(name) }
    return owners if owners
    return nil unless allow_empty

    # No outside owner at all is a known (empty) outside set only when nothing outside spells the name.
    @closed_world.outside_names.include?(name) ? nil : []
  end

  def outside_owner_call_decide(name)
    # The proof is the owner map's: off with it (BC2CPP_NATIVE_OWNER_MAP=0), and in strict mode it trusts no core
    # forwarder that installs a computed name.
    mode = native_owner_map_mode
    paths = @closed_world.native_paths
    return nil unless mode && paths

    map = CodeGen::NATIVE_OWNER_MAP_CACHE[paths] ||= NativeOwnerMap.build(paths)
    return nil if map.computed_unknown || map.refusals[:native_prepend].positive? ||
                  map.refusals[:native_unparsed_form].positive?
    return nil if mode == :strict && (map.core_dynamic_unknown.positive? || map.refusals[:core_prepend].positive?)

    native = map.by_name.fetch(name, Set.new)
    return nil if native.include?(NativeOwnerMap::UNKNOWN)

    ruby = OutsideRubyOwners.scan(Array(@closed_world.ruby_paths))
    return nil if ruby.unknown.include?(name) || ruby.unknown.include?(:all)

    owners = native | (map.computed - [NativeOwnerMap::UNKNOWN]) | ruby.names.fetch(name, Set.new) | ruby.wild
    return nil if owners.empty? || owners.any? { |owner| !owner.match?(OWNER_PATH) }

    owners.to_a.sort
  end
end

CodeGen.prepend(OutsideOwnerCall)
