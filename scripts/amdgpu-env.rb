# Finds the AMD GPU's architecture and an LLVM clang that can compile for amdgcn, for nfcxx's AMD GPU path
# (docs/notes/gpu.md, "AMD GPUs (ROCm)"): the Ruby port of the bash amdgpu-env.sh (its original is tests/amdgpu-env/oracle.sh;
# tests/amdgpu-env/run.sh is the differential test). Neither needs a ROCm tool: the architecture comes from the kernel
# driver's topology (KFD), and the compiler is any clang with the amdgcn target, else ROCm's clang.
#
#   ruby scripts/amdgpu-env.rb amdgpu_arch    prints the first GPU's gfx name (gfx1151), or fails when there is no AMD GPU
#   ruby scripts/amdgpu-env.rb amdgpu_clang   prints a clang that targets amdgcn, or fails
#
# Overrides: NFCXX_AMDGPU_ARCH (the architecture), NFCXX_AMDGPU_CLANG (the compiler), ROCM (ROCm's root, default /opt/rocm).

module AmdgpuEnv
  module_function

  KFD_NODES = "/sys/class/kfd/kfd/topology/nodes"

  # the architecture, or nil
  def arch(env = ENV)
    override = env["NFCXX_AMDGPU_ARCH"].to_s
    return override unless override.empty?

    Dir.glob("#{KFD_NODES}/*/").sort.each do |node|
      # KFD's topology keeps the value in the node's properties file ("gfx_target_version 110501"); older kernels had a file.
      v = read_property(File.join(node, "properties"), "gfx_target_version")
      v = read_file(File.join(node, "gfx_target_version")) if v.nil? || v.empty?
      next if v.nil? || v.empty? || !v.match?(/\A\d+\z/) || v.to_i <= 0

      # gfx_target_version is major * 10000 + minor * 100 + stepping: 110501 is gfx1151 (stepping 1, as one hex digit).
      n = v.to_i
      return format("gfx%d%d%x", n / 10000, n / 100 % 100, n % 100)
    end
    nil
  end

  # the value of KEY on a "KEY VALUE" line of FILE, or nil
  def read_property(file, key)
    File.foreach(file) do |line|
      fields = line.split
      return fields[1] if fields[0] == key && fields[1]
    end
    nil
  rescue SystemCallError
    nil
  end

  # the contents of FILE without its trailing newline, or nil when it cannot be read
  def read_file(file)
    File.read(file).chomp
  rescue SystemCallError
    nil
  end

  # the first executable named NAME on PATH, as the shell's command -v finds it
  def which(name, env = ENV)
    env["PATH"].to_s.split(":").each do |dir|
      path = File.join(dir, name)
      return path if File.file?(path) && File.executable?(path)
    end
    nil
  end

  # a clang that targets amdgcn, or nil
  def clang(env = ENV)
    override = env["NFCXX_AMDGPU_CLANG"].to_s
    return override unless override.empty?

    %w[clang clang-21 clang-20 clang-19 clang-18].each do |c|
      path = which(c, env)
      next unless path

      targets = begin
        IO.popen([path, "--print-targets"], err: File::NULL, &:read)
      rescue SystemCallError
        ""
      end
      return path if targets.each_line.any? { |l| l.match?(/\A *amdgcn /) }
    end
    rocm = env["ROCM"].to_s
    rocm = "/opt/rocm" if rocm.empty?
    candidate = File.join(rocm, "llvm/bin/clang")
    return candidate if File.file?(candidate) && File.executable?(candidate)

    nil
  end
end

# the command line: the function's value on a line, or nothing and a failure status
if $PROGRAM_NAME == __FILE__
  value = case ARGV[0]
          when "amdgpu_arch" then AmdgpuEnv.arch
          when "amdgpu_clang" then AmdgpuEnv.clang
          else abort "amdgpu-env: unknown function #{ARGV[0].inspect}"
          end
  exit 1 if value.nil?
  puts value
end
