# frozen_string_literal: true

require 'tmpdir'

# Each compilation keeps its own source and output directory: fixture constants and core-method replacements
# must never leak into another fixture's closed world.
class FixtureCheck
  # The host mrbc fixtures compile with (set by require_mrbc!).
  attr_reader :mrbc

  def initialize(name)
    @name = name
    @checks = 0
    @failures = []
  end

  def require_mrbc!
    configured = ENV['MRBC']
    @mrbc = if configured
              configured
            else
              ENV.fetch('PATH', '').split(File::PATH_SEPARATOR)
                 .map { |directory| File.join(directory, 'mrbc') }
                 .find { |path| File.file?(path) && File.executable?(path) }
            end
    if @mrbc && File.file?(@mrbc) && File.executable?(@mrbc)
      return
    end

    abort "#{@name}: MRBC is not an executable host mrbc: #{configured}" if configured

    puts "SKIP #{@name}: set MRBC to a host mrbc or put mrbc on PATH"
    exit 0
  end

  def compile(source)
    raise 'call require_mrbc! before compiling fixtures' unless @mrbc

    Dir.mktmpdir(@name) do |directory|
      path = File.join(directory, 'fixture.rb')
      File.write(path, source)
      ireps, root = compile_ireps([path], @name.delete_suffix('_check'), directory, mrbc: @mrbc)
      yield ireps, root, directory
    end
  end

  def check(label, condition)
    @checks += 1
    puts "  #{condition ? 'ok  ' : 'FAIL'} #{label}"
    @failures << label unless condition
  end

  def finish!
    if @failures.empty?
      puts "#{@name}: #{@checks} checks passed"
    else
      warn "#{@name}: #{@failures.size} of #{@checks} checks failed"
      exit 1
    end
  end
end
