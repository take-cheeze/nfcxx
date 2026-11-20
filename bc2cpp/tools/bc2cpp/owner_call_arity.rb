# frozen_string_literal: true

require 'stringio'

# OWNER_CALL_ARITY: an owner call `bc2cpp_owner_call(M, recv, <head>, blk, argc, args..., [caller_self])` with no
# block and at most two arguments, or a block and none, calls a fixed-arity entry instead (bc2cpp_owner_call0/1/2,
# bc2cpp_owner_call_b0, symbol_cache.rb) that drops blk and argc: the variadic form passes them, and its own
# arguments, on the stack on a 4-register-argument target. A level 2 site keeps its trailing caller self, which
# selects the entry's overload. The site's text is otherwise unchanged, `/* CLOSED_WORLD owner-call: name */` included.
#
# As OWNER_SET_SHARE, only a real gem build rewrites (a fixture keeps the general form); BC2CPP_OWNER_CALL_ARITY=1 or
# =0 forces either.
module OwnerCallArity
  START = /\bbc2cpp_owner_call\(/
  # The arguments before blk: M, recv, then the method index, the level and the owner set, or the one descriptor
  # those make (OWNER_CALL_DESC: BC2CPP_OWNERS(I, L, ...) / BC2CPP_SHARED(...)).
  DESC = /\ABC2CPP_(?:OWNERS(?:_D)?|SHARED)\(/
  NIL = 'mrb_nil_value()'

  module_function

  # The top-level comma-separated arguments of the call whose `(` is at +open+, and the index of its `)`; nil when
  # the line ends first.
  def args_at(code, open)
    depth = 0
    args = []
    from = open + 1
    i = from
    while i < code.size
      case code[i]
      when '"'
        i += 1
        i += code[i] == '\\' ? 2 : 1 while i < code.size && code[i] != '"'
      when '(', '[', '{' then depth += 1
      when ')', ']', '}'
        if depth.zero?
          args << code[from...i].strip
          return [args, i]
        end
        depth -= 1
      when ','
        if depth.zero?
          args << code[from...i].strip
          from = i + 1
        end
      when "\n" then return nil
      end
      i += 1
    end
    nil
  end

  # The fixed-arity spelling of the call +args+, or nil when the site keeps the general form.
  def fixed(args)
    head_size = args[2].to_s.match?(DESC) ? 3 : 5
    return nil unless args.size >= head_size + 2 && args[0] == 'M' && args[head_size + 1].match?(/\A\d+\z/)

    blk = args[head_size]
    argc = args[head_size + 1].to_i
    rest = args[(head_size + 2)..]
    return nil unless rest.size == argc || rest.size == argc + 1

    head = args[0, head_size]
    if blk == NIL && argc <= 2
      "bc2cpp_owner_call#{argc}(#{(head + rest).join(', ')})"
    elsif blk != NIL && argc.zero?
      "bc2cpp_owner_call_b0(#{(head + [blk] + rest).join(', ')})"
    end
  end

  def rewrite(code)
    out = +''
    pos = 0
    while (m = START.match(code, pos))
      open = m.end(0) - 1
      args, close = args_at(code, open)
      call = args && fixed(args)
      if call
        out << code[pos...m.begin(0)] << call
        pos = close + 1
      else
        out << code[pos...m.end(0)]
        pos = m.end(0)
      end
    end
    out << code[pos..]
  end

  # +real+: the run is a real gem build.
  def enabled?(real)
    case ENV['BC2CPP_OWNER_CALL_ARITY']
    when '1' then true
    when '0' then false
    else real
    end
  end

  def capture_stdout
    original = $stdout
    buffer = StringIO.new
    $stdout = buffer
    at_exit do
      $stdout = original
      original.write(rewrite(buffer.string)) unless $!
    end
  end
end
