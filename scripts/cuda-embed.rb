# CUDA device image for nfcxx: writes the C++ that goes at the end of a .cu file's host copy. It holds the cubin of the
# file's device code as a byte array, and the table that maps each kernel's host function to its entry name in that
# image. lib/cuda/nfcxx_cuda.h loads the image when the program starts.
# Usage: scripts/mrb scripts/cuda-embed.rb FILE.cubin FILE.ir FILE.kernels > tail.cpp
#        scripts/mrb scripts/cuda-embed.rb --groups=DIR --ext=cubin|ptx FILE.ir FILE.kernels [FILE.kernels.addr] > tail.cpp
#   FILE.ir        the device IR (scripts/pathb-dump --ir); its function names are the entry names
#   FILE.kernels   one kernel name per line (cuda-rewrite.rb --device --kernels)
#   DIR            the emitter's groups (pathb-ptx-emit --groups-dir): groups.txt has one line per module, "gNNNN.ptx" and
#                  the IR names of its kernels; the module image is DIR/gNNNN.EXT. Each module gets its own image and table.
# A kernel's entry is its IR function: the name itself (extern "C") or the Itanium mangled name _Z<len><name>...
# Overloaded kernels (two IR functions with the same mangled prefix) are refused with exit 3.

def read_bytes(path)
  File.open(path, "rb") { |f| f.read }
end

def refuse(msg)
  $stderr.puts "refused: #{msg}"
  exit(3)
end

groups_dir = nil
ext = "cubin"
args = []
ARGV.each do |a|
  if a[0, 9] == "--groups="
    groups_dir = a[9..-1]
  elsif a[0, 6] == "--ext="
    ext = a[6..-1]
  else
    args << a
  end
end
cubin_path = nil
if groups_dir.nil?
  # the single-image form: FILE.cubin FILE.ir FILE.kernels [FILE.kernels.addr]
  if args.length < 3
    $stderr.puts "usage: cuda-embed.rb FILE.cubin FILE.ir FILE.kernels [FILE.kernels.addr]"
    $stderr.puts "       cuda-embed.rb --groups=DIR --ext=cubin|ptx FILE.ir FILE.kernels [FILE.kernels.addr]"
    exit(2)
  end
  cubin_path, ir_path, kernels_path, addr_path = args
else
  if args.length < 2
    $stderr.puts "usage: cuda-embed.rb --groups=DIR --ext=cubin|ptx FILE.ir FILE.kernels [FILE.kernels.addr]"
    exit(2)
  end
  ir_path, kernels_path, addr_path = args
end

# IR function names, in order: each `(function "NAME"` line.
names = []
read_bytes(ir_path).split("\n").each do |line|
  i = line.index("(function \"")
  next if i.nil?
  j = line.index("\"", i + 11)
  names << line[(i + 11)...j] unless j.nil?
end

kernels = read_bytes(kernels_path).split("\n").reject { |k| k.empty? }
# Address-taken instances (addr file, from cuda-rewrite): "HOST-EXPRESSION<TAB>WRAPPER" lines. Their wrappers are kernels
# too (the emitter lowers them), but the host has no name for a wrapper: the table entry is the instance's address.
addr_lines = (addr_path.nil? || !File.exist?(addr_path)) ? [] : read_bytes(addr_path).split("\n").reject { |l| l.empty? }
addr_wrappers = addr_lines.map { |l| l.split("\t", 2)[1] }
entries = []
kernels.each do |k|
  mangled = "_Z#{k.length}#{k}"
  hits = names.select { |n| n == k || n.start_with?(mangled) }
  refuse("kernel #{k}: no device function named #{k} (IR has #{names.join(', ')})") if hits.empty?
  refuse("kernel #{k}: #{hits.length} device functions match") if hits.length > 1
  entries << [k, hits[0]] unless addr_wrappers.include?(k)
end

# Address-taken instances (addr file, from cuda-rewrite): "HOST-EXPRESSION<TAB>WRAPPER" lines. The table maps the host
# instance's address (&HOST-EXPRESSION) to the wrapper's entry, so a function pointer the program was handed finds it.
addr_lines.each do |line|
  host, wrapper = line.split("\t", 2)
  refuse("address table line without a wrapper: #{line}") if wrapper.nil?
  hits = names.select { |n| n == wrapper }
  refuse("address of #{host}: no device function named #{wrapper}") if hits.empty?
  refuse("address of #{host}: #{hits.length} device functions match") if hits.length > 1
  entries << [host, hits[0]]
end

# The modules: each is [image bytes, its entries]. The single-image form is one module with all the entries.
modules = []
if groups_dir.nil?
  # PTX text (NFCXX_CUDA_JIT=1): cudaLibraryLoadData reads it as a C string, so the image ends with a NUL.
  modules << [File.expand_path(cubin_path), cubin_path.end_with?(".ptx"), entries]
else
  group_of = {}
  files = []
  read_bytes(groups_dir + "/groups.txt").split("\n").each do |line|
    parts = line.split(" ").reject { |p| p.empty? }
    next if parts.empty?
    gi = files.length
    files << parts[0]
    parts[1..-1].each { |n| group_of[n] = gi }
  end
  by_group = files.map { [] }
  entries.each do |host, ir|
    gi = group_of[ir]
    refuse("kernel #{host}: device function #{ir} is in no module of #{groups_dir}") if gi.nil?
    by_group[gi] << [host, ir]
  end
  files.each_with_index do |f, gi|
    base = f[0, f.length - 4]  # gNNNN.ptx -> gNNNN
    modules << [File.expand_path(groups_dir + "/" + base + "." + ext), ext == "ptx", by_group[gi]]
  end
end

# The image is not C text: a byte array of ~6 characters a byte made the host copy of a large file (llama.cpp's
# mmvf.cu: 494 MB) too big for the front end. The image is an assembler .incbin of the module's file, in the same
# object: a top-level asm block, which the back ends pass through, so the symbol is in the object the compile writes.
# The symbol is local to the object (two objects can each have __nfcxx_image_0). The C side declares it and gives its
# size, which is known here. The .incbin path is read at assembly time: the file must exist during the compile.
def asm_escape(text)
  text.gsub("\\") { "\\\\" }.gsub('"') { '\\"' }
end

out = "// Generated by scripts/cuda-embed.rb: the device image of this file and its kernel table. Do not edit.\n"
modules.each_with_index do |mod, mi|
  path, nul, table = mod
  # the single image keeps the names it always had; with several modules each one is numbered
  sfx = groups_dir.nil? ? "" : "_#{mi}"
  size = File.size(path) + (nul ? 1 : 0)
  sym = "__nfcxx_image#{sfx}"
  asm_lines = [
    ".pushsection .rodata",
    ".balign 16",
    ".local #{sym}",
    ".type #{sym}, @object",
    "#{sym}:",
    ".incbin \"#{asm_escape(path)}\""
  ]
  asm_lines << ".byte 0" if nul
  asm_lines += [".size #{sym}, #{size}", ".popsection"]
  out << "__asm__(\n"
  asm_lines.each { |l| out << "  \"" << asm_escape(l) << "\\n\"\n" }
  out << ");\n"
  out << "extern const unsigned char #{sym}[];\n"
  out << "static const __nfcxx_kernel_entry __nfcxx_kernels#{sfx}[] = {\n"
  table.each { |k, e| out << "  {(const void *)&#{k}, \"#{e}\"},\n" }
  out << "  {(const void *)0, (const char *)0},\n" if table.empty?
  out << "};\n"
  out << "static const __nfcxx_module_init __nfcxx_module#{sfx}(#{sym}, #{size}, __nfcxx_kernels#{sfx}, #{table.length});\n"
end
print out
