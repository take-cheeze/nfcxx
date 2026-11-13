# AArch64 (Linux, AAPCS64) long double thunks (docs/notes/pathb-longdouble.md, "Linux aarch64").
#
# A parameter list is a string of class letters, one per parameter, in the C view (the AAPCS64 of the C side):
#   i  an integer, pointer, reference or memory-class aggregate (passed by address): one general register
#   d  double            f  float
#   L  long double, or a struct whose only member is a long double: one SIMD&FP register (quad), or 16 bytes of stack
#   C  _Complex long double: a homogeneous pair of quads (q(n), q(n+1)), or 32 bytes of stack
#   T  __int128: an even general register pair, or 16 bytes of stack
# The IR (be/nfcxx_ir.c) describes the same parameters as Path B passes them to QBE on arm64, the internal view:
#   i, d, f as above; T (__int128, two integer leaves) is a register pair starting at an even register, or 16 bytes of
#   stack; L and C are memory-class objects (__nfcxx_ld, the 32-byte complex): QBE passes their address, a pointer to a
#   copy the caller made, in one general register or as an 8-byte stack pointer. Written P here.
# A result is R: v (a value returned unchanged in x0 or d0, or no value), L (long double: q0) or C (q0 and q1).
# A routine with an L or C parameter, or an L or C result, is reached through these thunks: its C-convention symbol is
# the entry thunk, and the internal definition is __nfcxx_ldr_F with one more trailing pointer for an L or C result.
#
# The thunks (generated only for the signatures that need them, from the x87 forms of the IR, see x87_thunks_asm in
# scripts/pathb-x87-thunks.rb):
#   entry F:  C calls F; the thunk calls __nfcxx_ldr_F with the internal view and returns q0 (and q1).
#   call F:   Path B calls __nfcxx_x87c_F with the internal view; the thunk calls F with the C view and stores q0 (and
#             q1) at the result pointer.
#   icall:    the same with the C-convention callee, a function pointer, after the result pointer (in x16 for the call).
#   callv:    the call thunk of one variadic call shape. AAPCS64 on Linux gives the variadic arguments the registers of
#             the named ones (no %al), so it is the call thunk with the arguments of that call.
# Every thunk first saves x0-x7 and q0-q7 in its frame, so the moves read only memory and cannot overwrite a register
# they still need. The scratch registers are x9 (a pointer to a copy), x10 and x11 (copies) and x16 (the callee).

module A64Thunks
  module_function

  def size_of(letter)
    { "i" => 8, "S" => 8, "P" => 8, "d" => 8, "f" => 4, "L" => 16, "T" => 16, "U" => 16, "C" => 32 }.fetch(letter)
  end

  def up(x, a) = (x + a - 1) / a * a

  # AAPCS64 (C.1 to C.12) locations of the C view. Returns the locations and the size of the stack arguments.
  def alloc_c(letters)
    ngrn = 0
    nsrn = 0
    nsaa = 0
    locs = letters.map do |l|
      case l
      when "i", "S"
        if ngrn < 8
          ngrn += 1
          { k: :x, n: ngrn - 1 }
        else
          nsaa = up(nsaa, 8) + 8
          { k: :stk, off: nsaa - 8, size: 8 }
        end
      when "d", "f"
        if nsrn < 8
          nsrn += 1
          { k: :v, n: nsrn - 1, size: size_of(l) }
        else
          nsaa = up(nsaa, 8) + 8
          { k: :stk, off: nsaa - 8, size: size_of(l) }
        end
      when "L"
        if nsrn < 8
          nsrn += 1
          { k: :q, n: nsrn - 1 }
        else
          nsaa = up(nsaa, 16) + 16
          { k: :stk, off: nsaa - 16, size: 16 }
        end
      when "T"
        ngrn += 1 if ngrn.odd?
        if ngrn <= 6
          ngrn += 2
          { k: :x2, n: ngrn - 2 }
        else
          ngrn = 8
          nsaa = up(nsaa, 16) + 16
          { k: :stk, off: nsaa - 16, size: 16 }
        end
      when "U"
        # an integer aggregate of 9 to 16 bytes and alignment 8: two consecutive registers, no even-register rule
        if ngrn <= 6
          ngrn += 2
          { k: :x2, n: ngrn - 2 }
        else
          ngrn = 8
          nsaa = up(nsaa, 8) + 16
          { k: :stk, off: nsaa - 16, size: 16 }
        end
      when "C"
        if nsrn <= 6
          nsrn += 2
          { k: :q2, n: nsrn - 2 }
        else
          nsrn = 8
          nsaa = up(nsaa, 16) + 32
          { k: :stk, off: nsaa - 32, size: 32 }
        end
      else
        raise ArgumentError, "a64 thunk: unknown class #{l.inspect}"
      end
    end
    [locs, up(nsaa, 16)]
  end

  # The internal (QBE arm64) locations of the internal view: a scalar takes the next free register of its kind, else an
  # 8-byte stack slot; a 16-byte aggregate takes an even pair (one register is skipped when the next one is odd), else
  # the 16-byte stack slot, and then no general register is left for the following integers (QBE's argsclass).
  def alloc_i(letters)
    ngp = 8
    nfp = 8
    gpi = 0
    fpi = 0
    stk = 0
    locs = letters.map do |l|
      case l
      when "i", "P", "S"
        if ngp > 0
          ngp -= 1
          gpi += 1
          { k: :x, n: gpi - 1 }
        else
          stk = up(stk, 8) + 8
          { k: :stk, off: stk - 8, size: 8 }
        end
      when "d", "f"
        if nfp > 0
          nfp -= 1
          fpi += 1
          { k: :v, n: fpi - 1, size: size_of(l) }
        else
          stk = up(stk, 8) + 8
          { k: :stk, off: stk - 8, size: size_of(l) }
        end
      when "U"
        # QBE's aggregate of 9 to 16 bytes and alignment 8: a pair of registers, or the stack (argsclass)
        if ngp >= 2
          ngp -= 2
          gpi += 2
          { k: :x2, n: gpi - 2 }
        else
          ngp = 0
          stk = up(stk, 8) + 16
          { k: :stk, off: stk - 16, size: 16 }
        end
      when "T"
        if gpi.odd? && ngp > 0
          gpi += 1
          ngp -= 1
        end
        if ngp >= 2
          ngp -= 2
          gpi += 2
          { k: :x2, n: gpi - 2 }
        else
          ngp = 0
          stk = up(stk, 16) + 16
          { k: :stk, off: stk - 16, size: 16 }
        end
      else
        raise ArgumentError, "a64 thunk: unknown internal class #{l.inspect}"
      end
    end
    [locs, up(stk, 16)]
  end

  # The internal view of a C-view class string: a long double or a complex is a pointer to a copy.
  def internal_letters(cls)
    cls.chars.map { |l| l == "L" || l == "C" ? "P" : l }
  end

  def by_pointer?(letter) = letter == "L" || letter == "C"

  def res_has_slot?(res) = res == "L" || res == "C"

  # Frame, from sp up: the outgoing stack arguments, the result buffer (32 bytes), the complex copies (32 bytes each),
  # the result pointer of a call (16 bytes), the saved x0-x7 (64 bytes) and q0-q7 (128 bytes). The frame pointer and the
  # link register are pushed above it, so the incoming stack arguments start at size + 16.
  Frame = Struct.new(:size, :res, :tmp, :dsts, :sv, :svq, :in_stack)

  def frame(out_stack, ntemps)
    res = up(out_stack, 16)
    tmp = res + 32
    dsts = tmp + 32 * ntemps
    sv = dsts + 16
    svq = sv + 64
    size = up(svq + 128, 16)
    raise "a64 thunk: frame of #{size} bytes" if size > 4000
    Frame.new(size, res, tmp, dsts, sv, svq, size + 16)
  end

  # The memory of a saved or incoming location as [base, offset, size]: the save area for a register, the caller's
  # stack for a stack location.
  def saved_mem(fr, loc)
    case loc[:k]
    when :x then ["sp", fr.sv + 8 * loc[:n], 8]
    when :x2 then ["sp", fr.sv + 8 * loc[:n], 16]
    when :v then ["sp", fr.svq + 16 * loc[:n], loc[:size]]
    when :q then ["sp", fr.svq + 16 * loc[:n], 16]
    when :q2 then ["sp", fr.svq + 16 * loc[:n], 32]
    when :stk then ["sp", fr.in_stack + loc[:off], loc[:size]]
    else raise "a64 thunk: no memory for #{loc.inspect}"
    end
  end

  # The operand of a pair access (ldp/stp, whose immediate is at most 504 for x and 1008 for q registers): the address
  # is computed into scratch when the offset is out of the immediate range.
  def pair_mem(out, base, off, scratch)
    return [base, off] if off >= 0 && off <= 480 && off % 16 == 0
    out << "\tadd #{scratch}, #{base}, ##{off}"
    [scratch, 0]
  end

  # Copy size bytes from [sb, so] to [dst_base, dst_off] through x10 and x11 (x12 and x13 for large offsets).
  def copy(out, sb, so, dst_base, dst_off, size)
    case size
    when 4
      out << "\tldr w10, [#{sb}, ##{so}]"
      out << "\tstr w10, [#{dst_base}, ##{dst_off}]"
    when 8
      out << "\tldr x10, [#{sb}, ##{so}]"
      out << "\tstr x10, [#{dst_base}, ##{dst_off}]"
    when 16
      s = pair_mem(out, sb, so, "x12")
      d = pair_mem(out, dst_base, dst_off, "x13")
      out << "\tldp x10, x11, [#{s[0]}, ##{s[1]}]"
      out << "\tstp x10, x11, [#{d[0]}, ##{d[1]}]"
    when 32
      copy(out, sb, so, dst_base, dst_off, 16)
      copy(out, sb, so + 16, dst_base, dst_off + 16, 16)
    else
      raise "a64 thunk: copy of #{size} bytes"
    end
  end

  def prologue(out, fr)
    out << "\tstp x29, x30, [sp, #-16]!"
    out << "\tmov x29, sp"
    out << "\tsub sp, sp, ##{fr.size}"
    (0..7).step(2) do |n|
      b, o = pair_mem(out, "sp", fr.sv + 8 * n, "x12")
      out << "\tstp x#{n}, x#{n + 1}, [#{b}, ##{o}]"
    end
    (0..7).step(2) do |n|
      b, o = pair_mem(out, "sp", fr.svq + 16 * n, "x12")
      out << "\tstp q#{n}, q#{n + 1}, [#{b}, ##{o}]"
    end
  end

  def epilogue(out, fr)
    out << "\tadd sp, sp, ##{fr.size}"
    out << "\tldp x29, x30, [sp], #16"
    out << "\tret"
  end

  # One parameter: the value of the incoming location src goes to the outgoing location dst (the source is a pointer to a
  # 32-byte object when src_ptr: it is loaded into x9 first). A destination P is a pointer to a copy: the copy is made
  # in the frame's temporary number temp, and dst holds the address of it.
  def move(out, fr, src, src_ptr, dst, dst_letter, temp, size: 16)
    if src_ptr
      b, o, = saved_mem(fr, src)
      out << "\tldr x9, [#{b}, ##{o}]"
      sb = "x9"
      so = 0
    else
      sb, so, = saved_mem(fr, src)
    end
    if dst_letter == "P"
      tmp_off = fr.tmp + 32 * temp
      copy(out, sb, so, "sp", tmp_off, size)
      if dst[:k] == :x
        out << "\tadd x#{dst[:n]}, sp, ##{tmp_off}"
      else
        out << "\tadd x10, sp, ##{tmp_off}"
        out << "\tstr x10, [sp, ##{dst[:off]}]"
      end
      return
    end
    case dst[:k]
    when :x then out << "\tldr x#{dst[:n]}, [#{sb}, ##{so}]"
    when :x2
      b, o = pair_mem(out, sb, so, "x12")
      out << "\tldp x#{dst[:n]}, x#{dst[:n] + 1}, [#{b}, ##{o}]"
    when :v then out << "\tldr #{dst[:size] == 4 ? "s" : "d"}#{dst[:n]}, [#{sb}, ##{so}]"
    when :q then out << "\tldr q#{dst[:n]}, [#{sb}, ##{so}]"
    when :q2
      b, o = pair_mem(out, sb, so, "x12")
      out << "\tldp q#{dst[:n]}, q#{dst[:n] + 1}, [#{b}, ##{o}]"
    when :stk then copy(out, sb, so, "sp", dst[:off], dst[:size])
    else raise "a64 thunk: no destination for #{dst.inspect}"
    end
  end

  # The entry thunk: C calls name with the C view of the parameters, and the internal call takes the internal view.
  def entry(name, linkage, cls, res)
    cl = cls.chars
    c_locs, = alloc_c(cl)
    il = internal_letters(cls)
    il += ["i"] if res_has_slot?(res)
    i_locs, i_stack = alloc_i(il)
    fr = frame(i_stack, cl.count { |l| by_pointer?(l) })
    out = [".text", ".balign 16"]
    out << ".globl #{name}" if linkage == "global"
    out << ".weak #{name}" if linkage == "weak"
    out << ".type #{name}, @function"
    out << "#{name}:"
    prologue(out, fr)
    temp = 0
    cl.each_with_index do |l, j|
      if by_pointer?(l)
        # a copy in the frame (the C value is in a register or the caller's stack): its address is the argument
        move(out, fr, c_locs[j], false, i_locs[j], "P", temp, size: size_of(l))
        temp += 1
      else
        move(out, fr, c_locs[j], false, i_locs[j], l, 0)
      end
    end
    if res_has_slot?(res)
      rl = i_locs[cl.size]
      if rl[:k] == :x
        out << "\tadd x#{rl[:n]}, sp, ##{fr.res}"
      else
        out << "\tadd x10, sp, ##{fr.res}"
        out << "\tstr x10, [sp, ##{rl[:off]}]"
      end
    end
    out << "\tbl __nfcxx_ldr_#{name}"
    if res == "L"
      out << "\tldr q0, [sp, ##{fr.res}]"
    elsif res == "C"
      out << "\tldr q0, [sp, ##{fr.res}]"
      out << "\tldr q1, [sp, ##{fr.res + 16}]"
    end
    epilogue(out, fr)
    out << ".size #{name}, .-#{name}"
    out.join("\n") + "\n"
  end

  # The call thunk sym and its variants: Path B calls sym with the internal view (the result pointer after the parameters
  # for L and C, the callee after that for icall); the thunk calls target with the C view (icall: the callee).
  def call(sym, target, cls, res, icall: false)
    cl = cls.chars
    il = internal_letters(cls)
    il += ["i"] if res_has_slot?(res)
    il += ["i"] if icall
    i_locs, i_stack = alloc_i(il)
    c_locs, c_stack = alloc_c(cl)
    fr = frame(c_stack, 0)
    out = [".text", ".weak #{sym}", ".hidden #{sym}", ".type #{sym}, @function", "#{sym}:"]
    prologue(out, fr)
    if res_has_slot?(res)
      b, o, = saved_mem(fr, i_locs[cl.size])
      out << "\tldr x9, [#{b}, ##{o}]"
      out << "\tstr x9, [sp, ##{fr.dsts}]"
    end
    cl.each_with_index do |l, j|
      # a long double or complex argument arrives as a pointer to its copy: the value is read through it
      move(out, fr, i_locs[j], by_pointer?(l), c_locs[j], l, 0)
    end
    if icall
      b, o, = saved_mem(fr, i_locs[il.size - 1])
      out << "\tldr x16, [#{b}, ##{o}]"
      out << "\tblr x16"
    else
      out << "\tbl #{target}"
    end
    case res
    when "L"
      out << "\tldr x9, [sp, ##{fr.dsts}]"
      out << "\tstr q0, [x9]"
    when "C"
      out << "\tldr x9, [sp, ##{fr.dsts}]"
      out << "\tstr q0, [x9]"
      out << "\tstr q1, [x9, #16]"
    end
    epilogue(out, fr)
    out << ".size #{sym}, .-#{sym}"
    out.join("\n") + "\n"
  end
end
