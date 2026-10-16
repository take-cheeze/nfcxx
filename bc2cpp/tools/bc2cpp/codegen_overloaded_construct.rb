# frozen_string_literal: true

require_relative 'native_constructor_sigs'

# OVERLOADED_CONSTRUCT (docs/adr/0468): `Klass.new(args)` for a native class whose constructor overloads
# sig/native/rgss_constructors.rbs declares (and NativeConstructorSigs audits against the C and Ruby source).
#
# The call site picks the overload: first by argument count, then by the argument classes the flow proves (a Fixnum
# proof makes an argument Integer, an exact String flow makes it a String). One overload left, or one whose class
# tests the proofs decide, is called with no test. Otherwise each remaining overload gets its class test, in declared
# order, and the `else` overload (the form the class's initialize takes for any other argument) is the final branch,
# so a wrong argument raises inside its own conversion exactly as the native does. A count no `else` overload takes
# ends in the class's compiled Ruby initialize when it has one (which is then the whole of Class#new's work), and
# otherwise keeps the native construct path of codegen_send.rb.
#
# The receiver is the proven class: a stable constructor class takes no class test; otherwise the class test's miss
# is a guard violation when the receiver register is proven to hold the stable constant, and an unproven receiver
# keeps the older path.
class CodeGen
  def overloaded_construct_code(owner, native, d, recv, argv, irep, proof_site, owner_def, int_site)
    overloads = NativeConstructorSigs.table[owner]
    return nil unless overloads && overloaded_initialize_audited?(owner)

    stable = stable_standard_constructor_class?(owner)
    class_value = stable ? "#{native[:class_fn]}()" : "mrb_class_ptr(#{recv})"
    unless stable
      return nil unless proof_site && new_receiver_constant_proven?(irep, proof_site, 'new', owner, owner_def&.owner)
    end

    branches = overloaded_construct_branches(overloads, owner, argv, int_site, irep, proof_site)
    return nil unless branches

    body = overloaded_construct_body(branches, owner, d, argv, class_value)
    return nil unless body

    note = "  // OVERLOADED_CONSTRUCT :new -> #{owner}, overload chosen by argument count and class " \
           "(sig/native/rgss_constructors.rbs, ADR 0468)\n"
    return "#{note}#{body}" if stable

    "#{note}  if (mrb_class_ptr(#{recv}) == #{native[:class_fn]}()) {\n" \
      "#{body.gsub(/^/, '  ')}" \
      "  } else {\n" \
      "    #{guard_violation_line(d, recv, 'new', argv, 'NEW_IDENTITY')}" \
      "  }\n"
  end

  private

  # The initialize this program gives `owner` is the one the audit read: the audited Ruby definition when the source
  # is Ruby, and no Ruby definition at all (the C one stays live) when it is C.
  def overloaded_initialize_audited?(owner)
    defs = (@registry['initialize'] || []).select { |definition| definition.owner == owner && definition.owner != '<native>' }
    source = NativeConstructorSigs.ruby_source(owner)
    return defs.empty? unless source

    defs.one? && defs.first.irep && @ireps.fetch(defs.first.irep).file.to_s.end_with?("/#{source}")
  end

  # [[test or nil, overload], ...]: the overloads this call may take, in the order their tests run; a nil test is the
  # final branch. nil when a count is taken by no overload and the class has no compiled initialize to end in.
  def overloaded_construct_branches(overloads, owner, argv, int_site, irep, proof_site)
    n = argv.size
    fitting = overloads.select { |o| n.between?(o[:req].size, o[:req].size + o[:opt].size) }
    tested = []
    (fitting.reject { |o| o[:else] } + fitting.select { |o| o[:else] }).each do |o|
      tests = []
      verdicts = argv.each_index.map do |i|
        type = (o[:req] + o[:opt])[i]
        verdict = overloaded_arg_verdict(type, argv, i, int_site, irep, proof_site)
        tests << overloaded_arg_test(type, argv[i]) if verdict.nil?
        verdict
      end
      next if verdicts.include?(false) && !o[:else]

      test = o[:else] || verdicts.all? { |v| v != nil } ? nil : tests.compact.join(' && ')
      test = nil if test && test.empty?
      tested << [test, o]
      break if test.nil?
    end
    return tested if tested.last && tested.last[0].nil?

    compiled = overloads.find { |o| o[:path] == [:compiled] }
    return nil unless compiled

    tested << [nil, compiled.merge(whole: true)]
    # Every branch the compiled initialize: one call, no test.
    tested.all? { |_, o| o[:path] == [:compiled] } ? [[nil, compiled]] : tested
  end

  # true / false when the proofs decide that argument `i` has `type`, nil when only a runtime test can.
  def overloaded_arg_verdict(type, argv, i, int_site, irep, proof_site)
    # A truthiness-only positional takes any object.
    return true if type == :boolish

    int = native_int_arg_proven?(*int_site, argv, i)
    reg = argv[i].to_s[/\Ar(\d+)\z/, 1]
    mask = reg && int_site[3].to_i.zero? ? exact_flow_mask(irep, proof_site, reg) : nil
    str = mask == NumericFlow::STR
    case type
    when :num then return true if int
                   return false if str
    when :str then return true if str
                   return false if int
    end
    nil
  end

  def overloaded_arg_test(type, arg)
    case type
    when :num then "(mrb_integer_p(#{arg}) || mrb_float_p(#{arg}))"
    when :str then "mrb_string_p(#{arg})"
    end
  end

  def overloaded_construct_body(branches, owner, d, argv, class_value)
    codes = branches.map do |test, o|
      code = overloaded_path_code(o, owner, d, argv, class_value)
      return nil unless code

      [test, code]
    end
    return codes.first[1].gsub(/^/, '  ') if codes.size == 1

    out = +''
    codes.each_with_index do |(test, code), i|
      head = if i.zero? then "  if (#{test}) {\n"
             elsif test then "  } else if (#{test}) {\n"
             else "  } else {\n"
             end
      out << head << code.gsub(/^/, '    ')
    end
    out << "  }\n"
  end

  # The statements building the object for overload `o`, ending in r<d>.
  def overloaded_path_code(o, owner, d, argv, class_value)
    if o[:path] == [:compiled]
      # The initialize the call reaches must be the one the audit read, not another definition of the same class.
      source = NativeConstructorSigs.ruby_source(owner)
      definition = source && send(:self_new_initialize_def, owner)
      file = definition&.irep && @ireps.fetch(definition.irep).file.to_s
      return nil unless file && file.end_with?("/#{source}")

      call = send(:self_new_initialize_call, owner, argv)
      return nil unless call

      @direct_alloc_used = true
      return "r#{d} = bc2cpp_direct_alloc(M, #{class_value});\n#{format(call, obj: "r#{d}")}\n"
    end

    _, function, args = o[:path]
    locals = []
    position = 0
    values = args.map do |arg|
      kind, default = arg.split('=', 2)
      next arg unless %w[int float].include?(kind)

      i = position
      position += 1
      next default unless i < argv.size

      local = "bc2cpp_ov#{d}_#{i}"
      locals << "mrb_#{kind} #{local} = mrb_as_#{kind}(M, #{argv[i]});"
      local
    end
    "{\n#{locals.map { |l| "  #{l}\n" }.join}  r#{d} = #{function}(M, #{class_value}#{values.map { |v| ", #{v}" }.join});\n}\n"
  end
end
