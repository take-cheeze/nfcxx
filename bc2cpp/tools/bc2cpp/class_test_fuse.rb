# frozen_string_literal: true

require 'stringio'
require_relative 'compact_output'

# CLASS_TEST_FUSE (CodeGen#class_test_fuse?): bc2cpp_owner_class_N(M) is a bc2cpp_owner_ref that converts to its
# RClass* wherever a parameter asks for one. A variadic parameter asks for nothing, so the struct itself would be
# passed; GCC accepts that silently. The unit is refused instead when any getter call is a variadic argument.
module ClassTestFuse
  GETTER = /bc2cpp_owner_class_\d+\(M\)/
  # The variadic functions mruby's headers and libc declare, with their fixed parameter counts. The unit's own
  # variadic functions and macros are read from its text (variadic_arity).
  LIBRARY_VARIADICS = {
    'mrb_format' => 2, 'mrb_funcall' => 4, 'mrb_funcall_id' => 4, 'mrb_get_args' => 2, 'mrb_name_error' => 3,
    'mrb_no_method_error' => 4, 'mrb_raisef' => 3, 'mrb_warn' => 2, 'mrb_bug' => 2, 'printf' => 1, 'fprintf' => 2,
    'sprintf' => 2, 'snprintf' => 3
  }.freeze
  DECLARED = /\b(\w+)\(([^()]*?)\.\.\.\)/
  OPEN = { 41 => 40, 93 => 91, 125 => 123 }.freeze

  module_function

  def enabled?
    ENV['BC2CPP_CLASS_TEST_FUSE'] != '0'
  end

  # Runs on the whole unit text before the other output passes (registered after them: at_exit is last-in
  # first-out), and stops the run on a violation.
  def capture_stdout
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    at_exit do
      $stdout = original
      next if $!

      text = buffer.string
      bad = vararg_sites(text)
      abort "CLASS_TEST_FUSE: an owner getter is a variadic argument (#{bad.first(3).join('; ')})" unless bad.empty?
      original.write(text)
    end
  end

  def variadic_arity(text)
    found = LIBRARY_VARIADICS.dup
    text.scan(DECLARED) { |name, params| found[name] = [found[name], params.count(',')].compact.min }
    found
  end

  # The getter calls whose innermost enclosing call is variadic at that argument position.
  def vararg_sites(text)
    # Literals and comments blanked byte for byte, so a parenthesis inside one is not read as a call.
    s = text.gsub(CompactOutput::TOKENS) { |token| token.gsub(/[^\n]/, ' ') }.b
    arity = variadic_arity(s)
    out = []
    s.scan(GETTER) do
      at = $~.begin(0)
      callee, index = enclosing_call(s, at)
      fixed = arity[callee]
      out << "#{callee} argument #{index}: #{s.byteslice(at, 40)}" if fixed && index >= fixed
    end
    out
  end

  # [name, argument index] of the innermost call around +at+; a statement, block or subscript yields nil.
  def enclosing_call(s, at)
    depth = 0
    index = 0
    i = at - 1
    while i >= 0
      c = s.getbyte(i)
      if OPEN.key?(c)
        depth += 1
      elsif OPEN.value?(c)
        if depth.zero?
          return [nil, index] unless c == 40

          return [s.byteslice([i - 80, 0].max, [i, 80].min)[/(\w+)\s*\z/, 1], index]
        end
        depth -= 1
      elsif depth.zero? && c == 44
        index += 1
      elsif depth.zero? && c == 59
        return [nil, index]
      end
      i -= 1
    end
    [nil, index]
  end
end
