# frozen_string_literal: true

# Steps 6c-6f-ter: call-site argument types and `# bc2cpp:` annotations.

# ---------------------------------------------------------------------------
# Step 6c: whole-program call-site argument-type inference. For a MONO name
# every call site reaches the one definition, so if every caller's argument
# at position k traces to Fixnum (IvarLayout.trace_type), position k is Fixnum.
# POLY names are skipped: their call sites may target different methods.
# Feeds IvarLayout's incoming-argument fallback.
class ArgTypes
  def self.analyze(ireps, registry)
    types = {}

    registry.each do |name, defs|
      next unless defs.size == 1 # MONO names only -- see this class's own comment.
      next unless defs.first.irep # native-only definition -- no bytecode body to walk.

      irep = ireps.fetch(defs.first.irep)
      enter = irep.instructions.find { |i| i.op == 'ENTER' }
      mand = enter ? enter.args.split(':').first.to_i : 0
      next if mand.zero?

      arg_types = Array.new(mand)
      ireps.each_value do |caller_irep|
        caller_irep.instructions.each_with_index do |insn, idx|
          next unless %w[SEND0 SEND SSEND0 SSEND].include?(insn.op)
          # Same charset as compile_send's name extraction (so operator names match).
          next unless insn.args[/:([\w+\-*\/<>=!?\[\]&|^~%@]+)/, 1] == name

          d = insn.args[/^R(\d+)/, 1].to_i
          n = insn.args[/n=(\d+)/, 1].to_i
          next unless n == mand # a real call site to a MONO name always matches its one definition's arity.

          (1..mand).each do |k|
            # No caller ivar context here: a GETIV-sourced argument traces to UNKNOWN,
            # which is safe.
            t = IvarLayout.trace_type(caller_irep, idx, (d + k).to_s, {}, nil, 0, nil, nil, registry)
            arg_types[k - 1] = IvarLayout.join(arg_types[k - 1], t)
          end
        end
      end

      types[name] = arg_types.map { |t| t == IvarLayout::UNKNOWN ? nil : t }
    end

    types
  end
end

# ---------------------------------------------------------------------------
# Step 6d: magic-comment argument-type annotations, for what ArgTypes cannot
# see: #initialize's arguments (`X.new` is a native SEND :new, never SEND
# :initialize). An annotation sits on one `def`, so it is sound for POLY names
# too. Syntax, on the line above the def (blank lines skipped):
#   # bc2cpp: (fixnum, fixnum) -> fixnum
#   def initialize(x, y)
# mrbc drops comments, so the interpreted path is unaffected. A wrong
# annotation cannot corrupt memory: every embedded SETIV re-checks the type
# and raises TypeError. Only fixnum/Integer and symbol tokens mean anything
# for arguments; other tokens contribute nothing.
class Annotations
  TYPES = { 'fixnum' => :fixnum, 'Fixnum' => :fixnum, 'Integer' => :fixnum,
            'symbol' => :symbol, 'Symbol' => :symbol, 'Array' => :array }.freeze
  COMMENT_RE = /^\s*#\s*bc2cpp:\s*\(([^)]*)\)(?:\s*->\s*(\S+))?\s*$/

  Annotation = Struct.new(:args, :ret, keyword_init: true)

  # `:array` (the `Array` token) feeds ONLY the block-receiver return-type gate
  # (annotated_array_return; the emitter's mrb_array_p tripwire checks it at
  # runtime). It must never reach struct-field codegen: native_arg_types has no
  # `:array` arm (KeyError, fail-loud), and IvarLayout.trace_type filters
  # annotation args to :fixnum/:symbol (see EMBED_TYPE_SAFETY there).

  # irep label -> Annotation, for every real `def` (any registry entry with
  # a bytecode body -- a native MethodDef's `irep` is nil, nothing to
  # annotate) whose immediately-preceding source line matches COMMENT_RE.
  def self.extract(ireps, registry)
    result = {}
    file_lines = Hash.new { |h, path| h[path] = File.readlines(path, encoding: 'UTF-8') }

    registry.each_value do |defs|
      defs.each do |d|
        next unless d.irep

        irep = ireps.fetch(d.irep)
        next unless irep.file

        enter = irep.instructions.find { |i| i.op == 'ENTER' }
        next unless enter

        lines = file_lines[irep.file]
        # `enter.lineno` is the `def` line (1-indexed); the annotation is on the
        # preceding non-blank line.
        idx = enter.lineno - 2
        idx -= 1 while idx >= 0 && lines[idx].strip.empty?
        next if idx < 0

        m = COMMENT_RE.match(lines[idx])
        next unless m

        arg_types = m[1].split(',').map { |t| TYPES[t.strip] }
        # ELEMENT_CLASS_SUPPORT: `-> Array<Klass>` is still an `Array` return here; the
        # element half is read separately by ElementAnnotations. Stripping `<...>`
        # keeps `-> Array<Klass>` a strict superset of `-> Array`, and an unknown inner
        # class degrades to plain `-> Array`.
        ret_token = m[2]&.sub(/<.*>\z/, '')
        ret_type = ret_token && TYPES[ret_token]
        result[irep.label] = Annotation.new(args: arg_types, ret: ret_type)
      end
    end

    result
  end
end

# ---------------------------------------------------------------------------
# Step 6f: class-name argument annotations. Same `# bc2cpp: (...)` syntax as
# Annotations, separate reader and claim: "this argument is always exactly this
# class". Never shares Annotations' TYPES: a class name must not reach
# IvarLayout's embedding lattice (no C type to unbox into; C_TYPE.fetch would
# raise). Both readers can share one comment line, since each ignores the
# other's tokens.
class ClassAnnotations
  Annotation = Struct.new(:args, keyword_init: true)

  # `known_owners` (every owner in the registry) gates a token as a class hint,
  # so a random capitalized word is not one. `Array<Klass>`/`Hash<Klass>` read as
  # the outer container class even without registry methods for it;
  # ElementAnnotations handles the inner class.
  def self.extract(ireps, registry, known_owners)
    result = {}
    file_lines = Hash.new { |h, path| h[path] = File.readlines(path, encoding: 'UTF-8') }

    registry.each_value do |defs|
      defs.each do |d|
        next unless d.irep

        irep = ireps.fetch(d.irep)
        next unless irep.file

        enter = irep.instructions.find { |i| i.op == 'ENTER' }
        next unless enter

        lines = file_lines[irep.file]
        idx = enter.lineno - 2
        idx -= 1 while idx >= 0 && lines[idx].strip.empty?
        next if idx < 0

        m = Annotations::COMMENT_RE.match(lines[idx])
        next unless m

        args = m[1].split(',').map do |token|
          token = token.strip
          container_arg = /\A(Array|Hash)<([A-Za-z_][\w:]*)>\z/.match(token)
          token = container_arg[1] if container_arg && %w[Array Hash].include?(container_arg[1]) &&
                                      known_owners.include?(container_arg[2])
          token if known_owners.include?(token) || %w[Array Hash].include?(token)
        end
        next if args.all?(&:nil?)

        result[irep.label] = Annotation.new(args: args)
      end
    end

    result
  end
end

# ---------------------------------------------------------------------------
# Step 6f-ter: ELEMENT_CLASS_SUPPORT, the third reader of the `# bc2cpp:`
# comment: element classes of array results and array arguments.
#   # bc2cpp: () -> Array<Game::Actor>
#   def stat_targets(cmd)
#   # bc2cpp: (Array<Game::Actor>)
#   def initialize(actors)
# Separate from Annotations::TYPES because a class name has no C type.
# `known_owners` gates the inner token; an unknown name contributes nothing.
#
# Trust model (as annotated_array_return): a hand-placed claim, made sound by
# (1) every consumer guarding it at runtime with the exact
# `mrb_class_ptr(...) == mrb_obj_class(M, elem)` check and falling back to
# mrb_funcall, so a wrong claim only costs a failed guard; and (2)
# ArrayElementLayout re-deriving the fact and poisoning on disagreement.
# Two claims from the `-> T` token:
#   - `-> Array<Game::Actor>` (`element`): an Array whose elements are exactly
#     Game::Actor;
#   - `-> Game::Actor` (`ret_class`): the result itself is exactly that class
#     (trace_new_target has no return-type inference, so this is the only
#     source for e.g. what `Game::Actors#[]` returns).
# Both mean "every non-nil value is exactly this class". A nil always fails
# the guard (mrb_obj_class(nil) is NilClass), so nil-returning methods can be
# annotated truthfully.
# `ret_class` also feeds the guarded TYPED tracer; GETIDX/GETIDX0 are included
# because mrbc emits them for `receiver[index]`.
class ElementAnnotations
  Annotation = Struct.new(:element, :ret_class, :arg_elements, :arg_containers, keyword_init: true)

  # One `::`-joined class path, spelled like build_registry's owners. Anchored,
  # so a heterogeneous `Array<Foo, Bar>` does not match.
  ELEMENT_RE = /\AArray<([A-Za-z_][\w:]*)>\z/
  ARG_ELEMENT_RE = /\A(?:Array|Hash)<([A-Za-z_][\w:]*)>\z/
  RET_CLASS_RE = /\A([A-Za-z_][\w:]*)\z/

  # Tokens that already mean something to Annotations::TYPES must not also read
  # as a return class. `Array` is a registry owner (mruby-rgss reopens it), so a
  # plain `-> Array` would otherwise gain a second meaning.
  NON_CLASS_RET_TOKENS = (Annotations::TYPES.keys + ['Array']).uniq.freeze

  # irep label -> Annotation, for defs whose comment has a recognized element or
  # return-class token.
  def self.extract(ireps, registry, known_owners)
    result = {}
    file_lines = Hash.new { |h, path| h[path] = File.readlines(path, encoding: 'UTF-8') }

    registry.each_value do |defs|
      defs.each do |d|
        next unless d.irep

        irep = ireps.fetch(d.irep)
        next unless irep.file

        enter = irep.instructions.find { |i| i.op == 'ENTER' }
        next unless enter

        lines = file_lines[irep.file]
        idx = enter.lineno - 2
        idx -= 1 while idx >= 0 && lines[idx].strip.empty?
        next if idx < 0

        m = Annotations::COMMENT_RE.match(lines[idx])
        next unless m

        arg_elements = m[1].split(',').map do |arg|
          em = ARG_ELEMENT_RE.match(arg.strip)
          em && known_owners.include?(em[1]) ? em[1] : nil
        end
        arg_containers = m[1].split(',').map do |arg|
          cm = /\A(Array|Hash)<([A-Za-z_][\w:]*)>\z/.match(arg.strip)
          cm && known_owners.include?(cm[2]) ? cm[1] : nil
        end

        element = nil
        ret_class = nil
        if m[2]
          tok = m[2]
          if (em = ELEMENT_RE.match(tok))
            element = em[1] if known_owners.include?(em[1])
          elsif !NON_CLASS_RET_TOKENS.include?(tok) && (rm = RET_CLASS_RE.match(tok))
            ret_class = rm[1] if known_owners.include?(rm[1])
          end
        end
        next unless element || ret_class || arg_elements.any?

        result[irep.label] = Annotation.new(element: element, ret_class: ret_class,
                                            arg_elements: arg_elements, arg_containers: arg_containers)
      end
    end

    result
  end
end
