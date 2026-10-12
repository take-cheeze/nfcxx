# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'stringio'
require 'tmpdir'

# Opt-in warm generator for the fixture checks (BC2CPP_WARM_GENERATOR=1, ADR 0416). A server requires the tool once
# and warms the ScanCache memo; each generation runs in a fork of it, so no generator state carries between runs.
# A request whose load-time ENV gates differ from the server's runs as a subprocess instead.
module WarmGenerator
  ENV_NAME = 'BC2CPP_WARM_GENERATOR'

  # Records the ENV keys read while the server requires the tool. Prepended into ENV only in the server.
  module EnvTrace
    class << self
      attr_accessor :keys
    end

    %i[[] fetch key? has_key? include? member?].each do |name|
      define_method(name) do |key, *rest, &block|
        EnvTrace.keys << key if EnvTrace.keys && key.is_a?(String)
        super(key, *rest, &block)
      end
    end
  end

  # The server. It answers JSON lines on its input: `boot`, `generate` and `digest` requests.
  class Server
    def initialize
      @server_pid = Process.pid
      @tool = nil
      @gates = {}
      @tool_names = []
    end

    def serve(input = $stdin, output = $stdout)
      input.each_line do |line|
        output.puts(JSON.generate(handle(JSON.parse(line))))
        output.flush
      end
    end

    def handle(request)
      case request.fetch('op')
      when 'boot' then boot(request)
      when 'generate' then generate(request)
      when 'digest' then { 'digest' => state_digest }
      else raise ArgumentError, "WarmGenerator: unknown request #{request['op'].inspect}"
      end
    end

    private

    # Requires the tool (its main block is skipped: $PROGRAM_NAME is not the tool), records the load-time gates,
    # and warms the scans. The tool is required in this process only; generations never run here.
    def boot(request)
      @tool = File.expand_path(request.fetch('tool'))
      before = Object.constants
      ENV.singleton_class.prepend(EnvTrace) unless ENV.singleton_class.include?(EnvTrace)
      EnvTrace.keys = []
      require @tool
      read = EnvTrace.keys.uniq
      EnvTrace.keys = nil
      @gates = read.to_h { |key| [key, ENV[key]] }
      @tool_names = (Object.constants - before).select do |name|
        location = Object.const_source_location(name)
        location && location[0].start_with?(File.dirname(@tool))
      end.sort
      warm(request.fetch('native'), request.fetch('foreign'))
      { 'ready' => true, 'gates' => @gates.size, 'tool_constants' => @tool_names.size }
    end

    # The scans ScanCache routes through the memo, over the source lists a closed-world generation passes.
    # A scan that prints anything is not memoized: a fresh generation would print it again, so the memo is turned
    # off and the text is printed here once.
    def warm(native, foreign)
      ScanCache.memory = {}
      printed = StringIO.new
      saved = $stderr
      $stderr = printed
      begin
        NativeExpressionDevirt.analyze(native)
        NativeExpressionDevirt.analyze_exact_class_expressions(native)
        outside_world_tokens(native + foreign)
      ensure
        $stderr = saved
      end
      return if printed.string.empty?

      ScanCache.memory = nil
      saved.print(printed.string)
    end

    def generate(request)
      env = request.fetch('env')
      stale = @gates.reject { |key, value| env[key] == value }.keys
      return { 'fallback' => stale } unless stale.empty?

      exitstatus, termsig = fork_generation(request)
      { 'exit' => exitstatus, 'signal' => termsig }
    end

    # The child leaves with `exit`, not `exit!`: the tool's at_exit hooks (its report writers) must run as they do in
    # a subprocess, once, with the child's own state.
    def fork_generation(request)
      pid = fork do
        exit(generate_in_child(request))
      end
      _, status = Process.wait2(pid)
      [status.exitstatus, status.termsig]
    end

    # Runs in a forked child only. The server's own process must never reach the main block: that is the rule
    # that keeps the server's state clean.
    def generate_in_child(request)
      raise 'WarmGenerator: a generation must run in a forked child' if Process.pid == @server_pid

      $stdout.reopen(request.fetch('out'), 'w')
      $stderr.reopen(request.fetch('err'), 'w')
      ENV.replace(request.fetch('env'))
      ARGV.replace(request.fetch('argv'))
      $PROGRAM_NAME = @tool
      load @tool
      0
    rescue SystemExit => e
      e.status
    rescue Exception => e # rubocop:disable Lint/RescueException -- report the error as an uncaught one, exit 1
      e.set_backtrace(subprocess_backtrace(e.backtrace || []))
      $stderr.print(e.full_message(highlight: false))
      1
    ensure
      $stdout.flush
      $stderr.flush
    end

    # The frames a subprocess run would show: this file's frames (the server's loop and the fork) are dropped, and
    # the tool's top level, loaded here rather than run as the main script, reads <main> as it does there.
    def subprocess_backtrace(lines)
      lines.reject { |line| line.start_with?("#{__FILE__}:") }
           .map { |line| line.sub(%r{(/bc2cpp\.rb:\d+:in [`'])<top \(required\)>'}, "\\1<main>'") }
    end

    # A digest of the tool's own class-level state and constants. Compared before and after requests, it shows
    # that no child's changes reached the server. Process-local: it uses Object#hash.
    def state_digest
      lines = []
      @tool_names.each do |name|
        mod = Object.const_get(name)
        next unless mod.is_a?(Module)

        Kernel.instance_method(:instance_variables).bind_call(mod).each do |iv|
          lines << "#{name}.@#{iv}=#{fingerprint(Kernel.instance_method(:instance_variable_get).bind_call(mod, iv))}"
        end
        Module.instance_method(:class_variables).bind_call(mod).each do |cv|
          lines << "#{name}.@@#{cv}=#{fingerprint(Module.instance_method(:class_variable_get).bind_call(mod, cv))}"
        end
        Module.instance_method(:constants).bind_call(mod, false).each do |c|
          next if Module.instance_method(:autoload?).bind_call(mod, c)

          lines << "#{name}::#{c}=#{fingerprint(Module.instance_method(:const_get).bind_call(mod, c, false))}"
        end
      end
      Digest::SHA256.hexdigest(lines.sort.join("\n"))
    end

    def fingerprint(value)
      case value
      when Hash, Array, Set, String then [value.class.name, value.size, value.hash]
      when Numeric, Symbol, nil, true, false then value.inspect
      else [value.class.name, value.object_id]
      end.inspect
    end
  end

  # The client, in the check process. One server per tool and source lists; it starts on the first request.
  class Client
    Result = Struct.new(:exitstatus, :termsig) do
      def success? = exitstatus.zero?
    end

    attr_reader :generations, :fallbacks

    def initialize(tool:, native:, foreign:)
      @tool = File.expand_path(tool)
      @dir = Dir.mktmpdir('bc2cpp-warm')
      @stdin, @stdout, @waiter = Open3.popen2(RbConfig.ruby, __FILE__, '--serve')
      @stdin.sync = true
      @sequence = 0
      @generations = 0
      @fallbacks = 0
      reply = exchange('op' => 'boot', 'tool' => @tool, 'native' => native, 'foreign' => foreign)
      raise 'WarmGenerator: the server did not boot' unless reply['ready']
    end

    # [stdout, stderr, status] of `ruby TOOL *argv` with `changes` (nil unsets) applied to the environment, as
    # Open3.capture3 returns it.
    def run(argv, changes)
      @sequence += 1
      out = File.join(@dir, "#{@sequence}.out")
      err = File.join(@dir, "#{@sequence}.err")
      env = ENV.to_h.merge(changes).compact
      reply = exchange('op' => 'generate', 'argv' => argv, 'env' => env, 'out' => out, 'err' => err)
      if reply.key?('fallback')
        @fallbacks += 1
        return Open3.capture3(changes, RbConfig.ruby, @tool, *argv)
      end
      raise "WarmGenerator: the generation was killed by signal #{reply['signal']}" if reply['signal']

      @generations += 1
      encoding = Encoding.default_external
      [File.binread(out).force_encoding(encoding), File.binread(err).force_encoding(encoding),
       Result.new(reply.fetch('exit'), nil)]
    end

    def digest
      exchange('op' => 'digest').fetch('digest')
    end

    def close
      return if @stdin.closed?

      @stdin.close
      @stdout.close
      @waiter.value
      FileUtils.rm_rf(@dir)
    end

    private

    def exchange(request)
      @stdin.puts(JSON.generate(request))
      line = @stdout.gets
      raise 'WarmGenerator: the server exited without answering (see its stderr above)' unless line

      JSON.parse(line)
    end
  end

  module_function

  def enabled?
    ENV[ENV_NAME] == '1' && Process.respond_to?(:fork)
  end

  # The client for `tool`, started on first use and closed when the process exits.
  def client(tool:, native:, foreign:)
    @clients ||= {}
    @clients[File.expand_path(tool)] ||= Client.new(tool: tool, native: native, foreign: foreign).tap do |started|
      at_exit { started.close }
    end
  end

  # The clients this process has started, by tool path.
  def clients = @clients || {}
end

if $PROGRAM_NAME == __FILE__ && ARGV == ['--serve']
  require_relative 'scan_cache'
  WarmGenerator::Server.new.serve
  # The server's own at_exit hooks (the tool's report writers, registered when it was required) must not run
  # here: they would overwrite the reports the children wrote with the server's empty state.
  $stdout.flush
  exit!(0)
end
