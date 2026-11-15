# Helpers of the Ruby launchers of the repo's tools (scripts/mrb.rb, scripts/weak-symbols.rb, scripts/spirv-emit.rb).
# The Ruby port of scripts/tool-ensure.sh (its original is tests/helpers/oracle/tool-ensure.sh), plus the bash `exec`
# that the launchers use.
#   ToolEnsure.ensure(name, root)  builds build/NAME from tools/NAME (its build.ninja) when it is missing. Compiles run in
#                                  parallel (one back end per object), so the build is serialized by a lock directory: the
#                                  first run builds, the others wait for the binary. Returns the status to exit with.
#   ToolEnsure.exec_program(path, *args)  `exec "$path" "$@"`: the program replaces this process. A program that cannot run
#                                  ends it with the shell's status (127, or 126) and message.
require 'fileutils'

module ToolEnsure
  module_function

  def ensure(name, root)
    exe = File.join(root, 'build', name)
    lock = "#{exe}.lock"
    return 0 if File.executable?(exe)

    FileUtils.mkdir_p(File.join(root, 'build'))
    waited = 0
    until File.executable?(exe)
      begin
        Dir.mkdir(lock)
      rescue SystemCallError
        sleep 0.2
        waited += 1
        unless waited < 3000
          $stderr.puts "#{name}: #{lock} is stuck (remove it if no build is running)"
          return 1
        end
        next
      end
      rc = File.executable?(exe) ? 0 : build(root, name)
      begin
        Dir.rmdir(lock)
      rescue SystemCallError
        nil
      end
      return rc
    end
    0
  end

  # ninja -C tools/NAME, its output on stderr (bash: ninja -C ... >&2)
  def build(root, name)
    ok = system('ninja', '-C', File.join(root, 'tools', name), out: $stderr)
    return 0 if ok

    if ok.nil?
      $stderr.puts 'ninja: command not found'
      return 127
    end
    $?.exitstatus || 1
  end

  def exec_program(path, *args)
    Kernel.exec([path, path], *args)
  rescue Errno::EACCES
    $stderr.puts "#{path}: Permission denied"
    exit 126
  rescue Errno::ENOENT
    $stderr.puts(path.include?('/') ? "#{path}: No such file or directory" : "#{path}: command not found")
    exit 127
  end
end
