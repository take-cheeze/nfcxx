# x87 ABI thunks for long double (docs/notes/pathb-longdouble.md), shared by scripts/pathb-ssa-build.
#
# The generators x87_copy_args, x87_call_thunk, x87_icall_thunk and x87_entry_thunk are copied unchanged from
# scripts/pathb-qbe-emit.rb (its lines 2717-2835). x87_thunks_asm below chooses the thunks the IL needs, as the
# existing emitter does with its markers (emit_x87_thunks).

require_relative "pathb-ssa-qbe"
require_relative "pathb-a64-thunks"

# The AArch64 forms: (x87-thunk call|callv|icall "NAME" "CLASSES" RES) and (x87-thunk entry "F" LINKAGE "CLASSES" RES),
# where the CLASSES string is a quoted token (scripts/pathb-a64-thunks.rb). The x86 forms have integers there.
def x87_a64_form?(f)
  case head(f).to_s == "x87-thunk" ? f[1].to_s : nil
  when "call", "callv", "icall" then f[3].is_a?(Str)
  when "entry" then f[4].is_a?(Str)
  else false
  end
end

# ---- long double: the x87 thunks (docs/notes/pathb-longdouble.md)
#
# A function returning long double returns it in st(0), which QBE cannot touch. Path B defines such a function F as
# __nfcxx_ldr_F with a trailing pointer parameter for the result (an ordinary void function). Two thunks in assembly
# connect that to the C convention. They are described by the IR forms
#   (x87-thunk entry "F" LINKAGE INTS STACK)   F itself: calls __nfcxx_ldr_F with a stack buffer, loads st(0)
#   (x87-thunk call "F" INTS STACK)            __nfcxx_x87c_F(args..., dst): calls F, stores st(0) at dst
# and entryc / callc for a _Complex long double result (COMPLEX_X87: real part in st(0), imaginary part in st(1); the
# 32-byte object holds the real part at offset 0 and the imaginary part at 16).
# where INTS is the number of integer registers the parameters of F use and STACK the bytes of its stack arguments.
# The emitter leaves one marker comment per live thunk in the QBE IL; append_weak turns them into assembly (QBE has no
# way to write it). The extra pointer is the next integer register after the parameters, or the stack word after the
# stack arguments when all six are used; the thunk copies the stack arguments to its own frame, which keeps the
# 16-byte alignment of long doubles passed in memory, and uses only r11 and the register of the extra pointer.
X87_MARK = "# pathb-x87 "
X87_REGS = ["rdi", "rsi", "rdx", "rcx", "r8", "r9"]

def x87_copy_args(stack, frame)
  out = []
  i = 0
  while i < stack
    out << "\tmovq #{frame + 8 + i}(%rsp), %r11"
    out << "\tmovq %r11, #{i}(%rsp)"
    i += 8
  end
  out
end

# vsse: the call of a variadic F (the "callv" thunk, __nfcxx_x87cv_F_I<ints>S<stack>V<vsse>): %al = the number of vector
# registers the arguments use, which a variadic callee reads. The call site knows all its arguments, so INTS and STACK
# count the variadic ones too.
def x87_call_thunk(name, ints, stack, complex = false, vsse = nil)
  r = (stack + 15) / 16 * 16
  frame = r + 24
  sym = vsse.nil? ? "__nfcxx_x87c_" + name : "__nfcxx_x87cv_" + name + "_I" + ints.to_s + "S" + stack.to_s + "V" + vsse.to_s
  out = [".text", ".weak #{sym}", ".hidden #{sym}", ".type #{sym}, @function", sym + ":", "\tsubq $#{frame}, %rsp"]
  if ints < 6
    out << "\tmovq %#{X87_REGS[ints]}, #{r}(%rsp)"
  else
    out << "\tmovq #{frame + 8 + stack}(%rsp), %r11"
    out << "\tmovq %r11, #{r}(%rsp)"
  end
  out.concat(x87_copy_args(stack, frame))
  out << "\tmovl $#{vsse}, %eax" unless vsse.nil?
  out << "\tcall #{name}@PLT"
  out << "\tmovq #{r}(%rsp), %rdi"
  out << "\tfstpt (%rdi)"
  out << "\tmovw $0, 10(%rdi)"
  out << "\tmovl $0, 12(%rdi)"
  if complex
    out << "\tfstpt 16(%rdi)"
    out << "\tmovw $0, 26(%rdi)"
    out << "\tmovl $0, 28(%rdi)"
  end
  out << "\taddq $#{frame}, %rsp"
  out << "\tret"
  out << ".size #{sym}, .-#{sym}"
  out.join("\n") + "\n"
end

def x87_icall_thunk(key, ints, stack, complex = false)
  r = (stack + 15) / 16 * 16
  frame = r + 24
  sym = (complex ? "__nfcxx_x87ic_" : "__nfcxx_x87i_") + key
  out = [".text", ".weak #{sym}", ".hidden #{sym}", ".type #{sym}, @function", sym + ":", "\tsubq $#{frame}, %rsp"]
  # the result pointer: the integer register after the parameters, or the stack word after the stack arguments
  if ints < 6
    out << "\tmovq %#{X87_REGS[ints]}, #{r}(%rsp)"
  else
    out << "\tmovq #{frame + 8 + stack}(%rsp), %r11"
    out << "\tmovq %r11, #{r}(%rsp)"
  end
  # the callee: the register after the result pointer, or the stack word after the result pointer
  if ints < 5
    out << "\tmovq %#{X87_REGS[ints + 1]}, #{r + 8}(%rsp)"
  else
    word = ints == 5 ? stack : stack + 8
    out << "\tmovq #{frame + 8 + word}(%rsp), %r11"
    out << "\tmovq %r11, #{r + 8}(%rsp)"
  end
  out.concat(x87_copy_args(stack, frame))
  out << "\tmovq #{r + 8}(%rsp), %r11"
  out << "\tcall *%r11"
  out << "\tmovq #{r}(%rsp), %rdi"
  out << "\tfstpt (%rdi)"
  out << "\tmovw $0, 10(%rdi)"
  out << "\tmovl $0, 12(%rdi)"
  if complex
    out << "\tfstpt 16(%rdi)"
    out << "\tmovw $0, 26(%rdi)"
    out << "\tmovl $0, 28(%rdi)"
  end
  out << "\taddq $#{frame}, %rsp"
  out << "\tret"
  out << ".size #{sym}, .-#{sym}"
  out.join("\n") + "\n"
end

def x87_entry_thunk(name, linkage, ints, stack, complex = false)
  m = stack + (ints == 6 ? 8 : 0)
  mr = (m + 15) / 16 * 16
  frame = mr + (complex ? 40 : 24)
  global = linkage == "local" ? [] : [(linkage == "weak" ? ".weak #{name}" : ".globl #{name}")]
  # Aligned as QBE aligns functions: the entry is the function's address, and the Itanium pointer-to-member ABI reads
  # an odd one as a virtual function's vtable offset.
  out = [".text", ".balign 16", *global, ".type #{name}, @function", name + ":",
         "\tsubq $#{frame}, %rsp"]
  out.concat(x87_copy_args(stack, frame))
  if ints < 6
    out << "\tleaq #{mr}(%rsp), %#{X87_REGS[ints]}"
  else
    out << "\tleaq #{mr}(%rsp), %r11"
    out << "\tmovq %r11, #{stack}(%rsp)"
  end
  out << "\tcall __nfcxx_ldr_#{name}@PLT"
  out << "\tfldt #{mr + 16}(%rsp)" if complex
  out << "\tfldt #{mr}(%rsp)"
  out << "\taddq $#{frame}, %rsp"
  out << "\tret"
  out << ".size #{name}, .-#{name}"
  out.join("\n") + "\n"
end


# The assembly of the x87 thunks that the module's IL needs. forms are the module's (x87-thunk ...) forms; il is the
# module's QBE IL text. A call thunk is needed when the IL calls __nfcxx_x87c_F (or __nfcxx_x87i_KEY / __nfcxx_x87ic_KEY
# for an icall), and an entry thunk when the IL defines __nfcxx_ldr_F. The symbols are Qbe.symbol-escaped as the IL
# has them.
# The text of a name in an IR form (a string token, quotes removed).
def sname(x)
  (x.respond_to?(:raw) ? x.raw : x.to_s).delete('"')
end

# The target the thunks are for. PATHB_X87_TARGET (x86_64 or arm64) overrides the host, for checks on another machine.
def x87_target_name
  ENV.fetch("PATHB_X87_TARGET") { RbConfig::CONFIG["host_cpu"] }
end

def x87_target_x86_64?
  %w[x86_64 amd64].include?(x87_target_name)
end

# The AArch64 Linux thunks (scripts/pathb-a64-thunks.rb, AAPCS64). Darwin's arm64 ABI differs (variadic arguments on
# the stack), so only a Linux host takes them.
def x87_a64_target?
  %w[aarch64 arm64].include?(x87_target_name) && RbConfig::CONFIG["host_os"].include?("linux")
end

def x87_thunks_asm(forms, il)
  out = []
  # The function header lines of the IL, found once: an entry thunk asks whether one defines __nfcxx_ldr_F, and matching
  # a regex against the whole IL for each form is quadratic in the module.
  headers = nil
  forms.each do |f|
    kind = f[1].to_s
    name = Qbe.symbol(sname(f[2]))
    if x87_a64_form?(f)
      # AArch64 forms carry the class string of the parameters (scripts/pathb-a64-thunks.rb); x86 targets skip them
      next unless x87_a64_target?
      case kind
      when "call", "callv", "icall"
        cls = sname(f[3])
        res = f[4].to_s
        # the names: __nfcxx_x87c_F; __nfcxx_x87cv_F_A<classes>R<result> for a variadic call shape; __nfcxx_x87i_KEY (KEY
        # is A<classes>R<result>, written by the IR)
        sym = case kind
              when "call" then "__nfcxx_x87c_" + sname(f[2])
              when "callv" then "__nfcxx_x87cv_" + sname(f[2]) + "_A" + cls + "R" + res
              else "__nfcxx_x87i_" + sname(f[2])
              end
        sym = Qbe.symbol(sym)
        # a call with a hidden result goes through the thunk sym.nfcxxx8 (pathb-ssa-build's hidden_result_asm), which branches here
        used = il.include?("$#{sym}(") || il.include?("$#{sym}.nfcxxx8(")
        if kind == "icall"
          out << A64Thunks.call(sym, nil, cls, res, icall: true) if used
        else
          out << A64Thunks.call(sym, name, cls, res) if used
        end
      when "entry"
        linkage = f[3].to_s
        cls = sname(f[4])
        res = f[5].to_s
        headers ||= il.scan(/^(?:export )?function [^\n]*/).join("\n")
        defined = headers.include?("$#{Qbe.symbol("__nfcxx_ldr_" + sname(f[2]))}(")
        out << A64Thunks.entry(name, linkage, cls, res) if defined
      end
      next
    end
    case kind
    when "call", "callc"
      sym = Qbe.symbol("__nfcxx_x87c_" + sname(f[2]))
      out << x87_call_thunk(name, Qbe.int_lit(f[3]), Qbe.int_lit(f[4]), kind == "callc") if il.include?("$#{sym}(")
    when "callv", "callvc"
      ints = Qbe.int_lit(f[3])
      stack = Qbe.int_lit(f[4])
      vsse = Qbe.int_lit(f[5])
      sym = Qbe.symbol("__nfcxx_x87cv_" + sname(f[2]) + "_I" + ints.to_s + "S" + stack.to_s + "V" + vsse.to_s)
      out << x87_call_thunk(name, ints, stack, kind == "callvc", vsse) if il.include?("$#{sym}(")
    when "icall", "icallc"
      key = Qbe.symbol(sname(f[2]))
      sym = Qbe.symbol((kind == "icallc" ? "__nfcxx_x87ic_" : "__nfcxx_x87i_") + sname(f[2]))
      out << x87_icall_thunk(key, Qbe.int_lit(f[3]), Qbe.int_lit(f[4]), kind == "icallc") if il.include?("$#{sym}(")
    when "entry", "entryc"
      headers ||= il.scan(/^(?:export )?function [^\n]*/).join("\n")
      defined = headers.include?("$#{Qbe.symbol("__nfcxx_ldr_" + sname(f[2]))}(")
      out << x87_entry_thunk(name, f[3].to_s, Qbe.int_lit(f[4]), Qbe.int_lit(f[5]), kind == "entryc") if defined
    end
  end
  out.join
end
