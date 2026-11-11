# frozen_string_literal: true

require 'json'
require 'tmpdir'
require_relative '../../tools/bc2cpp/type_check_variants'

variant_error = lambda do |label, &block|
  begin
    block.call
  rescue TypeCheckVariants::Error
    next
  end
  raise "shared setup accepted #{label}"
end
Dir.mktmpdir('type-check-variant-protocol') do |dir|
  flag = 'BC2CPP_IR_CONTEXT_MAX_CONTEXTS'
  entries = 2.times.map do |index|
    { 'env' => { flag => index.zero? ? 'first' : nil }, 'facts' => File.join(dir, "#{index}.json"),
      'stderr' => File.join(dir, "#{index}.stderr") }
  end
  TypeCheckVariants.validate_plan(entries)
  variant_error.call('empty plan') { TypeCheckVariants.validate_plan([]) }
  variant_error.call('non-array plan') { TypeCheckVariants.validate_plan({}) }
  changes = [->(e) { e[0]['env'] = [] }, ->(e) { e[0]['env']['MRBC'] = 'other' },
             ->(e) { e[0]['env'][flag] = 1 }, ->(e) { e[0]['facts'] = 'relative.json' },
             ->(e) { e[0]['facts'] = e[1]['stderr'] }, ->(e) { e[0]['unknown'] = 'field' }]
  changes.each do |change|
    bad = Marshal.load(Marshal.dump(entries))
    change.call(bad)
    variant_error.call('invalid plan') { TypeCheckVariants.validate_plan(bad) }
  end
  variant_error.call('missing plan argument') { TypeCheckVariants.parse_argv([TypeCheckVariants::FLAG]) }
  variant_error.call('duplicate plans') { TypeCheckVariants.parse_argv([TypeCheckVariants::FLAG] * 2) }

  TypeCheckVariants::CONTROL_KEYS.each do |key|
    [[:[], [key]], [:fetch, [key, 'fallback']], [:key?, [key]], [:values_at, [key]], [:slice, [key]],
     [:assoc, [key]], [:delete, [key]], [:[]=, [key, 'changed']]].each do |method, args|
      begin
        TypeCheckVariants.arm_guard
        variant_error.call("early ENV.#{method}") { ENV.public_send(method, *args) }
      ensure
        TypeCheckVariants::EnvGuard.armed = false
      end
    end
  end
  %i[to_h to_a keys values each each_pair each_key each_value select inspect size length empty? invert except count clear].each do |method|
    begin
      TypeCheckVariants.arm_guard
      variant_error.call("early full ENV.#{method}") { ENV.public_send(method) }
    ensure
      TypeCheckVariants::EnvGuard.armed = false
    end
  end
  begin
    TypeCheckVariants.arm_guard
    ENV['PATH']
  ensure
    TypeCheckVariants::EnvGuard.armed = false
  end

  if Process.respond_to?(:fork)
    state = []
    pid = fork do
      ENV['BC2CPP_TYPE_FACTS'] = File.join(dir, 'parent.json')
      at_exit { File.write("#{ENV.fetch('BC2CPP_TYPE_FACTS')}.exit", 'ran') }
      TypeCheckVariants.fork_variants(entries)
      state << 'private'
      File.write(ENV.fetch('BC2CPP_TYPE_FACTS'), JSON.generate(value: ENV[flag], state: state, pid: Process.pid))
      warn 'variant diagnostic'
      exit 0
    end
    raise 'shared variants failed' unless Process.wait2(pid).last.success?
    outputs = entries.map { |entry| JSON.parse(File.read(entry['facts'])) }
    raise 'variant environment or private state leaked' unless outputs.map { |v| [v['value'], v['state']] } == [['first', ['private']], [nil, ['private']]]
    raise 'variants reused a process' unless outputs.map { |v| v['pid'] }.uniq.size == 2
    raise 'parent ran child exit hooks' if File.exist?(File.join(dir, 'parent.json.exit'))
    entries.each do |entry|
      raise 'child exit hook did not run' unless File.exist?("#{entry['facts']}.exit")
      raise 'child diagnostics were lost' unless File.read(entry['stderr']).include?('variant diagnostic')
    end

    parent_error = File.join(dir, 'failure.stderr')
    pid = fork do
      $stderr.reopen(parent_error, 'w')
      TypeCheckVariants.fork_variants(entries.first(1))
      warn 'expected child failure'
      exit 7
    end
    status = Process.wait2(pid).last
    raise 'child failure was not propagated' unless status.exitstatus == 7 && File.read(parent_error).include?('expected child failure')
  end
end
puts 'shared type-check setup guards, protocol, private forks and failure checks passed'
