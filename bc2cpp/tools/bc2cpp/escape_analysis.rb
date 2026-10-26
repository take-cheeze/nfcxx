# frozen_string_literal: true

require 'set'
require_relative 'bytecode_ir_ops'
require_relative 'irep'
require_relative 'bytecode_ir'
require_relative 'bytecode_ir_regions'
require_relative 'core_hierarchy_sigs'
require_relative 'core_defs'
require_relative 'send_names'

# ESCAPE_ANALYSIS: one value-flow module for "does the value this instruction creates leave
# the frame that made it?". Every claim is sound by construction. The default answer is "escapes", and a
# value is non-escaping only when every instruction that can see it is on the audited lists below: a
# register copy, a branch test, a call whose every possible callee provably keeps neither that argument
# nor its receiver, a closure that itself does not escape. An op, a callee, a CFG or a state the model
# does not name is an escape.
#
# A tracked value is a SET of registers that may hold it (a forward may-alias flow over the irep's CFG,
# catch-handler edges included). Per creation site it answers:
#   1. only registers of the creating frame        -> no reasons; `uses` lists the calls made on it
#   2. passed as receiver / argument / block       -> every definition the name can reach must have a
#      summary saying that position is not kept (bytecode: this analysis run on the callee; native: the
#      audited tables below)
#   3. returned, stored (ivar, global, constant, upvar, array, hash, range), raised, read by a closure
#      that escapes, handed to an unknown or by-name send -> escapes
#
# Callee positions: [:self], [:self_keep], [:arg, k], [:block]. A summary says whether the callee "captures"
# (keeps, returns or loses track of) that position. [:self_keep] is [:self] except that the receiver may
# leave as the call's result; returns_self? says whether it does, so the caller tracks the result.
# Callees are found by NAME over every definition in the world, so the answer holds for any receiver class.
# Mutual recursion is assumed non-capturing only while it is being decided (co-inductive); a non-capturing
# result that rests on such an assumption is not memoised unless the assumed frame itself finishes non-capturing.
module EscapeAnalysis
  # BC2CPP_ESCAPE_ANALYSIS=0 returns every consumer to the earlier output.
  def self.enabled?
    ENV['BC2CPP_ESCAPE_ANALYSIS'] != '0'
  end

  # [[instruction, index]] of the IR instructions whose op is one of +ops+, in program order.
  def self.op_sites(irep, ops)
    sites = []
    BytecodeIR.for(irep).each_with_op(*ops) { |insn, index| sites << [insn, index] }
    sites
  end

  def self.insn_at(irep, index)
    BytecodeIR.for(irep).instruction_at(index).source
  end

  class << self
    # The World of the program being compiled (set by the driver once the registry and the native names
    # exist); nil when the analysis is off. Each CodeGen builds its own Analyzer over it so that memoised
    # answers never outlive the class facts they used.
    attr_reader :world

    def install(world)
      @world = world
    end
  end

  # kind :call = a Proc invocation with the value as receiver; :pass_arg / :pass_block = handed to `name`.
  Use = Struct.new(:index, :kind, :name, :reg, keyword_init: true)
  # reasons: [[symbol, instruction address]]; empty = the value does not escape. tracked: every register
  # of the analysed frame that may hold it. returned: a `returns` flow handed the value back as its result.
  Verdict = Struct.new(:reasons, :uses, :tracked, :returned, keyword_init: true) do
    def escapes?
      !reasons.empty?
    end

    def reason
      reasons.first&.first
    end
  end

  # -- audited facts about native (C) methods, by name ------------------------------------------------
  # A name here is a claim about EVERY native definition of that name in the world;
  # Each name's registrations must match NATIVE_MANIFEST, so a new definition forces a new audit. mruby's iterators (each, map, times, inject, ...) are Ruby in
  # mrblib: they need no entry, their summaries are computed from bytecode.

  # Natives that take a block and either call it synchronously or never read it; none keeps it.
  NATIVE_BLOCK_NO_CAPTURE = Set['section', 'select', 'count', 'index'].freeze
  NATIVE_MANIFEST = {
    'section' => %w[mruby-rgss/src/profiler.cxx],
    'select' => %w[3rd/mruby/mrbgems/mruby-io/src/io.c],
    'count' => %w[3rd/mruby/mrbgems/mruby-string-ext/src/string.c],
    'index' => %w[3rd/mruby/src/array.c 3rd/mruby/src/string.c],
    'class' => %w[3rd/mruby/src/kernel.c],
    'is_a?' => %w[3rd/mruby/src/kernel.c],
    'kind_of?' => %w[3rd/mruby/src/kernel.c],
    'instance_of?' => %w[3rd/mruby/src/kernel.c],
    'frozen?' => %w[3rd/mruby/src/kernel.c],
    'respond_to?' => %w[3rd/mruby/src/kernel.c],
    'respond_to_missing?' => %w[3rd/mruby/src/kernel.c],
    'hash' => %w[3rd/mruby/src/kernel.c 3rd/mruby/src/numeric.c 3rd/mruby/src/proc.c 3rd/mruby/src/string.c
                 3rd/mruby/mrbgems/mruby-complex/src/complex.c 3rd/mruby/mrbgems/mruby-rational/src/rational.c
                 3rd/mruby/mrbgems/mruby-set/src/set.c 3rd/mruby/mrbgems/mruby-time/src/time.c],
    'instance_variable_get' => %w[3rd/mruby/mrbgems/mruby-metaprog/src/metaprog.c],
    'inspect' => %w[3rd/mruby/src/numeric.c 3rd/mruby/src/hash.c 3rd/mruby/src/object.c 3rd/mruby/src/array.c
                    3rd/mruby/src/kernel.c 3rd/mruby/src/class.c 3rd/mruby/src/range.c 3rd/mruby/src/string.c
                    3rd/mruby/src/error.c 3rd/mruby/src/symbol.c 3rd/mruby/mrbgems/mruby-struct/src/struct.c
                    3rd/mruby/mrbgems/mruby-fiber/src/fiber.c 3rd/mruby/mrbgems/mruby-time/src/time.c
                    3rd/mruby/mrbgems/mruby-data/src/data.c 3rd/mruby/mrbgems/mruby-set/src/set.c
                    3rd/mruby/mrbgems/mruby-binding/src/binding.c 3rd/mruby/mrbgems/mruby-method/src/method.c
                    3rd/mruby/mrbgems/mruby-proc-ext/src/proc.c 3rd/mruby/mrbgems/mruby-task/src/task.c
                    3rd/mruby/mrbgems/mruby-socket/src/socket.c],
    'raise' => %w[3rd/mruby/src/kernel.c],
    # kernel.c:683 (kernel_rom_entries, MRB_MT_INIT_ROM at kernel.c:721) -> mrb_obj_freeze, kernel.c:356: flags and
    # returns the receiver. mruby-rgss-compiled/src/register.cxx:542 is Graphics' singleton freeze (not NATIVE_SRCS):
    # Ruby body mruby-rgss/mrblib/lib.rb:1644, returns nil, keeps no receiver.
    'freeze' => %w[3rd/mruby/src/kernel.c mruby-rgss-compiled/src/register.cxx],
    'to_s' => %w[3rd/mruby/src/numeric.c 3rd/mruby/src/hash.c 3rd/mruby/src/object.c 3rd/mruby/src/array.c
                 3rd/mruby/src/kernel.c 3rd/mruby/src/class.c 3rd/mruby/src/range.c 3rd/mruby/src/string.c
                 3rd/mruby/src/error.c 3rd/mruby/src/symbol.c 3rd/mruby/mrbgems/mruby-struct/src/struct.c
                 3rd/mruby/mrbgems/mruby-fiber/src/fiber.c 3rd/mruby/mrbgems/mruby-time/src/time.c
                 3rd/mruby/mrbgems/mruby-data/src/data.c 3rd/mruby/mrbgems/mruby-set/src/set.c
                 3rd/mruby/mrbgems/mruby-method/src/method.c 3rd/mruby/mrbgems/mruby-proc-ext/src/proc.c
                 3rd/mruby/mrbgems/mruby-test-inline-struct/test/inline.c mruby-rgss/src/lib.cxx]
  }.freeze

  # Natives that do not keep their RECEIVER. :fresh = the result is a new value or an element, never the
  # receiver; :self = the result may be the receiver itself (so it joins the tracked set). String#to_s
  # returns self (mrb_str_to_s), which is why to_s is :self.
  NATIVE_RECEIVER_OK = {
    'call' => :fresh, '[]' => :fresh, '===' => :fresh, 'arity' => :fresh, 'lambda?' => :fresh,
    'nil?' => :fresh, '!' => :fresh, '==' => :fresh, 'equal?' => :fresh, 'size' => :fresh,
    'length' => :fresh, 'empty?' => :fresh, 'first' => :fresh, 'last' => :fresh, 'include?' => :fresh,
    'key?' => :fresh, 'has_key?' => :fresh, 'pop' => :fresh, 'shift' => :fresh, '[]=' => :fresh,
    '<<' => :self, 'push' => :self, 'unshift' => :self,
    'class' => :fresh, 'is_a?' => :fresh, 'kind_of?' => :fresh, 'instance_of?' => :fresh, 'frozen?' => :fresh,
    'respond_to?' => :fresh, 'respond_to_missing?' => :fresh, 'hash' => :fresh,
    'instance_variable_get' => :fresh, 'inspect' => :fresh, 'to_s' => :self,
    # mrb_obj_freeze returns its receiver (NATIVE_MANIFEST has the registrations). Graphics.freeze returns nil,
    # which :self over-approximates; a Ruby `freeze` that keeps self still escapes (name_receiver_result).
    'freeze' => :self,
    # mrb_f_raise (kernel.c) reads only its arguments and never returns self. Its arguments are kept (the
    # exception and its message), so raise has no NATIVE_ARG_OK entry.
    'raise' => :fresh
  }.freeze
  # Ruby methods a native calls with its own receiver as self, by name. respond_to? calls
  # respond_to_missing? on self when the method is absent, so that callee must keep no self either.
  NATIVE_RECEIVER_CALLBACKS = { 'respond_to?' => %w[respond_to_missing?] }.freeze

  # Natives that keep none of the ARGUMENT at the listed positions. files: every file that registers the name
  # among NATIVE_SRCS, plus the audited files (a NATIVE_SRCS registration elsewhere refuses the name, see
  # native_files_audited?; the generated *-compiled register.cxx files are not NATIVE_SRCS). recv: Ruby or
  # native methods the natives call with the argument as receiver, judged by NATIVE_RECEIVER_OK or the
  # receiver field here, plus the user summaries. arg: [name, position] pairs the natives call with the
  # argument as an argument. Set#eql? is a C alias of Set#== (set.c), covered by the == entry.
  NATIVE_ARG_OK = {
    # complex.c, rational.c and numeric.c call mrb_equal(arg, self), so the argument is the receiver of
    # `==`. The others compare elements, ivars or identity, never the argument itself.
    '==' => {
      args: [0], recv: %w[==],
      files: %w[3rd/mruby/mrbgems/mruby-complex/src/complex.c 3rd/mruby/mrbgems/mruby-data/src/data.c
                3rd/mruby/mrbgems/mruby-fiber/src/fiber.c 3rd/mruby/mrbgems/mruby-method/src/method.c
                3rd/mruby/mrbgems/mruby-rational/src/rational.c 3rd/mruby/mrbgems/mruby-set/src/set.c
                3rd/mruby/mrbgems/mruby-struct/src/struct.c 3rd/mruby/mrbgems/mruby-time/src/time.c
                3rd/mruby/src/array.c 3rd/mruby/src/class.c 3rd/mruby/src/hash.c 3rd/mruby/src/numeric.c
                3rd/mruby/src/proc.c 3rd/mruby/src/range.c 3rd/mruby/src/string.c 3rd/mruby/src/symbol.c
                3rd/mruby-onig-regexp/src/mruby_onig_regexp.c mruby-rgss/src/lib.cxx]
    },
    # Identity only (bob_rom_entries: mrb_obj_equal_m).
    'equal?' => { args: [0], recv: [], files: %w[3rd/mruby/src/class.c] },
    # Numeric#eql? (num_eql) calls mrb_equal(self, arg), so the argument is the argument of `==`. The rest
    # compare elements or ivars. receiver: no eql? native keeps its receiver, so key? may hand it to eql?.
    'eql?' => {
      args: [0], recv: [], arg: [['==', 0]], receiver: :fresh,
      files: %w[3rd/mruby/mrbgems/mruby-data/src/data.c 3rd/mruby/mrbgems/mruby-method/src/method.c
                3rd/mruby/mrbgems/mruby-set/src/set.c 3rd/mruby/mrbgems/mruby-struct/src/struct.c
                3rd/mruby/mrbgems/mruby-time/src/time.c 3rd/mruby/src/array.c 3rd/mruby/src/hash.c
                3rd/mruby/src/kernel.c 3rd/mruby/src/numeric.c 3rd/mruby/src/proc.c 3rd/mruby/src/range.c
                3rd/mruby/src/string.c]
    },
    # The only Ruby callback is to_s, reached through ensure_class_type's %v when the argument is not a class.
    # Its result is copied into the message, never kept.
    'is_a?' => { args: [0], recv: %w[to_s], files: %w[3rd/mruby/src/kernel.c] },
    'kind_of?' => { args: [0], recv: %w[to_s], files: %w[3rd/mruby/src/kernel.c] },
    'instance_of?' => { args: [0], recv: %w[to_s], files: %w[3rd/mruby/src/kernel.c] },
    # mrb_hash_has_key hashes the probe (hash, receiver = key) and compares it (eql?, receiver = key).
    'key?' => { args: [0], recv: %w[hash eql?], files: %w[3rd/mruby/src/hash.c] },
    'has_key?' => { args: [0], recv: %w[hash eql?], files: %w[3rd/mruby/src/hash.c] },
    # Both registrations (profiler.cxx, real and WIO stub) read the name with "S&" and copy it into a std::string
    # key (profiler_section_end); the block is NATIVE_BLOCK_NO_CAPTURE. A non-String name is inspected (%Y).
    'section' => { args: [0], recv: %w[inspect to_s], files: %w[mruby-rgss/src/profiler.cxx] },
    # pack.c reads the template once (prepare_tmpl: mrb_get_args "S" into a stack struct) and builds copies.
    # Only an exact String is proven: other classes reach mrb_ensure_string_type, which inspects them (%Y).
    # A template reaches the element conversions (to_int, to_f) only as an element of the receiver, a store
    # the analysis already rejects for that object.
    'pack' => { args: [0], recv: [], only: %w[String], files: %w[3rd/mruby/mrbgems/mruby-pack/src/pack.c] },
    'unpack' => { args: [0], recv: [], only: %w[String], files: %w[3rd/mruby/mrbgems/mruby-pack/src/pack.c] }
  }.freeze
  # Receiver names that invoke a Proc (a `uses` entry the consumers turn into a direct call).
  PROC_CALLS = Set['call', '[]', '==='].freeze

  # -- the op model ---------------------------------------------------------------------------------
  # Write only their leading register and read no register that can hold a tracked value.
  KILLS_LEAD = Set[
    :LOADL, :LOADI8, :LOADINEG, :LOADI__1, :LOADI_0, :LOADI_1, :LOADI_2, :LOADI_3, :LOADI_4,
    :LOADI_5, :LOADI_6, :LOADI_7, :LOADI16, :LOADI32, :LOADSYM, :LOADNIL, :LOADTRUE, :LOADFALSE,
    :GETGV, :GETSV, :GETIV, :GETCV, :GETCONST, :GETUPVAR, :GETMCNST, :OCLASS, :TCLASS, :EXCEPT,
    :KARG, :KEY_P, :STRING, :SYMBOL, :INTERN, :METHOD, :AREF
  ].freeze
  PASSES = Set[
    :NOP, :EXT1, :EXT2, :EXT3, :DEBUG, :JMP, :JMPUW, :KEYEND, :ALIAS, :UNDEF, :ENTER, :JMPIF,
    :JMPNOT, :JMPNIL, :MATCHERR, :RETNIL, :RETTRUE, :RETFALSE, :STOP, :ERR
  ].freeze
  # Read their leading register and keep it somewhere that outlives the instruction.
  STORES_LEAD = {
    :SETGV => :stored_global, :SETSV => :stored_global, :SETIV => :stored_ivar, :SETCV => :stored_classvar,
    :SETCONST => :stored_constant, :SETMCNST => :stored_constant, :SETUPVAR => :stored_upvar,
    :RAISEIF => :raised, :RETURN => :returned, :RETURN_BLK => :returned, :BREAK => :returned,
    :ASET => :stored_container
  }.freeze
  # Write the leading register from a window of registers starting there; a tracked value in the window
  # would be kept by the result (array, hash, range) or by the class machinery.
  WINDOW_OPS = %i[RANGE_INC RANGE_EXC CLASS MODULE SCLASS EXEC DEF TDEF SDEF].freeze
  BINARY_NAMES = {
    :ADD => '+', :SUB => '-', :MUL => '*', :DIV => '/', :EQ => '==', :LT => '<', :LE => '<=',
    :GT => '>', :GE => '>='
  }.freeze
  CLOSURE_OPS = Set[:BLOCK, :LAMBDA].freeze

  # The callee side: ireps, every definition of a name and the native method names. +defs+ is
  # name => [MethodDef] as build_registry leaves it BEFORE core filtering (a core method the build keeps
  # interpreted is still a callee). +native_names+ nil means the native sources were not scanned, so every
  # name may have a native definition. +aliases+: new name => [old names] from the ALIAS op. +invisible+
  # says whether some definer outside the ireps (an outside Ruby source, a computed installer) can make
  # that name; such a name has no enumerable definitions. +hidden_owners+ (a HiddenRubyOwners) lets a name
  # that only plain class-body defs outside the ireps make be relevant to defs_for on the classes that
  # can reach it; defs_named (no receiver class) still refuses such a name.
  class World
    DEF_OPS = Set[:TDEF, :SDEF, :DEF].freeze
    # The hidden-owner token that makes every receiver a possible callee (see mixin_defines?).
    UNCONDITIONAL = '*'
    # The repository root: NATIVE_ARG_OK's file lists are repo-relative.
    NATIVE_ROOT = File.expand_path('../..', __dir__)
    CONST_READS = Set[:GETCONST, :GETMCNST].freeze
    # Sends that make a method from a name computed at run time. A literal name is modelled below; any
    # other makes every callee set unknowable (`dynamic`).
    NAMING_SENDS = %w[define_method define_singleton_method alias_method].freeze
    # `obj.send(:define_method, :x) { }` names the installer in its first argument. A first argument that is
    # not a literal is the closed world's own residual (ClosedWorld reads direct installer sends only).
    FORWARDING_SENDS = SendNames::FORWARDING_SENDS

    # mruby's own class tree for the classes the registry never declares (the natives and mrblib reopen
    # them without a superclass), and the modules their C code includes. Must match a real mruby's class tree.
    BUILTIN_SUPERCLASS = {
      'Integer' => 'Numeric', 'Float' => 'Numeric', 'Numeric' => 'Object', 'Array' => 'Object', 'Hash' => 'Object',
      'String' => 'Object', 'Symbol' => 'Object', 'Range' => 'Object', 'Proc' => 'Object', 'NilClass' => 'Object',
      'TrueClass' => 'Object', 'FalseClass' => 'Object', 'Struct' => 'Object', 'Object' => 'BasicObject',
      'Exception' => 'Object', 'StandardError' => 'Exception', 'RuntimeError' => 'StandardError',
      'ArgumentError' => 'StandardError', 'TypeError' => 'StandardError', 'IndexError' => 'StandardError',
      'RangeError' => 'StandardError', 'NameError' => 'StandardError', 'NoMethodError' => 'NameError',
      'KeyError' => 'IndexError', 'IOError' => 'StandardError', 'EOFError' => 'IOError', 'ScriptError' => 'Exception',
      'NotImplementedError' => 'ScriptError', 'FiberError' => 'StandardError', 'StopIteration' => 'IndexError',
      'ZeroDivisionError' => 'StandardError', 'LocalJumpError' => 'StandardError',
      'FloatDomainError' => 'RangeError'
    }.freeze
    BUILTIN_INCLUDES = CoreHierarchySigs.hierarchy.last

    # Sends and constants that read a frame's locals or the whole heap by name, so no value is confined.
    REFLECTIVE_SENDS = %w[binding eval local_variable_get local_variable_set local_variables
                          local_variable_defined?].freeze
    REFLECTIVE_CONSTS = %w[ObjectSpace].freeze
    # Every op scan_definitions reads.
    SCANNED_OPS = (BytecodeIR::Ops::SEND | DEF_OPS | %i[GETCONST GETMCNST]).freeze

    attr_reader :ireps, :aliases, :dynamic_sites, :reflective_sites

    def initialize(ireps:, defs:, native_names: nil, native_files: nil, native_owners: nil, aliases: {},
                   superclass_of: {}, included: {}, prepended: {}, unknown_mixins: Set.new, modules: Set.new,
                   struct_classes: Set.new, invisible: nil, hidden_owners: nil)
      @ireps = ireps
      @invisible = invisible
      @hidden_owners = hidden_owners&.owners || {}
      @hidden_wild = hidden_owners ? hidden_owners.wild.to_a : []
      @hidden_mixins = hidden_owners ? hidden_owners.mixins : Set.new
      @native_names = native_names
      # name => the NATIVE_SRCS files that register it (extract_native_method_sources). nil: no audit possible.
      @native_files = native_files
      @native_owners = native_owners
      @superclass_of = superclass_of
      @included = included
      @prepended = prepended
      @unknown_mixins = unknown_mixins
      @modules = modules
      @struct_classes = struct_classes.to_set
      @mro = {}
      @aliases = Hash.new { |h, k| h[k] = [] }
      aliases.each { |new_name, olds| @aliases[new_name].concat(olds) }
      @dynamic_sites = []
      @reflective_sites = []
      @defs = Hash.new { |h, k| h[k] = [] }
      defs.each { |name, list| @defs[name].concat(list) }
      # A class mruby's own Ruby opens (IO, File, Enumerator ...) may include modules from C, which the
      # registry never sees: only the builtin tables place such a class.
      @core_classes = @defs.values.flatten.select(&:core).to_set(&:owner)
      scan_definitions
    end

    # Definitions a call of +name+ can reach, or nil when the world cannot enumerate them.
    def defs_named(name, seen = Set.new, class_aware: false)
      return nil unless @dynamic_sites.empty?
      return nil if @invisible&.call(name)
      # Without a receiver class no hidden definition can be placed, so any hidden owner refuses the name.
      return nil if !class_aware && !hidden_owners_for(name).empty?
      return [] unless seen.add?(name)

      list = @defs.fetch(name, []).dup
      Array(@aliases.fetch(name, [])).each do |old|
        more = defs_named(old, seen, class_aware: class_aware) or return nil

        list.concat(more)
      end
      list
    end

    def native_name?(name)
      @native_names.nil? || @native_names.include?(name)
    end

    # Does every NATIVE_SRCS registration of +name+ sit in one of the +audited+ files (NATIVE_ARG_OK)?
    def native_files_audited?(name, audited)
      registered = @native_files&.fetch(name, nil)
      return false if registered.nil? || registered.empty?

      registered.all? { |path| audited.include?(path.delete_prefix("#{NATIVE_ROOT}/")) }
    end

    # The ancestry of +klass+ (nil when the tables cannot place it), for native_free_on?.
    def ancestry(klass)
      mro(klass)
    end

    # Is +name+ provably free of native definitions on every class in +chain+ (an exact receiver's
    # ancestry)? Only NativeOwnerMap's own proof counts: an unresolved owner refuses it. Core computed-name
    # installs are trusted as the codegen trusts them: a Ruby dynamic install makes this world's
    # dynamic_sites or invisible names, and defs_named then cannot enumerate the name at all.
    def native_free_on?(name, chain)
      return false if @native_owners.nil?

      NativeOwnerMap.verdict(@native_owners, name, chain, core_dynamic_trusted: true).first == :proven
    end

    # Can the hierarchy tables place the class +name+?
    def class_known?(name)
      !mro(name).nil?
    end

    # A placed class that is not a module: an instance of it is exactly that class (no includer of a module can be one).
    def plain_class?(name)
      class_known?(name) && !module_name?(name)
    end

    # Definitions a call of +name+ can reach on a receiver of class +klass+ (exactly that class when
    # +exact+, else it or any subclass; a module name means any includer). Every class or module the
    # hierarchy tables cannot place leaves the answer at all definitions of the name.
    def defs_for(name, klasses, exact)
      list = defs_named(name, class_aware: true)
      return nil if list.nil?

      hidden = hidden_owners_for(name)
      return nil if hidden.include?(UNCONDITIONAL)

      # Each early answer below is the whole name list. With a hidden owner present that list is not the
      # callee set, so it becomes unknown (nil) rather than a superset that might miss the hidden def.
      unrefined = hidden.empty? ? list : nil
      return unrefined if klasses.nil? || klasses.empty?

      # A class whose ancestry the tables cannot place may sit under any class, so no override is excluded.
      return unrefined if !exact && known_classes.any? { |c| mro(c).nil? }

      chains = []
      klasses.each do |klass|
        if exact
          chains << (mro(klass) or return unrefined)
        else
          ([klass] + descendants(klass)).each do |c|
            next if c == klass && module_name?(klass)

            chains << (mro(c) or return unrefined)
          end
        end
      end
      return unrefined if chains.empty?
      return nil if hidden.any? { |owner| hidden_owner_reaches?(owner, chains, exact) }

      chains.flat_map { |chain| first_owner_defs(list, chain) }.uniq | list.select { |d| d.owner.start_with?('<') }
    end

    private

    # The hidden owners a call of +name+ can reach through its alias closure: the plain class bodies
    # that define it outside the ireps, every wild owner, and UNCONDITIONAL when a compiled module that a hidden
    # `include` names defines it. Empty when nothing outside the ireps can define the name.
    def hidden_owners_for(name)
      out = []
      alias_closure(name).each do |n|
        own = @hidden_owners[n]
        next if own.nil? && @hidden_wild.empty?

        out.concat(own.to_a) if own
        out.concat(@hidden_wild)
        out << UNCONDITIONAL if mixin_defines?(n)
      end
      out.uniq
    end

    def alias_closure(name, seen = Set.new)
      return seen unless seen.add?(name)

      Array(@aliases.fetch(name, [])).each { |old| alias_closure(old, seen) }
      seen
    end

    # A hidden `include M` may give any class a compiled module M, which this world's ancestry tables
    # do not know. A compiled module of that simple name that defines +name+ therefore makes the
    # name unconditional.
    def mixin_defines?(name)
      return false if @hidden_mixins.empty?

      @defs.fetch(name, []).any? { |d| @modules.include?(d.owner) && @hidden_mixins.include?(d.owner.split('::').last) }
    end

    # May a hidden definition owned by +owner+ sit on one of +chains+ (the receiver classes' ancestries)?
    # Names are compared by their last segment, which is an over-approximation: a lexical `class A::B`
    # is recorded as B. An owner the tables cannot place may be a hidden subclass of a receiver class,
    # so it is reachable for a receiver set (not exact).
    def hidden_owner_reaches?(owner, chains, exact)
      return true if !exact && mro(owner).nil?

      simple = owner.split('::').last
      chains.any? { |chain| chain.any? { |entry| entry.split('::').last == simple } }
    end

    def module_name?(name)
      @modules.include?(name) || BUILTIN_INCLUDES.values.flatten.include?(name)
    end

    # Method resolution order of +klass+ (own prepended modules, the class, its included modules, then
    # the superclass chain), or nil when a link is unknown.
    def mro(klass)
      return @mro[klass] if @mro.key?(klass)

      @mro[klass] = begin
        chain = []
        k = klass
        until k.nil?
          return @mro[klass] = nil if chain.include?(k) || @unknown_mixins.include?(k)
          return @mro[klass] = nil if @core_classes.include?(k) && !BUILTIN_SUPERCLASS.key?(k) && !module_name?(k)

          Array(@prepended[k]).reverse_each { |m| add_module(chain, m) }
          chain << k
          (Array(@included[k]) + Array(BUILTIN_INCLUDES[k])).reverse_each { |m| add_module(chain, m) }
          k = superclass(k)
          return @mro[klass] = nil if k == :unknown
        end
        chain
      end
    end

    def add_module(chain, mod)
      return if chain.include?(mod)

      chain << mod
      Array(@included[mod]).reverse_each { |m| add_module(chain, m) }
    end

    # Superclass name, nil at the root, :unknown for a class neither declared nor builtin.
    def superclass(klass)
      return nil if klass == 'BasicObject'
      return 'BasicObject' if klass == 'Object'

      # A reopened builtin keeps its real superclass (`class Integer` without one is not Object's child),
      # and a class made by `Name = Struct.new` stays a Struct when reopened.
      return BUILTIN_SUPERCLASS[klass] if BUILTIN_SUPERCLASS.key?(klass)
      return 'Struct' if @struct_classes.include?(klass)

      declared = @superclass_of[klass]
      return 'Object' if declared == :none

      declared.is_a?(String) ? resolve_superclass(declared) : :unknown
    end

    # The registry spells a superclass relative to the class body (`class Timeout < StandardError` inside
    # RGSS is "RGSS::StandardError"). A name no declared class owns is the builtin of that simple name.
    def resolve_superclass(name)
      return name if @superclass_of.key?(name) || @modules.include?(name) || BUILTIN_SUPERCLASS.key?(name)

      simple = name.split('::').last
      BUILTIN_SUPERCLASS.key?(simple) ? simple : :unknown
    end

    def known_classes
      @known_classes ||= (@superclass_of.keys + BUILTIN_SUPERCLASS.keys + ['BasicObject']).uniq
    end

    # Classes that inherit from, or (for a module) include, +klass+.
    def descendants(klass)
      known_classes.select { |c| c != klass && (chain = mro(c)) && chain.include?(klass) }
    end

    # For each chain, the definitions of the first owner that defines the name.
    def first_owner_defs(list, chain)
      chain.each do |owner|
        found = list.select { |d| d.owner == owner }
        return found unless found.empty?
      end
      []
    end

    # A `def` the registry walk did not see still dispatches (every TDEF/SDEF names a callee); a literal
    # define_method/alias_method/attr_* is a definition, a computed one makes the world dynamic.
    def scan_definitions
      known = Hash.new { |h, k| h[k] = Set.new }
      @defs.each { |name, list| list.each { |d| known[name] << d.irep if d.irep } }
      closure_bodies = Set.new
      @ireps.each_value do |irep|
        BytecodeIR::Tree.child_labels(irep, CLOSURE_OPS).each { |_, label| closure_bodies << label }
      end
      @ireps.each_value do |irep|
        EscapeAnalysis.op_sites(irep, SCANNED_OPS).each do |insn, idx|
          if (BytecodeIR::Ops::SEND.include?(insn.op) && REFLECTIVE_SENDS.include?(insn.sym)) ||
             (CONST_READS.include?(insn.op) && REFLECTIVE_CONSTS.include?(insn.const_name))
            @reflective_sites << [irep.label, idx]
          end
          if DEF_OPS.include?(insn.op) && insn.sym
            scan_definition_op(irep, idx, insn, known, closure_bodies.include?(irep.label))
          elsif BytecodeIR::Ops::SEND.include?(insn.op) && NAMING_SENDS.include?(insn.sym)
            scan_naming_send(irep, idx, insn, insn.sym, 1)
          elsif BytecodeIR::Ops::SEND.include?(insn.op) && FORWARDING_SENDS.include?(insn.sym)
            named = insn.plain_fixed_argc? && insn.argc.to_i.positive? && literal_symbol(irep, idx, (insn.reg + 1))
            scan_naming_send(irep, idx, insn, named, 2) if named && NAMING_SENDS.include?(named)
          end
        end
      end
    end

    # The registry owns a def by its lexical class; one inside a block (Class.new { def ... }) lands on
    # a class chosen at run time, so it also counts under an owner that every class can reach.
    def scan_definition_op(irep, idx, insn, known, in_closure)
      label = CoreDefs.def_body_label(irep, insn, idx)
      return @dynamic_sites << [irep.label, idx, insn.op] if label.nil?
      return unless in_closure || !known[insn.sym].include?(label)

      owner = in_closure ? '<scoped>' : '<def-op>'
      @defs[insn.sym] << MethodDef.new(name: insn.sym, owner: owner, irep: label, visibility: :public)
    end

    # +first+: argument slot of the first name (1, or 2 behind the method name of a forwarding send).
    def scan_naming_send(irep, idx, insn, sym, first)
      count = insn.plain_fixed_argc? ? insn.argc.to_i : -1
      last = count - first + 1
      names = last.positive? ? (first..count).map { |k| literal_symbol(irep, idx, (insn.reg + k)) } : []
      literal = !names.empty? && names.none?(&:nil?)
      case sym
      when 'alias_method'
        return @dynamic_sites << [irep.label, idx, sym] unless literal && names.size == 2

        @aliases[names[0]] << names[1]
      when 'define_method', 'define_singleton_method'
        return @dynamic_sites << [irep.label, idx, sym] unless literal

        @defs[names[0]] << MethodDef.new(name: names[0], owner: '<define_method>', irep: nil, visibility: :public,
                                         installer: :define_method)
      end
    end

    # The Symbol every definition reaching +reg+ loads, or nil.
    def literal_symbol(irep, idx, reg)
      defs = BytecodeIR.reaching_definitions(irep, idx, reg, shared: true)
      return nil if defs.nil? || defs.empty? || defs.any?(&:entry?)

      loads = defs.map { |d| EscapeAnalysis.insn_at(irep, d.index) }
      loads.first.sym if loads.all? { |l| l.op == :LOADSYM } && loads.map(&:sym).uniq.size == 1
    end
  end

  BLKPUSH = %i[BLKPUSH].freeze
  REF_OPS = %i[GETUPVAR BLKPUSH].freeze

  class Analyzer
    MAX_DEPTH = 24
    STEP_CAP = 20_000
    NONE = Float::INFINITY

    # Callbacks that sharpen callee sets from the compiler's class flow (nil = by name only):
    #   receiver_classes.call(irep, index, reg) -> every class that register may hold at that instruction
    #   self_class.call(irep) -> the class or module whose method the irep belongs to
    attr_reader :world
    attr_accessor :receiver_classes, :self_class

    def initialize(world)
      @world = world
      @memo = {}
      @stack = []
      @floor = NONE
      @refs = {}
      @native_arg_busy = Set.new
    end

    CREATED_CLASS = { :LAMBDA => 'Proc', :BLOCK => 'Proc', :ARRAY => 'Array', :HASH => 'Hash',
                      :STRING => 'String', :RANGE_INC => 'Range', :RANGE_EXC => 'Range' }.freeze
    # The `new` check covers the argument-less form too (SEND0, `Keeper.new`), which the IR files apart from SEND.
    NEW_SENDS = Set[:SEND0, :SEND, :SENDB].freeze

    # The value written to the leading register of the instruction at +index+: a LAMBDA, BLOCK, ARRAY, HASH,
    # STRING or the result of a `new` send (then +value_class+ is the constructed class when known).
    def creation(irep, index, value_class: nil, self_klass: nil)
      insn = EscapeAnalysis.insn_at(irep, index)
      return failed(:no_destination) unless insn.reg
      return failed(:reflection) unless @world.reflective_sites.empty?
      # A frozen literal is one persistent object shared by every load, not a fresh creation.
      return failed(:frozen_literal) if insn.frozen_literal
      # `new` runs the constructor with the new object as self, so the constructor must not keep it.
      if NEW_SENDS.include?(insn.op) && insn.sym == 'new'
        return failed(:initialize_unknown) unless value_class
        return failed(:initialize_keeps_self) unless initialize_keeps_no_self?(value_class)
      end

      flow(irep, { index => { insn.reg => true } }, created_at: index,
                                                   value_class: CREATED_CLASS[insn.op] || value_class,
                                                   self_klass: self_klass)
    end

    # Does the constructor of +klass+ keep no reference to self? BasicObject#initialize is mrb_do_nothing
    # (3rd/mruby src/class.c, bob_rom_entries), which keeps neither its arguments nor self; any other
    # native initialize on the ancestry refuses, and so does an opaque or installed one.
    def initialize_keeps_no_self?(klass)
      chain = @world.ancestry(klass)
      list = chain && @world.defs_for('initialize', [klass], true)
      return false if list.nil? || installer?(list) || !opaque_defs(list).empty?
      return false if @world.native_name?('initialize') && !@world.native_free_on?('initialize', chain - ['BasicObject'])

      list.none? { |d| captures?(d, [:self]) }
    end

    # true when +mdef+ may keep its +position+ ([:self], [:self_keep], [:arg, k] or [:block]) or it cannot be shown.
    def captures?(mdef, position)
      return true unless @world.reflective_sites.empty?

      cyclic([:summary, mdef.object_id, position]) { compute_summary(mdef, position) }
    end

    # true when +mdef+ may return its receiver as its result on some path. Inside a cycle it is assumed true:
    # the caller then tracks the call's result, which only adds reasons, so the answer is never too small.
    def returns_self?(mdef)
      return true unless @world.reflective_sites.empty?

      cyclic([:summary, mdef.object_id, :self_returns], assume: true) { compute_summary(mdef, [:self_returns]) }
    end

    # returns_self? for a receiver of exactly +klass+ when the call passes a block (see literal_block_send?): the block
    # tests are decided, so an arm that returns to_enum without one does not count as returning self.
    def returns_self_given?(mdef, klass)
      return returns_self?(mdef) unless @world.reflective_sites.empty? && plain_body?(mdef) && @world.plain_class?(klass)

      cyclic([:self_returns_as, mdef.object_id, klass], assume: true) do
        irep = body_irep(mdef)
        if irep.nil?
          true
        else
          verdict = flow(irep, { 0 => { 0 => true } }, self_tracked: true, returns: true, value_class: klass,
                                                         block_given: true)
          verdict.escapes? || verdict.returned == true
        end
      end
    end

    # RBS_RECORD_TYPES' interprocedural scan: may a call of +name+ keep its argument +k+? Callees
    # are every definition the name reaches (the by-name set); a native or unenumerable one keeps it. With
    # +klass+ the argument is known to be exactly an instance of that class, so each callee's own sends on it
    # resolve through that class's ancestry (the summary is computed and memoised per class).
    def name_captures_arg?(name, k, klass: nil)
      return true unless @world.reflective_sites.empty?

      arg_captured_by_name?(name, k, @world.defs_named(name), klass, value_class: klass)
    end

    # Does the closure BLOCK/LAMBDA at irep[index] leave its frame?
    # +self_klass+: the frame's self class when the frame is a method body given one (see block_captures_as?).
    def closure_escapes?(irep, index, self_klass = nil)
      cyclic([:closure, irep.label, index, self_klass]) { creation(irep, index, self_klass: self_klass).escapes? }
    end

    # The method's own block, for BlockYielders: a method whose closures read its block from a nested level is refused
    # (the block could be yielded from there). Otherwise the uses of the block: a `yield` is a :call use.
    def method_block_verdict(irep)
      return failed(:nested_block_reads) if nested_block_reads?(irep)

      block_verdict(irep)
    end

    # The verdict on a method's own block (see block_captured?): its uses are the calls made on it, so a `yield` is a
    # :call use.
    def block_verdict(irep, self_klass: nil)
      fields = irep.enter ? irep.enter.enter_fields : []
      sources = EscapeAnalysis.op_sites(irep, BLKPUSH).filter_map { |insn, j| j if insn.paren_int.to_i.zero? }
      starts = {}
      local = nil
      if fields[6].to_i.positive?
        return failed(:block_param_kept) if fields[4].to_i.positive? || fields[5].to_i.positive?

        local = 1 + fields[0].to_i + fields[1].to_i + fields[2].to_i + fields[3].to_i
        starts[0] = { local => true }
      end
      if starts.empty? && sources.empty? && !nested_block_reads?(irep)
        return Verdict.new(reasons: [], uses: [], tracked: Set.new)
      end

      flow(irep, starts, block_sources: sources, block_tracked: true, value_class: 'Proc', self_klass: self_klass)
    end

    private

    # Memoised boolean "bad" (captures / escapes). A key found on the stack is assumed good (false) unless
    # +assume+ says otherwise; a result computed under such an assumption is kept only if it is bad
    # (monotone: the assumption can only remove reasons) or the assumed frame is this one.
    def cyclic(key, assume: false)
      return @memo[key] if @memo.key?(key)

      if (at = @stack.index(key))
        @floor = [@floor, at].min
        return assume
      end
      return true if @stack.size >= MAX_DEPTH

      saved = @floor
      @floor = NONE
      @stack.push(key)
      result = yield
      @stack.pop
      assumed = @floor
      @memo[key] = result if result || assumed >= @stack.size
      @floor = [saved, assumed < @stack.size ? assumed : NONE].min
      result
    end

    # -- summaries --------------------------------------------------------------------------------
    def compute_summary(mdef, position)
      return position[0] == :arg && mdef.name.end_with?('=') if mdef.irep.nil? && mdef.kind == :ivar_accessor

      irep = body_irep(mdef) or return true
      case position[0]
      when :self then flow(irep, { 0 => { 0 => true } }, self_tracked: true).escapes?
      when :self_keep then flow(irep, { 0 => { 0 => true } }, self_tracked: true, returns: true).escapes?
      when :self_returns
        verdict = flow(irep, { 0 => { 0 => true } }, self_tracked: true, returns: true)
        verdict.escapes? || verdict.returned == true
      when :arg then arg_captured?(irep, position[1])
      when :block then block_captured?(irep)
      else true
      end
    end

    # [:self_keep] of +mdef+ for a receiver of exactly +klass+: its implicit-self sends resolve on that class (see
    # callees), so a Ruby method is judged on the definitions its receiver class reaches, not every one of the name.
    # The exact class is the receiver's own (a held register of the caller), so this is only as sound as that class.
    # +block_given+: see literal_block_send?.
    def self_captures_as?(mdef, klass, block_given: false)
      return captures?(mdef, [:self_keep]) unless plain_body?(mdef) && @world.plain_class?(klass)

      cyclic([:self_as, mdef.object_id, klass, block_given]) do
        irep = body_irep(mdef)
        irep.nil? ||
          flow(irep, { 0 => { 0 => true } }, self_tracked: true, returns: true, value_class: klass,
                                               block_given: block_given).escapes?
      end
    end

    # [:block] of +mdef+ for a receiver of exactly +klass+: self is that class, so the body's own calls on self (the
    # Enumerable bodies' self.each) resolve on it. Only plain `def`s: a module_function copy or an installed body has
    # another self, so those keep the by-name summary.
    def block_captures_as?(mdef, klass)
      return captures?(mdef, [:block]) unless plain_body?(mdef) && @world.plain_class?(klass)

      cyclic([:block_as, mdef.object_id, klass]) do
        irep = body_irep(mdef)
        irep.nil? || block_captured?(irep, self_klass: klass)
      end
    end

    # A `def` in a class or module body: its self is an instance of the class it is reached through. A scoped def
    # (Class.new { def }), an installed or module_function body, or a singleton one has another self.
    def plain_body?(mdef)
      mdef.kind.nil? && mdef.installer.nil? && !mdef.owner.start_with?('<') && !mdef.owner.end_with?('.singleton')
    end

    def body_irep(mdef)
      return nil if mdef.installer

      label = mdef.irep || (mdef.kind == :module_function ? mdef.copy_irep : nil)
      label && @world.ireps[label]
    end

    # Leading mandatory arguments sit in R1.. on entry; other layouts are not modelled. +klass+: the exact
    # class of the argument, when the caller knows it.
    def arg_captured?(irep, k, klass = nil)
      enter = irep.enter
      return true unless enter && k < enter.enter_fields[0].to_i

      flow(irep, { 0 => { 1 + k => true } }, value_class: klass).escapes?
    end

    # [:arg, k] of +mdef+ for an argument that is exactly a +klass+ instance.
    def arg_captured_as?(mdef, k, klass)
      cyclic([:summary_as, mdef.object_id, k, klass]) do
        if mdef.irep.nil? && mdef.kind == :ivar_accessor
          mdef.name.end_with?('=')
        else
          irep = body_irep(mdef)
          irep.nil? || arg_captured?(irep, k, klass)
        end
      end
    end

    # The block of a method is born at BLKPUSH (level 0) and, with a block parameter, in its local.
    def block_captured?(irep, self_klass: nil)
      block_verdict(irep, self_klass: self_klass).escapes?
    end

    def nested_block_reads?(irep)
      closure_children(irep).any? { |_, child| subtree_refs(child, 0, []).any? { |ref| ref[:kind] == :blk } }
    end

    # -- the frame flow ------------------------------------------------------------------------------
    # Per-run state shared by the transfer functions.
    # returns: the frame may hand the value back as its result (RETSELF / RETURN of a holding register); the
    # exit is recorded in returned instead of escaping. Only the method's own frame is run that way.
    # self_klass: the exact class of register 0 (self) when it is not tracked (see block_captures_as?).
    # block_given: the frame's block (block_slot) is a Proc on every entry (see literal_block_send?).
    Run = Struct.new(:irep, :reasons, :uses, :self_tracked, :params, :block_slot, :value_class, :returns,
                     :returned, :self_klass, :block_given, keyword_init: true)

    # +starts+: { instruction index => { register => true } }. With +created_at+ the start index is the
    # creating instruction and the value enters its SUCCESSORS (and again whenever it runs); otherwise the
    # state holds on entry to that index. +block_sources+: BLKPUSH indices that introduce the value;
    # +block_tracked+: the value is a method's block, so closures that BLKPUSH it from a nested level see it.
    def flow(irep, starts, created_at: nil, self_tracked: false, block_sources: [], block_tracked: false,
             value_class: nil, returns: false, self_klass: nil, block_given: false)
      prog = BytecodeIR.for(irep)
      return failed(:cfg_unresolved) unless prog.resolved?
      return failed(:handlers_unresolved) unless prog.handlers_resolved?

      insns = prog.instructions
      params = parameter_count(irep)
      run = Run.new(irep: irep, reasons: [], uses: [], self_tracked: self_tracked, params: params,
                    block_slot: params + 1, value_class: value_class, returns: returns, returned: false,
                    self_klass: self_klass, block_given: block_given)
      state = Array.new(insns.size)
      work = []
      seed = lambda do |index, regs|
        next if regs.empty? || index >= insns.size

        cur = state[index]
        merged = cur ? cur | regs : regs.to_set
        next if cur && merged.size == cur.size

        state[index] = merged
        work << index
      end
      starts.each do |index, regs|
        if created_at
          insns[index].successors.each { |succ| seed.call(succ, regs.keys) }
        else
          seed.call(index, regs.keys)
        end
      end
      block_sources.each do |j|
        insns[j].successors.each { |succ| seed.call(succ, [insns[j].source.reg]) }
      end

      ever = Set.new
      steps = 0
      until work.empty?
        i = work.pop
        return failed(:state_cap) if (steps += 1) > STEP_CAP

        s = state[i]
        ever.merge(s)
        out = step(run, i, insns[i].source, s)
        unless run.reasons.empty?
          return Verdict.new(reasons: run.reasons, uses: run.uses.uniq, tracked: ever, returned: run.returned)
        end

        out = out | [insns[i].source.reg] if i == created_at
        normal = block_test_successors(run, prog, i) || insns[i].successors
        normal.each { |succ| seed.call(succ, out.to_a) }
        # Handler edges only: a successor the block test decided away is not re-seeded from here.
        (prog.successors_of(i, include_handlers: true) - insns[i].successors).each do |succ|
          seed.call(succ, (s | out).to_a)
        end
      end

      ever.merge(Array(starts.values.flat_map(&:keys)))
      read_by_closures(run, ever, block_tracked: block_tracked)
      Verdict.new(reasons: run.reasons, uses: run.uses.uniq, tracked: ever, returned: run.returned)
    end

    def failed(reason)
      Verdict.new(reasons: [[reason, 0]], uses: [], tracked: Set.new)
    end

    # The successors of a jump on the block slot's entry value (`unless block`) when the block is given (see
    # literal_block_send?), else nil. A write to the slot, from this frame or a nested block, refuses.
    def block_test_successors(run, prog, index)
      return nil unless run.block_given
      # A jump with a handler edge is left alone: the handler could reach the edge the test drops.
      return nil if prog.raise_targets[index]

      insn = prog.source_at(index)
      return nil unless %i[JMPIF JMPNOT JMPNIL].include?(insn.op)

      defs = prog.reaching_definitions(index, insn.reg, opaque_regs: BytecodeIR.own_upvar_written_regs(run.irep),
                                                             shared: true)
      return nil unless defs&.any? && defs.all? { |d| block_slot_entry?(run, prog, d) }

      if insn.op == :JMPIF
        target = prog.address_to_index[insn.branch_target]
        target && [target]
      else
        index + 1 < prog.size ? [index + 1] : []
      end
    end

    # A definition that is the block slot's value on entry: the ENTRY pseudo-definition, or the ENTER that stores the slot.
    def block_slot_entry?(run, prog, defn)
      return false unless defn.reg == run.block_slot

      defn.entry? || (defn.built == :block && prog.source_at(defn.index).op == :ENTER)
    end

    # The block of this SENDB/SSENDB is the BLOCK made in this frame, so the callee gets a Proc and its `unless block`
    # arm (Array#each's to_enum) is not taken: the callee is judged with the block given (block_test_successors). A
    # variable, `&blk` or several writers may hold nil, and keep the by-name verdict.
    def literal_block_send?(irep, index, insn, block)
      return false unless block && %i[SENDB SSENDB].include?(insn.op)

      prog = BytecodeIR.for(irep)
      defs = prog.reaching_definitions(index, block, shared: true)
      defs&.size == 1 && !defs.first.entry? && prog.source_at(defs.first.index).op == :BLOCK
    end

    # Registers R1..R<n> are the parameters; the block slot follows. ARGARY (zsuper) and BLKPUSH read them
    # without printing them.
    def parameter_count(irep)
      fields = irep.enter ? irep.enter.enter_fields : []
      fields.first(6).sum(&:to_i)
    end

    # -- one instruction -----------------------------------------------------------------------------
    # The registers holding the value after +insn+; appends to run.reasons when it escapes.
    def step(run, i, insn, s)
      op = insn.op
      lead = BytecodeIR::OperandModel.reg(insn)
      escape = ->(why) { run.reasons << [why, insn.addr] }
      held = ->(r) { s.include?(r) }
      window = ->(from, count) { (0...count).any? { |k| held.call(from.to_i + k) } }

      return s if PASSES.include?(op)
      return s - [lead] if KILLS_LEAD.include?(op)

      if STORES_LEAD.key?(op)
        # Only a `returns` flow may hand the receiver back (the caller tracks the result); elsewhere it escapes.
        if op == :RETURN && run.returns
          run.returned = true if held.call(BytecodeIR::OperandModel.reg_operand(insn))
        elsif held.call(BytecodeIR::OperandModel.reg_operand(insn))
          escape.call(STORES_LEAD[op])
        end
        return s
      end

      case op
      when :MOVE then s - [lead] | (held.call(BytecodeIR::OperandModel.move(insn).src) ? [lead] : [])
      when :LOADSELF then s - [lead] | (s.include?(0) ? [lead] : [])
      when :RETSELF
        if s.include?(0) && run.returns
          run.returned = true
        elsif s.include?(0)
          escape.call(:returned)
        end
        s
      when :RESCUE
        operands = BytecodeIR::OperandModel.regs(insn)
        escape.call(:rescue_operand) if held.call(operands[0]) || held.call(operands[1])
        s - [operands[1]]
      when :ARGARY
        escape.call(:stored_array) if s.any? { |r| r.to_i.between?(1, run.params) }
        s - [lead]
      when :BLKPUSH
        s - [lead] | (BytecodeIR::OperandModel.paren_int(insn).to_i.zero? && held.call(run.block_slot) ? [lead] : [])
      when *BINARY_NAMES.keys
        send_site(run, i, insn, s, BINARY_NAMES[op], recv: lead, args: [lead.to_i + 1], dest: lead)
      when :ADDI, :SUBI
        send_site(run, i, insn, s, op == :ADDI ? '+' : '-', recv: lead, args: [], dest: lead)
      when :ADDILV, :SUBILV
        # R[b], R[b+1] are the scratch window of the method-call fallback: written, never read.
        second = BytecodeIR::OperandModel.regs(insn)[1]
        scratch = [second, second.to_i + 1]
        send_site(run, i, insn, s, op == :ADDILV ? '+' : '-', recv: lead, args: [], dest: lead) - scratch
      when :GETIDX then send_site(run, i, insn, s, '[]', recv: lead, args: [lead.to_i + 1], dest: lead)
      when :GETIDX0 then send_site(run, i, insn, s, '[]', recv: BytecodeIR::OperandModel.regs(insn)[1], args: [], dest: lead)
      when :SETIDX
        send_site(run, i, insn, s, '[]=', recv: lead, args: [lead.to_i + 1, lead.to_i + 2], dest: lead)
      when *BytecodeIR::Ops::SEND then send_op(run, i, insn, s)
      when :BLKCALL
        escape.call(:block_call_argument) if window.call(lead.to_i + 1, BytecodeIR::OperandModel.uint_operand(insn).to_i)
        run.uses << Use.new(index: i, kind: :call, name: 'call', reg: lead) if held.call(lead)
        s - [lead]
      when :SUPER
        positional, kw = argument_slots(insn)
        escape.call(:super_window) if window.call(lead, positional + kw + 2) || s.include?(0)
        s - [lead]
      when :ARRAY
        three = BytecodeIR::OperandModel.src_and_literal(insn)
        escape.call(:stored_array) if window.call(three ? three[0] : lead,
                                                  three ? three[1].to_i : BytecodeIR::OperandModel.uint_operand(insn).to_i)
        s - [lead]
      when :ARYCAT, :HASHCAT, :ARYSPLAT
        escape.call(:spread_operand) if window.call(lead, 2)
        s - [lead]
      when :ARYPUSH
        escape.call(:stored_array) if window.call(lead.to_i + 1, BytecodeIR::OperandModel.uint_operand(insn).to_i)
        s
      when :HASH
        escape.call(:stored_hash) if window.call(lead, 2 * BytecodeIR::OperandModel.uint_operand(insn).to_i)
        s - [lead]
      when :HASHADD
        escape.call(:stored_hash) if window.call(lead.to_i + 1, 2 * BytecodeIR::OperandModel.uint_operand(insn).to_i)
        s
      when :APOST
        s - (0..BytecodeIR::OperandModel.post_count(insn)).map { |k| lead.to_i + k }
      when :STRCAT
        # A String operand is copied; anything else is converted by its own to_s.
        escape.call(:string_operand) if held.call(lead.to_i + 1) && run.value_class != 'String'
        s
      when *CLOSURE_OPS then s - [lead]
      when *WINDOW_OPS
        escape.call(:class_machinery) if window.call(lead, 2) || s.include?(0)
        s - [lead]
      else
        escape.call(:unmodelled_op)
        s
      end
    end

    # -- sends ---------------------------------------------------------------------------------------
    # [positional slots, keyword slots] after the receiver; `n=*` packs the arguments in one slot.
    def argument_slots(insn)
      [insn.positional_slots, insn.keyword_slots]
    end

    def send_op(run, i, insn, s)
      call = BytecodeIR::OperandModel.send_call(insn)
      a = call.receiver.to_i
      positional, kw = argument_slots(insn)
      spread = insn.positional_splat?
      unpacked = spread ? [a + 1] : []
      unpacked += ((a + positional + 1)..(a + positional + kw)).to_a
      return reject(run, insn, :spread_or_keyword_argument, s) if unpacked.any? { |r| s.include?(r) }

      send_site(run, i, insn, s, call.name, recv: BytecodeIR::Ops::SELF_SEND_FAMILY.include?(insn.op) ? nil : a,
                args: spread ? [] : (1..positional).map { |k| a + k }, dest: a,
                block: BytecodeIR::Ops::BLOCK_SEND_FAMILY.include?(insn.op) ? a + positional + kw + 1 : nil)
    end

    # The shared send rule; returns the registers holding the value after the call.
    def send_site(run, i, insn, s, name, recv:, args:, dest:, block: nil)
      out = s - [dest]
      reg_held = ->(r) { r && s.include?(r) }
      held = recv.nil? ? s.include?(0) : reg_held.call(recv)
      klasses = receiver_klasses(run, i, recv, held)
      list = callees(run, name, recv, klasses)
      if held
        # The exact class's ancestry, when callees resolved by it (the same test as in callees). A self-tracked run
        # is a summary of one method for receivers of exactly run.value_class (see self_captures_as?).
        exact = run.value_class && (recv ? reg_held.call(recv) : run.self_tracked)
        chain = exact ? @world.ancestry(run.value_class) : nil
        given = literal_block_send?(run.irep, i, insn, block)
        result = receiver_result(name, list, chain, exact ? run.value_class : nil, block_given: given)
        return reject(run, insn, :send_receiver, s) unless result

        run.uses << Use.new(index: i, kind: :call, name: name, reg: recv) if recv && PROC_CALLS.include?(name)
        out |= [dest] if result == :self
      end
      args.each_with_index do |r, k|
        next unless reg_held.call(r)
        # A held register is this run's one tracked object, so its class is run.value_class (see arg_captured_as?).
        # The same class narrows native callback resolution (value_class:).
        if arg_captured_by_name?(name, k, list, run.value_class, value_class: run.value_class)
          return reject(run, insn, :send_argument, s)
        end

        run.uses << Use.new(index: i, kind: :pass_arg, name: name, reg: r)
      end
      if reg_held.call(block)
        klass = klasses&.size == 1 ? klasses.first : nil
        return reject(run, insn, :send_block, s) if block_captured_by_name?(name, list, klass)

        run.uses << Use.new(index: i, kind: :pass_block, name: name, reg: block)
      end
      out
    end

    # Definitions the call can reach: by the receiver's class when something proves it (the tracked
    # value's own class, the compiler's class flow, the class whose method this is for an implicit
    # self), else every definition of the name. nil when the world cannot enumerate them.
    def callees(run, name, recv, klasses)
      if recv.nil? && klasses.nil?
        owner = run.self_tracked ? nil : @self_class&.call(run.irep)
        return @world.defs_for(name, owner && [owner], false)
      end

      @world.defs_for(name, klasses, true)
    end

    # The classes a call's receiver is, exactly, when the run proves them: the tracked value (a held register of
    # value_class; self of a self-tracked run), self of a run given its class (self_klass), else the class flow.
    # nil when unknown. An implicit-self call (recv nil) with neither is the owner-based callee set in callees.
    def receiver_klasses(run, index, recv, receiver_held)
      if recv.nil?
        return run.self_tracked ? (run.value_class && [run.value_class]) : (run.self_klass && [run.self_klass])
      end
      return [run.value_class] if receiver_held && run.value_class
      return [run.self_klass] if recv == 0 && run.self_klass

      @receiver_classes&.call(run.irep, index, recv)
    end

    def reject(run, insn, why, s)
      run.reasons << [why, insn.addr]
      s
    end

    # Definitions in +list+ with no analysable body that are not a plain accessor: natives the registry
    # lists, Struct members, module_function copies without a body.
    def opaque_defs(list)
      list.select { |d| body_irep(d).nil? && !(d.irep.nil? && d.kind == :ivar_accessor) }
    end

    # A definition installed by define_method has a block body whose parameters are not modelled.
    def installer?(list)
      list.any?(&:installer)
    end

    # :fresh / :self when no definition in +list+ keeps the receiver, else nil. A native counts only
    # through NATIVE_RECEIVER_OK; the rest is each bytecode definition's [:self] summary.
    # +chain+: the ancestry of an exact receiver class, when the caller knows it. A name with no native
    # definition on that chain cannot be the native the by-name veto is for, so the veto does not apply.
    def receiver_result(name, list, chain = nil, klass = nil, block_given: false)
      result = name_receiver_result(name, list, chain, NATIVE_RECEIVER_OK[name], klass, block_given: block_given)
      return nil if result.nil?

      # Each callback is checked by name with no callbacks of its own, so the check cannot recurse.
      callbacks_ok = NATIVE_RECEIVER_CALLBACKS.fetch(name, []).all? do |callback|
        name_receiver_result(callback, @world.defs_named(callback), nil)
      end
      callbacks_ok ? result : nil
    end

    # +table+: the natives' receiver fact (NATIVE_RECEIVER_OK by default; a callback named by NATIVE_ARG_OK
    # passes its own audited fact).
    # +klass+: the receiver's exact class when it is the tracked value (then the bodies' summaries are per class).
    def name_receiver_result(name, list, chain, table = NATIVE_RECEIVER_OK[name], klass = nil, block_given: false)
      return nil if list.nil? || installer?(list)

      opaque = opaque_defs(list)
      native_free = chain && @world.native_free_on?(name, chain)
      return nil if table.nil? && (list.empty? || (@world.native_name?(name) && !native_free) || !opaque.empty?)
      bytecode = list.reject { |d| opaque.include?(d) }
      if bytecode.any? { |d| klass ? self_captures_as?(d, klass, block_given: block_given) : captures?(d, [:self_keep]) }
        return nil
      end

      # A bytecode definition that returns its receiver makes the result the receiver too.
      given = block_given && klass
      return :self if table == :self || bytecode.any? { |d| given ? returns_self_given?(d, klass) : returns_self?(d) }

      table || :fresh
    end

    # A name with a native definition keeps every argument unless NATIVE_ARG_OK audits that position (see
    # native_arg_ok?). The <native> definitions in +list+ are those natives, so they are not the opaque veto.
    # +value_class+: the exact class of the argument, when known. It only narrows the Ruby callbacks a native
    # makes with the argument (native_arg_ok?); the argument's own summaries keep +klass+ as before.
    def arg_captured_by_name?(name, k, list, klass = nil, value_class: nil)
      return true if list.nil? || installer?(list)
      # An audited native may have an empty list: defs_for drops the <native> definitions by ancestry, so an
      # empty list means no Ruby callee of the name.
      return true if @world.native_name?(name) ? !native_arg_ok?(name, k, value_class) : list.empty?
      return true unless opaque_defs(list).all? { |d| native_def?(d) }

      list.any? { |d| !native_def?(d) && (klass ? arg_captured_as?(d, k, klass) : captures?(d, [:arg, k])) }
    end

    def native_def?(mdef)
      mdef.owner == '<native>'
    end

    # Argument +k+ of every native of +name+ is kept by none of them (NATIVE_ARG_OK), and each Ruby method the
    # natives call with it keeps nothing. Callbacks on the argument resolve on +value_class+ when it is known
    # (the argument is exactly that class), else on every definition of the name. A callback cycle refuses.
    def native_arg_ok?(name, k, value_class)
      entry = NATIVE_ARG_OK[name]
      return false unless entry && entry[:args].include?(k) && @world.native_files_audited?(name, entry[:files])
      # +only+: the audit holds for these exact argument classes alone (see the NATIVE_ARG_OK entry).
      return false if entry[:only] && !entry[:only].include?(value_class)
      return false unless @native_arg_busy.add?(name)

      begin
        return false unless entry[:recv].all? { |callback| callback_receiver_ok?(callback, value_class) }

        # The argument is an argument of +callback+ here; that call's receiver is some other value.
        entry.fetch(:arg, []).all? do |callback, pos|
          !arg_captured_by_name?(callback, pos, @world.defs_named(callback), nil, value_class: value_class)
        end
      ensure
        @native_arg_busy.delete(name)
      end
    end

    # True when no method +name+ reaches on a receiver of +value_class+ keeps that receiver (nil: any definition).
    def callback_receiver_ok?(name, value_class)
      table = NATIVE_RECEIVER_OK[name] || NATIVE_ARG_OK.dig(name, :receiver)
      list = value_class ? @world.defs_for(name, [value_class], true) : @world.defs_named(name)
      !name_receiver_result(name, list, nil, table).nil?
    end

    # +klass+: the receiver's one exact class, when known (then each callee is judged on that class).
    def block_captured_by_name?(name, list, klass = nil)
      return true if list.nil? || installer?(list)

      opaque = opaque_defs(list)
      natives = @world.native_name?(name) || !opaque.empty?
      return true if (natives || list.empty?) && !NATIVE_BLOCK_NO_CAPTURE.include?(name)

      list.any? { |d| !opaque.include?(d) && (klass ? block_captures_as?(d, klass) : captures?(d, [:block])) }
    end

    # -- closures that can see the value ---------------------------------------------------------------
    # A closure made in this frame reads the frame's variables when it runs: a captured local (GETUPVAR),
    # the method block (BLKPUSH from a nested level) or, for self, implicitly. It sees the value safely
    # only if neither it nor any closure between it and the reading frame escapes, and the value does not
    # escape in the reading frame.
    def read_by_closures(run, ever, block_tracked:)
      irep = run.irep
      closure_children(irep).each do |ci, child|
        refs = closure_refs(irep, ci, child).select do |ref|
          ref[:kind] == :blk ? block_tracked : ever.include?(ref[:idx])
        end
        next if refs.empty? && !run.self_tracked

        reason = closure_reason(irep, ci, child, refs, run)
        next unless reason

        run.reasons << [reason, EscapeAnalysis.insn_at(irep, ci).addr]
        return
      end
    end

    # The exact class of the frame's self when the run knows it: the tracked self of a self-tracked run is an instance of
    # value_class (see receiver_klasses), else the class the run was given. A closure of the frame shares that self.
    def frame_self_klass(run)
      run.self_tracked ? run.value_class : run.self_klass
    end

    def closure_refs(irep, ci, child)
      @refs[[irep.label, ci]] ||= subtree_refs(child, 0, [[irep, ci]])
    end

    def closure_reason(irep, ci, child, refs, run)
      return :captured_by_escaping_closure if closure_escapes?(irep, ci, frame_self_klass(run))

      refs.each do |ref|
        return :captured_by_escaping_closure if ref[:chain].any? do |(owner, index)|
          closure_escapes?(owner, index, owner.equal?(irep) ? frame_self_klass(run) : nil)
        end

        verdict = flow(ref[:irep], { ref[:index] => { ref[:dest] => true } }, created_at: ref[:index],
                       value_class: run.value_class)
        return verdict.reason if verdict.escapes?
      end
      return nil unless run.self_tracked

      verdict = flow(child, { 0 => { 0 => true } }, self_tracked: true)
      verdict.escapes? ? verdict.reason : nil
    end

    # [[closure instruction index, child irep]] of +irep+.
    def closure_children(irep)
      BytecodeIR::Tree.children(irep, @world.ireps, CLOSURE_OPS)
    end

    # Reads (GETUPVAR/BLKPUSH) inside +irep+'s closure subtree that resolve to the frame +irep+ is a closure
    # of (+depth+ 0 = a read in +irep+ itself). +chain+: the [irep, closure index] pairs that carry the read
    # out of that frame. A SETUPVAR only writes the frame's register, so it is no read.
    def subtree_refs(irep, depth, chain)
      refs = []
      BytecodeIR::Tree.each_subtree(irep, @world.ireps, CLOSURE_OPS, depth, chain) do |node, d, c|
        BytecodeIR.for(node).each_with_op(*REF_OPS) do |insn, j|
          if insn.op == :GETUPVAR
            idx, level = insn.upvar_ref
            refs << { kind: :up, idx: idx, irep: node, index: j, dest: insn.reg, chain: c } if level == d
          elsif insn.paren_int == d + 1
            refs << { kind: :blk, irep: node, index: j, dest: insn.reg, chain: c }
          end
        end
      end
      refs
    end
  end
end

require_relative 'escape_immediate_ivars'
