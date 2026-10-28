# frozen_string_literal: true

require 'set'

# OWNER_CALL_DIRECT: an owner call (bc2cpp_owner_call, symbol_cache.rb) carries the compiled entry of a listed owner
# this gem registers the name on, so the call finds that method without the owner's method-table entry.
#
# The owner call looks the name up and runs what it finds on a listed owner. With direct entries it then walks the
# receiver's ancestors in lookup order up to where the table lookup found the name (bc2cpp_owner_direct_pick): the
# first direct owner met answers with its entry and the flags its registration gives it (aspec, visibility), which
# is what the lookup finds while that registration is in place. So the call is the same whether the closed list
# (static_dispatch_registrations.rb) leaves the registration out or not, and the proof counts the call as no
# lookup of its direct owners (OWNER_CALL_GUARDED).
#
# An entry is direct only when its registration is the plain define of OWNER_METHOD_REGISTRATION (codegen_emit.rb):
# public or private, no CORE_BLOCK_GUARD (registered only when the bytecode could be saved), under its own name. A
# wrapper is static in its gem, so only this gem's owners can be direct. A call gets direct entries only when they
# complete it: every listed owner the closed list may leave out (CLOSED_OWNER_RE) is direct, or tested by the
# exact-class guard chain the call is the else of and subclassed by no class of the program (a subclass instance
# takes the else and inherits the owner's method). Any other call would still look its owners up, and its table of
# entries would only cost read-only data. BC2CPP_OWNER_CALL_DIRECT=0 turns it off.
module OwnerCallDirect
  # CLOSED_OWNER_RE: the owners the closed list may unregister -- the engine's own (Game, RPG2k, RPG2k3, LCF), RGSS,
  # and the singletons of those modules themselves (`Game.singleton`). Reopened core classes (Array, StringIO, ...)
  # stay out: the core's own code calls their methods on values of every kind.
  CLOSED_OWNER_RE = /\A(?:Game|RPG2k3?|LCF|RGSS)(?:::|\.singleton\z|\z)/
  # A call carries at most this many (each is a row of read-only data and a class slot).
  MAX = 8
  VISIBILITY = { public: 'MRB_METHOD_PUBLIC_FL', private: 'MRB_METHOD_PRIVATE_FL' }.freeze
  # `bc2cpp_owner_call_named(M, RECV, "name", LEVEL, BC2CPP_OWNERS(LIST)` before SymbolCache.rewrite numbers the name.
  SITE = /(\bbc2cpp_owner_call(?:_argv)?_named\(M, (.*?), "((?:[^"\\]|\\.)*)", \d+, )BC2CPP_OWNERS\(([^)]*)\)/
  STRING = /"((?:[^"\\]|\\.)*)"/
  # One arm of an exact-class guard chain: POLY_SMALL_N, MONO_EMBED_GUARD, the RGSS native-direct arms.
  GUARD_HEAD = /\A\s*(\} else )?if \((?:mrb_likely\()?bc2cpp_class_is\(M, (\w+), ([\w:]+\(M?\))\)\)?\) \{\s*\z/
  GUARD_CHAIN_LINES = 200

  module_function

  # { [owner, name] => entry } for every entry `registrations` (compiled entries plus module_function copies, as
  # emit_owner_registrations groups them) defines plainly on an owner of `registered_owners`.
  def entries(registrations, registered_owners)
    owners = registered_owners.to_set
    registrations.each_with_object({}) do |m, out|
      next unless m[:entry] && m[:aspec] && VISIBILITY.key?(m[:visibility]) && !m[:guard] && owners.include?(m[:owner])

      out[[m[:owner], m[:name]]] ||= m
    end
  end

  # `code` with the owner set of each call the direct entries complete replaced by BC2CPP_OWNERS_D. `slots` maps an
  # owner-class getter call (`bc2cpp_owner_class_3(M)`) to its owner; `subclassed` holds every program superclass.
  def rewrite(code, entries, slots, subclassed)
    return code if entries.empty? || ENV['BC2CPP_OWNER_CALL_DIRECT'] == '0' || !code.include?('BC2CPP_OWNERS(')

    lines = code.lines
    changed = false
    lines.each_with_index do |line, at|
      next unless line.include?('BC2CPP_OWNERS(')

      lines[at] = line.sub(SITE) do
        site = Regexp.last_match
        head, recv, name, list = site.captures
        owners = list.scan(STRING).flatten.grep(CLOSED_OWNER_RE)
        guarded = (at.positive? && lines[at - 1].strip == '} else {' && guard_chain_classes(lines, at - 1, recv, slots)) || Set.new
        direct = owners.reject { |o| guarded.include?(o) && !subclassed.include?(o) }.map { |o| entries[[o, name]] }
        next site[0] if direct.empty? || direct.include?(nil) || direct.size > MAX

        changed = true
        rows = direct.map do |m|
          "BC2CPP_OWNER_DIRECT(\"#{m[:owner]}\", #{m[:entry]}, #{m[:aspec]}, #{VISIBILITY.fetch(m[:visibility])})"
        end
        "#{head}BC2CPP_OWNERS_D(#{rows.join(' ')}, #{list})"
      end
    end
    changed ? lines.join : code
  end

  # The classes the if/else-if chain ending in the `} else {` at `else_at` tests `recv` against exactly, or nil when
  # its head is not found. An arm whose condition is anything but one exact-class test adds nothing. The guard of an
  # RGSS native-direct arm is `rgss::native_<name>_class()`, the class RGSS::<Name> (mruby-rgss/src/lib.cxx).
  def guard_chain_classes(lines, else_at, recv, slots)
    guarded = Set.new
    depth = 0
    (else_at - 1).downto([else_at - GUARD_CHAIN_LINES, 0].max) do |k|
      line = lines[k]
      if depth.zero? && (head = GUARD_HEAD.match(line))
        owner = guard_owner(head[3], slots)
        guarded << owner if owner && head[2] == recv
        return guarded unless head[1]
      elsif depth.zero? && line.match?(/\A\s*(\} else )?if \(/)
        return guarded unless line.lstrip.start_with?('}')
      end
      depth += line.count('}') - line.count('{')
      return nil if depth.negative?
    end
    nil
  end

  def guard_owner(cls, slots)
    slots[cls] || cls[/\Argss::native_(\w+)_class\(\)\z/, 1]&.then { |w| "RGSS::#{w.split('_').map(&:capitalize).join}" }
  end
end
