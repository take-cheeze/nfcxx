# frozen_string_literal: true

# PURE_CONST_EVAL's evaluation step (pure_eval.rb), kept out of the baked compiler sources: pure_eval.rb loads this file
# only under CRuby, with `load` rather than `require_relative`, so a self-compiled bc2cpp never carries it. It runs a
# body's statements in a fresh Module with module_eval: mruby has no string eval (module_eval raises), and the fresh
# Module would escape a self-compiled bc2cpp's closed world (class_factory_escape).
module PureEvalHost
  module_function

  # Runs `source` in a fresh Module and returns [value of constant `name`], or nil when it raises.
  def evaluate(source, name, magic)
    text = +''
    text << "# frozen_string_literal: true\n" if magic
    text << source
    verbose = $VERBOSE
    $VERBOSE = nil
    mod = Module.new
    mod.module_eval(text, '(pure_eval)', 1)
    [mod.const_get(name, false)]
  rescue StandardError, ScriptError
    nil
  ensure
    $VERBOSE = verbose
  end
end
