#!/usr/bin/env ruby
# The setup's state as Ruby values (the port of the setup planners' handoff, docs/notes/driver-body-port.md, item 3).
#
# The setup planners (scripts/nfcxx-setup.rb, nfcxx-setup-args.rb) are Ruby; what the bash body needed was their output as
# shell statements, which it evals. NfcxxSetupState.plan returns the same state as a Hash of plain Ruby values:
# scalars are Strings, arrays (the bash arrays, and pb_flags) are Arrays of Strings. The driver reads the state without
# any shell: the statements are read here, by a reader that accepts exactly the forms the planners print (NAME=VALUE,
# NAME=(WORDS), NAME+=(WORDS), export NAME=VALUE, and the one export whose value expands the gnu_opts array).
# tests/driver-setup-state/run.sh checks every value against what bash computes from the same statements.
#
#   ruby scripts/nfcxx-setup-state.rb -- ARG...    prints the state, one NAME=VALUE line per scalar and NAME[]=WORD per array element
#
# A statement the reader does not know is an error (NfcxxSetupState::Unported), not a guess: the caller falls back to the body.

require "shellwords"
require_relative "nfcxx-setup-args"

module NfcxxSetupState
  module_function

  class Unported < StandardError
  end

  # the planners' statements of one planned state, in the body's order (see NfcxxSetupArgs.planned_state); the three that are
  # not statements of the body (the trace unit's export, the backend environment's) are read the same way
  PLANNED_ORDER = %i[default asan stage rest flags backend_env trace_unit].freeze

  ARRAY = /\A(\w+)(\+?)=\(((?:\\.|[^)\\])*)\)/m
  SCALAR = /\A(\w+)=((?:"(?:\\.|[^"\\])*"|'[^']*'|\\.|[^\s;'"\\])*)/m

  # the words of a statement's array body, as the shell reads them (Shellwords reads the planners' escapes)
  def words(body)
    Shellwords.split(body)
  end

  # the value of a scalar as the shell reads it: a single word; an expansion is not read here (Unported)
  def scalar_value(raw)
    raise Unported, "an expansion in #{raw.inspect}" if raw.include?("$")

    value = Shellwords.split(raw)
    value.size <= 1 ? value.first.to_s : raise(Unported, "more than one word in #{raw.inspect}")
  end

  # applies the statements of one planner's text to STATE (a Hash): NAME=VALUE, NAME=(WORDS), NAME+=(WORDS), export NAME=VALUE
  # and the statement separator ";" (the trace unit's one line holds two statements)
  def apply_text(text, state, env)
    text.each_line do |line|
      rest = line.strip
      until rest.empty?
        rest = rest.sub(/\A[\s;]+/, "")
        break if rest.empty?

        if (m = rest.match(ARRAY))
          name, append, body = m[1], m[2], m[3]
          list = words(body)
          state[name] = append == "+" ? (state.fetch(name, []) + list) : list
          rest = m.post_match
        elsif rest.start_with?("export ")
          rest = rest.delete_prefix("export ")
          # the export whose value expands the gnu_opts array: the front end's default options (see flags_text, rest)
          if (m = rest.match(/\A(EDG_CPFE_DEFAULT_OPTIONS)="\$\{gnu_opts\[\*\]\} \$\{EDG_CPFE_DEFAULT_OPTIONS:-\}"/))
            state[m[1]] = [*state.fetch("gnu_opts", []), env["EDG_CPFE_DEFAULT_OPTIONS"].to_s].join(" ")
            rest = m.post_match
          elsif (m = rest.match(SCALAR))
            (state[:exports] ||= {})[m[1]] = scalar_value(m[2])
            rest = m.post_match
          else
            raise Unported, "an export in #{rest.inspect}"
          end
        elsif (m = rest.match(SCALAR))
          state[m[1]] = scalar_value(m[2])
          rest = m.post_match
        else
          raise Unported, "a statement in #{rest.inspect}"
        end
      end
    end
    state
  end

  # The state of the setup for ARGV (the command line as given), from the planners' own statements. Returns nil when the loop
  # gives no state (the body plans the setup itself), as NfcxxSetupArgs.planned_state does.
  def plan(argv, env = ENV)
    planned = NfcxxSetupArgs.planned_state(argv, env)
    return nil unless planned

    # a planner step is [status, text] (asan, stage, backend_env) or the default and flags texts; a refusal of one of them
    # is the body's to print, so the state is not planned (nil). The rest keeps its statements up to its refusal, below.
    state = {}
    %i[default asan stage rest flags backend_env trace_unit].each do |key|
      part = planned[key]
      next if part.nil?

      if part.is_a?(Array)
        return nil if key != :rest && part.first.to_i != 0

        text = part[1]
      else
        text = part
      end
      apply_text(text.to_s, state, env) unless text.to_s.empty?
    end
    # the rest's status and message (the refusal the body prints before it exits)
    rest = planned[:rest]
    state[:rest_status] = rest ? rest.first.to_i : 0
    state[:rest_message] = rest && rest[2].to_s
    state
  rescue Unported
    nil
  end
end

if $PROGRAM_NAME == __FILE__
  texts = ARGV.first == "--texts"
  ARGV.shift if texts
  argv = ARGV.first == "--" ? ARGV.drop(1) : ARGV
  if texts
    # the planners' statements in the body's order, for bash to evaluate (tests/driver-setup-state/run.sh compares the two).
    # Only a command the state is planned for has them: a refusal's message is the body's to print, not a statement.
    planned = NfcxxSetupArgs.planned_state(argv, ENV)
    abort "nfcxx-setup-state: no state for this command" unless planned && NfcxxSetupState.plan(argv, ENV)
    NfcxxSetupState::PLANNED_ORDER.each do |key|
      part = planned[key]
      $stdout.write((part.is_a?(Array) ? part[1] : part).to_s)
    end
    exit 0
  end
  state = NfcxxSetupState.plan(argv, ENV)
  if state.nil?
    warn "nfcxx-setup-state: no state for this command (the body plans its setup)"
    exit 2
  end
  state.each do |name, value|
    case value
    when Array then value.each { |w| puts "#{name}[]=#{w}" }
    when Hash then value.each { |k, v| puts "#{name}.#{k}=#{v}" }
    else puts "#{name}=#{value}"
    end
  end
end
