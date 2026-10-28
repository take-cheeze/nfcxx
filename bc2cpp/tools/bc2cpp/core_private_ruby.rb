# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir'
require_relative 'core_defs'

# CORE_PRIVATE_RUBY (closed only): the private methods mruby's own Ruby defines (`private def puts` in mruby-io's
# kernel.rb) that no lookup in the closed build can reach. The closed build removes each one after its mrblib has
# run, like a left-out native (STATIC_DISPATCH_CORE_LEFT_OUT), so its bytecode is no method-table entry.
#
# CoreNativeCandidates reads names receiver-blind, which a private method can never satisfy: `$stdout.puts` spells
# `puts` 200 times, none of them Kernel#puts. A private method is reached only by
#   - a send with the implicit self (SSEND, `self.puts` too): the VM's private check runs for OP_SEND and not for
#     OP_SSEND (vm.c). A self send inside a method whose own class (or a superclass below Object) defines the name
#     finds that one first and is no use of the Kernel one (IO#each_line's `self.gets`, File.foreach's
#     `self.open`);
#   - a lookup by name that skips the check: `send`, `method` and the other LOOKUP_SENDS, a native's funcall, a
#     Symbol (a LOADSYM spells it), `super`, an alias or undef, or a name built at run time. These are what
#     CoreNativeCandidates.lookup_names already counts, so the rule here is that scan with the explicit-receiver
#     sends of a candidate name left out.
# A few native spellings of these names are no lookup (NOT_LOOKUPS).
module CorePrivateRuby
  # Native text that spells a name without looking a method up by it:
  #   - the class-of-an-IO search of mrb_io_puts_direct, whose result is used only when it is io_puts_method;
  #   - a presym scanning tag and cdump's operator-name table row (build-time tools that name the operator);
  #   - the "p" of MRUBY_PATCHLEVEL_STR, glued to the number after it.
  NOT_LOOKUPS = [
    /mrb_method_search_vm\(\s*\w+\s*,\s*&c\s*,\s*MRB_SYM\(puts\)\s*\)/,
    /MRB_PRESYM_SCANNING_TAGGED\("`"\)/,
    /OPERATOR_SYMBOL\("`"\s*,\s*"tick"\)/,
    /"p"(?=MRB_STRINGIZE)/
  ].freeze

  # The scan CoreNativeCandidates.lookup_names makes, minus the candidates that scan finds only as a DEF's own name
  # or as the name of a send that cannot reach a private method. A send that can is the implicit-self one of a
  # method whose class does not define the name (see the header). +owners+ maps an irep (by identity) to the
  # owner of the method it belongs to.
  class Lookup
    DEF_OPS = %i[DEF TDEF SDEF].freeze

    # +candidates+ are the private names; +defined_only+ are other names whose DEF in a body that also holds an ALIAS
    # is no use (lookup_names keeps every symbol of such a body). Their explicit sends count.
    def initialize(candidates, owners, defines, defined_only = Set.new)
      @candidates = candidates
      @defined_only = defined_only
      @owners = owners
      @defines = defines
    end

    def call(irep, own, names, fragments)
      here = Set.new(irep.syms.map(&:to_s)) & (@candidates | @defined_only)
      seen = Set.new
      CoreNativeCandidates.lookup_names(irep, own, seen, fragments)
      names.merge(here.empty? ? seen : seen - here.reject { |name| reached?(irep, own, name) })
    end

    private

    # Does +irep+ look +name+ up other than as a def's name or an explicit send (which stops at a private method)?
    # An occurrence in the symbol table no instruction explains counts.
    def reached?(irep, own, name)
      return true if own == name || irep.pool.any? { |s| s == name }

      explained = false
      BytecodeIR.for(irep).each_source do |insn, _index|
        next unless insn.op == :ALIAS ? [insn.sym, insn.first_of(:name)&.value].map(&:to_s).include?(name) : insn.sym.to_s == name

        if DEF_OPS.include?(insn.op) then explained = true
        elsif @candidates.include?(name) && BytecodeIR::Ops::SEND_FAMILY.include?(insn.op) && !self_send_reaching?(insn, irep)
          explained = true
        else return true
        end
      end
      !explained
    end

    # An implicit-self send finds the private method unless the class of its method defines the name itself.
    def self_send_reaching?(insn, irep)
      return false unless BytecodeIR::Ops::SELF_SEND_FAMILY.include?(insn.op)

      owner = @owners[irep]
      owner.nil? || !@defines.call(owner, insn.sym.to_s)
    end
  end

  module_function

  # "Owner#name" => its method body's irep label, for each `private def` of a core file: a TDEF whose result the next
  # instruction hands to a self `private`. `owner_of` maps a body label to its owner.
  def private_defs(ireps, owner_of)
    out = {}
    ireps.each_value do |irep|
      prog = BytecodeIR.for(irep)
      prog.each_source do |insn, index|
        next unless insn.op == :TDEF

        nxt = prog.source_at(index + 1)
        next unless nxt && nxt.op == :SSEND && nxt.sym == 'private' && nxt.argc == 1 && nxt.reg.to_i + 1 == insn.reg.to_i

        label = CoreDefs.def_body_label(irep, insn, index)
        owner = label && owner_of[label]
        out["#{owner}##{insn.sym}"] = label if owner
      end
    end
    out
  end

  # Does a self send of +name+ from a method of +owner+ find a definition below Object first? +defined+ is every
  # "Owner#name" some Ruby file or native registration defines (a singleton owner's with `.singleton`; a ROM entry is
  # attributed to the instance side only), +superclass_of+ the class hierarchy.
  def defines_proc(defined, superclass_of)
    lambda do |owner, name|
      singleton = owner.end_with?('.singleton')
      klass = owner.delete_suffix('.singleton')
      seen = Set.new
      while klass && !%w[Object BasicObject Kernel].include?(klass) && seen.add?(klass)
        return true if defined.include?("#{klass}#{'.singleton' if singleton}##{name}")

        klass = superclass_of[klass]
      end
      false
    end
  end

  # Blanks the NOT_LOOKUPS of native text.
  def strip_not_lookups(text)
    NOT_LOOKUPS.inject(text) { |t, re| t.gsub(re) { |m| ' ' * m.size } }
  end
end
