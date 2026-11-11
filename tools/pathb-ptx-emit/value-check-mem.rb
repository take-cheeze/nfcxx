# value-check-mem.rb: port of tools/pathb-ptx-emit/value-check-mem.py for mruby (docs/notes/mruby-scripting.md).
# Writes the GPU value check of the memory forms (run by value-check-mem.cu): for each scalar type, one kernel whose body
# is the C++ emitter's own lines for index, load and store (build/pathb-ptx-emit --eval-arith), with the thread's index
# loaded from memory and the value copied out. The runner compares the output with the host's copy of the indexed input.
# Usage: scripts/mrb tools/pathb-ptx-emit/value-check-mem.rb OUT.ptx   (needs build/pathb-ptx-emit built)
# mruby has no Process, so the emitter runs through IO.popen with its exit status read back from `echo $?`; its cases
# and output go through files next to OUT.ptx (OUT.ptx.emit.*), removed again. The directory comes from __FILE__.

EMIT = File.dirname(__FILE__) + "/../../build/pathb-ptx-emit"

# type, element size, the register class of a value of the type (its PTX register is %<class>9)
TYPES = [
  ["char", 1, "r"], ["unsigned_char", 1, "r"], ["short", 2, "r"], ["unsigned_short", 2, "r"],
  ["int", 4, "r"], ["unsigned_int", 4, "r"], ["long", 8, "rd"], ["unsigned_long", 8, "rd"],
  ["float", 4, "f"], ["double", 8, "fd"],
]

def sh_quote(s)
  "'" + s.gsub("'") { "'\\''" } + "'"
end

def read_file(path)
  File.open(path, "rb") { |f| f.read }.to_s
end

def write_file(path, text)
  File.open(path, "wb") { |f| f.write(text) }
end

def remove_if_exists(path)
  File.delete(path) if File.exist?(path)
end

# Runs the emitter on the cases (one per line) and returns its output lines. A nonzero exit stops the script, as the
# Python original's check=True does (its traceback is replaced by a message on stderr).
def emitter_lines(cases, base)
  cases_path = base + ".cases"
  o = base + ".stdout"
  e = base + ".stderr"
  write_file(cases_path, cases.join("\n") + "\n")
  io = IO.popen("#{sh_quote(EMIT)} --eval-arith #{sh_quote(cases_path)} >#{sh_quote(o)} 2>#{sh_quote(e)}; echo $?")
  status = io.read.to_i
  io.close
  if status != 0
    $stderr.puts "value-check-mem: #{EMIT} --eval-arith failed (exit #{status})"
    $stderr.write(read_file(e)) if File.exist?(e)
    [cases_path, o, e].each { |p| remove_if_exists(p) }
    exit 1
  end
  out = read_file(o)
  [cases_path, o, e].each { |p| remove_if_exists(p) }
  out.split("\n")
end

def body_for(t, size, cls, base)
  v = "%" + cls + "9"
  # index: the address of in[idx] (into %rd9); load: the value into v from that address; store: v to out's element.
  index_case = "(mem (ptr) ((%1 %rd1 (ptr)) (%2 %r2 int)) () (index %1 %2 #{size}))"
  load_case = "(mem #{t} ((%1 %rd9 (ptr))) () (load #{t} %1))"
  store_case = "(stmt ((%1 %rd3 (ptr)) (%2 #{v} #{t})) () (store #{t} %1 %2))"
  lines = emitter_lines([index_case, load_case, store_case], base)
  dests = ["%rd9", v, nil]
  out = []
  lines[0, 3].each_with_index do |line, i|
    dest = dests[i]
    line = line.gsub("%d") { dest } if dest
    line.split(" ~ ").each do |x|
      s = x.strip
      out << s unless s.empty?
    end
  end
  out
end

def main
  if ARGV.empty?
    $stderr.puts "usage: value-check-mem.rb OUT.ptx"
    exit 1
  end
  out_path = ARGV[0]
  base = out_path + ".emit"
  mod = [".version 7.0", ".target sm_75", ".address_size 64", ""]
  TYPES.each do |t, size, cls|
    name = "k_" + t
    body = body_for(t, size, cls, base)
    lines = [
      ".visible .entry " + name + "(.param .u64 pin, .param .u64 pidx, .param .u64 pout)", "{",
      "  .reg .pred %p<16>;", "  .reg .b32 %r<16>;", "  .reg .b64 %rd<16>;", "  .reg .f32 %f<16>;",
      "  .reg .f64 %fd<16>;",
      "  ld.param.u64 %rd1, [pin];", "  ld.param.u64 %rd5, [pidx];", "  ld.param.u64 %rd6, [pout];",
      "  mov.u32 %r0, %tid.x;",
      "  mul.wide.u32 %rd7, %r0, 4;", "  add.s64 %rd8, %rd5, %rd7;", "  ld.global.s32 %r2, [%rd8];",
      "  mul.wide.u32 %rd4, %r0, #{size};", "  add.s64 %rd3, %rd6, %rd4;",
    ]
    body.each { |b| lines << (b.start_with?("  ") ? b : "  " + b) }
    lines += ["  ret;", "}", ""]
    mod += lines
  end
  write_file(out_path, mod.join("\n") + "\n")
end

main
