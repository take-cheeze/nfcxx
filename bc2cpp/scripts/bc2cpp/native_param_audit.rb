# frozen_string_literal: true

require 'digest'
require_relative '../../tools/bc2cpp/native_direct'

# The audit behind NATIVE_PARAM_UNBOX (docs/adr/0372), as a library so the check and its mutation check share it.
#
# A call site may convert a native entry point's :int/:float/:bool arguments itself, with no tag test and no by-name
# else, only when
#   1. mruby's mrb_get_args still converts "i", "f" and "b" with exactly mrb_as_int / mrb_as_float / mrb_test of the one
#      argument (MRUBY_PINS: a digest of the squashed arms in 3rd/mruby/src/class.c, so a changed arm fails here);
#   2. the binding registered for (owner, name) is `T a; ...; mrb_get_args(M, "<fmt>", &a, ...); return entry(M, self, a, ...)`
#      with nothing before the call but the argument declarations, the letters of <fmt> are the entry's kinds in
#      order, and `entry` is the table's function (or the forwarder the generated block makes to its `_native_body`).
module NativeParamAudit
  ROOT = File.expand_path('../..', __dir__)
  LETTER_KINDS = { 'i' => :int, 'f' => :float, 'b' => :bool, 'o' => :value }.freeze
  CTYPES = { 'i' => 'mrb_int', 'f' => 'mrb_float', 'b' => 'mrb_bool', 'o' => 'mrb_value|V' }.freeze

  # [file, marker] => SHA-256 of the whitespace-squashed text from the marker to its terminator.
  MRUBY_PINS = {
    ['src/class.c', "case 'i':"] => '71bf588b5c4ff65382cd1d527378247d09e5d38e22aeb98a38dbfb1dd7582111',
    ['src/class.c', "case 'f':"] => '809b52126c89f04a2b17a71853fce03c6591d30f9349950450f7feaa13a44cc5',
    ['src/class.c', "case 'b':"] => '0c51fe785818f1d00120c45b61a78ac1732746106c511d4b919ca805715f62b0',
    ['include/mruby.h', '#define mrb_as_int('] => '3cc54149a012497124dec4e2fed2fdfe64090f7da09c00b93cddab00ca80e6a3',
    ['include/mruby.h', '#define mrb_as_float('] => 'd7581de865e0deb8a635368d873a42d701648b1dcfa834ca72e23b9f9e334e1d'
  }.freeze

  module_function

  def squash(text)
    text.gsub(%r{/\*.*?\*/|//[^\n]*}m, ' ').gsub(/\s+/, ' ').strip
  end

  # From `marker` to the `break;` that closes a mrb_get_args arm, or to the end of a one-line #define.
  def mruby_text(source, marker)
    from = source.index(marker) or return nil
    if marker.start_with?('#define')
      source[from...source.index("\n", from)]
    else
      source[from...(source.index(/\bbreak;/, from) or return nil)]
    end
  end

  def pin_digests(mruby_dir)
    MRUBY_PINS.keys.to_h do |file, marker|
      text = mruby_text(File.read(File.join(mruby_dir, file)), marker)
      [[file, marker], text && Digest::SHA256.hexdigest(squash(text))]
    end
  end

  # Index of the `}` closing the `{` at `open` (comments and literals already stripped).
  def close_brace(text, open)
    depth = 0
    (open...text.size).each do |i|
      depth += 1 if text[i] == '{'
      if text[i] == '}'
        depth -= 1
        return i if depth.zero?
      end
    end
    nil
  end

  REGISTRATION = /\bmrb_define_(method|module_function|class_method|singleton_method|private_method)\s*\(\s*M\s*,\s*(\w+)\s*,\s*"((?:[^"\\\n]|\\.)*)"\s*,\s*/.freeze
  FUNCTION = /\bmrb_value\s+(\w+)\s*\(\s*mrb_state\s*\*\s*M\s*,\s*(?:mrb_value|V)\s+self\s*\)\s*\{/.freeze
  LAMBDA = /\A\[[^\]]*\]\s*\(\s*mrb_state\s*\*\s*M\s*,\s*(?:mrb_value|V)\s+self\s*\)\s*(?:->\s*mrb_value\s*)?\{/.freeze

  # Every binding of the RGSS sources: [owner, name, body, label] (owner nil when not attributable).
  def bindings(src_files)
    texts = src_files.to_h { |path| [path, NativeDirect.strip_comments(File.binread(path).force_encoding('UTF-8'))] }
    functions = {}
    texts.each_value do |text|
      text.scan(FUNCTION) do
        open = Regexp.last_match.end(0) - 1
        close = close_brace(text, open) or next
        functions[Regexp.last_match(1)] = text[(open + 1)...close]
      end
    end
    out = []
    texts.each do |path, text|
      owners = NativeDirect.class_variables(text, NativeDirect.sibling_param_owners(path))
      text.scan(REGISTRATION) do |kind, var, name|
        owner = owners[var]
        owner = "#{owner}.singleton" if owner && !%w[method private_method].include?(kind)
        rest = text[Regexp.last_match.end(0)..]
        if (m = rest.match(/\A(\w+)\s*,/))
          out << [owner, name, functions[m[1]], m[1]]
        elsif (m = rest.match(LAMBDA))
          close = close_brace(rest, m.end(0) - 1)
          out << [owner, name, close && rest[m.end(0)...close], 'lambda']
        else
          out << [owner, name, nil, rest[0, 30]]
        end
      end
    end
    out
  end

  # [] when `body` is `decls; mrb_get_args(M, fmt, &vars); return callee(M, self, vars)` with fmt's letters = `kinds`
  # and callee in `callees`; otherwise the reasons it is not.
  def audit_body(body, kinds, callees)
    return ['no body found'] unless body

    fmt_re = /\bmrb_get_args\s*\(\s*M\s*,\s*"([a-z]+)"((?:\s*,\s*&\w+)+)\s*\)\s*;/
    m = body.match(fmt_re) or return ['no mrb_get_args(M, "<letters>", &vars) call']
    reasons = []
    before = body[0...m.begin(0)]
    after = body[m.end(0)..]
    vars = m[2].scan(/&(\w+)/).flatten
    fmt = m[1]
    reasons << "format #{fmt.inspect} is not the kinds #{kinds.inspect}" unless fmt.chars.map { |c| LETTER_KINDS[c] } == kinds
    # Declarations only, with constant initializers: a call before mrb_get_args could be observable.
    declarator = '\w+(?:\s*=\s*[^;,()]+)?'
    decl = "(?:mrb_int|mrb_float|mrb_bool|mrb_value|V)\\s+#{declarator}(?:\\s*,\\s*#{declarator})*\\s*;"
    unless before.match?(/\A(?:\s*#{decl})*\s*\z/)
      reasons << 'something other than the argument declarations precedes mrb_get_args'
    end
    decl_names = before.scan(/#{decl}/).flat_map { |d| d.sub(/\A\w+\s+/, '').chomp(';').split(',').map { |x| x[/\w+/] } }
    reasons << "declarations #{decl_names.inspect} are not the targets #{vars.inspect}" unless decl_names.sort == vars.sort
    tail = after.match(/\A\s*return\s+(?:rgss::)?(\w+)\s*\(\s*M\s*,\s*self((?:\s*,\s*\w+)*)\s*\)\s*;\s*\z/)
    if tail.nil?
      reasons << 'the body does not end in `return callee(M, self, vars...)`'
    else
      reasons << "callee #{tail[1]} is not one of #{callees.inspect}" unless callees.include?(tail[1])
      reasons << "call arguments #{tail[2].scan(/\w+/).inspect} are not the targets #{vars.inspect} in order" unless tail[2].scan(/\w+/) == vars
    end
    reasons
  end
end
