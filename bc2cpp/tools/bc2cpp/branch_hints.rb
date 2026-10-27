# frozen_string_literal: true

# BRANCH_HINTS: static prediction for the compiler's own guards -- a tag, class or bounds test whose failure means a
# proof did not hold or the operand has a rare type. Never for a branch the program itself takes (a user `if`, a loop
# test, the value a comparison computes). BC2CPP_BRANCH_HINTS=0 emits the guards bare. See docs/bc2cpp-branch-hints.md.
module BranchHints
  module_function

  def on?
    ENV['BC2CPP_BRANCH_HINTS'] != '0'
  end

  # mruby's common.h macros, valid C and C++.
  def likely(cond)
    on? ? "mrb_likely(#{cond})" : cond
  end

  def unlikely(cond)
    on? ? "mrb_unlikely(#{cond})" : cond
  end

  # Statement prefix for a fallback arm that no condition can carry: the final else of a guard chain, whose earlier
  # arms are each data-dependent. A cold label (BC2CPP_COLD_ARM, defined in PRELUDE) moves the arm out of line.
  def cold_arm
    on? ? 'BC2CPP_COLD_ARM ' : ''
  end

  # GCC's label attributes; clang ignores a cold label with a warning, so it gets nothing. __COUNTER__ keeps the label
  # names unique within a function.
  PRELUDE = <<~CPP
    #ifndef BC2CPP_COLD_ARM
    #if defined(__GNUC__) && !defined(__clang__)
    #define BC2CPP_COLD_ARM_(n) bc2cpp_cold_##n: __attribute__((cold, unused));
    #define BC2CPP_COLD_ARM_N(n) BC2CPP_COLD_ARM_(n)
    #define BC2CPP_COLD_ARM BC2CPP_COLD_ARM_N(__COUNTER__)
    #else
    #define BC2CPP_COLD_ARM
    #endif
    #endif
  CPP

  def prelude
    on? ? PRELUDE : ''
  end

  # A template written with hints, for the file-scope helpers kept as constants: unwraps each mrb_likely(...) /
  # mrb_unlikely(...) and drops BC2CPP_COLD_ARM when hints are off.
  def text(template)
    return template if on?

    out = template.gsub('BC2CPP_COLD_ARM ', '')
    while (start = out.index(/mrb_(?:un)?likely\(/))
      open = out.index('(', start)
      depth = 0
      close = (open...out.size).find do |i|
        depth += 1 if out[i] == '('
        depth -= 1 if out[i] == ')'
        depth.zero?
      end
      out = out[0...start] + out[(open + 1)...close] + out[(close + 1)..]
    end
    out
  end
end
