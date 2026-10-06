# frozen_string_literal: true

# LINT_CROSSCHECK (ADR 0368): the closed-world lint (scripts/rpg2k_closed_world_lint.rb) and the
# ClosedWorld analysis scan the same Ruby by different means. A proof is only as trusted as the
# agreement of the two, so a build that refuses to agree fails instead of shipping a closed form.
# BC2CPP_LINT_CROSSCHECK=0 turns the check off.
module LintCrosscheck
  LINT = 'scripts/rpg2k_closed_world_lint.rb'

  # Lint cops whose offences the analysis must also see: a clean cop with a non-empty analysis
  # answer (or the reverse) means one of the two scanners is wrong.
  METHOD_MISSING = 'Dynamic/MethodMissing'

  module_function

  def enabled? = ENV['BC2CPP_LINT_CROSSCHECK'] != '0'

  # Problems that block the build; empty when lint and analysis agree.
  def violations(repo_root, closed_world)
    path = File.join(repo_root, LINT)
    return ["#{LINT} is missing"] unless File.exist?(path)

    require path
    run = closed_world_lint_run(root: repo_root)
    problems = run[:malformed].dup
    run[:new_offences].uniq(&:key).each { |o| problems << "#{o.file}:#{o.line}: #{o.cop}: not in the lint baseline" }
    run[:stale].each_key { |(cop, file, snippet)| problems << "#{file}: #{cop}: stale lint baseline entry (#{snippet})" }
    problems.concat(agreement(run, closed_world))
  end

  def agreement(run, closed_world)
    problems = []
    lint_mm = run[:offences].any? { |o| o.cop == METHOD_MISSING }
    mm = closed_world.method_missing_classes.to_a.sort
    if !lint_mm && !mm.empty?
      problems << "lint finds no #{METHOD_MISSING} offence but the analysis sees method_missing classes: #{mm.join(', ')}"
    end
    problems
  end

  def enforce!(repo_root, closed_world)
    return unless enabled?

    problems = violations(repo_root, closed_world)
    return if problems.empty?

    abort "bc2cpp: lint/analysis cross-check failed (ADR 0368):\n  #{problems.join("\n  ")}"
  end
end
