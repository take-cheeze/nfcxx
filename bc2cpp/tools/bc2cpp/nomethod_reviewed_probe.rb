# frozen_string_literal: true

# Runs bc2cpp.rb the way the closed build's compiled-gem codegen task does
# (mruby-*-compiled/mrbgem.rake with bc2cpp_closed_world_env), for the
# (docs/adr/0226).
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'
require_relative 'compiled_gems'
require_relative 'nomethod_reviewed'
require_relative 'proven_miss_reviewed'
require_relative 'strict_hints'

module NomethodReviewedProbe
  # The closed build's gem list: build_config.rb's rpg_maker_gems for
  # conf.name == 'closed' (single-format, with mruby-compiler), the compiled
  # gems, and every add_dependency they pull in. Derived by
  # bc2cpp_closed_core_gems (compiled_gems.rb); order is not significant.
  CLOSED_CORE_GEMS = bc2cpp_closed_core_gems.freeze

  module_function

  def closed_gems(root)
    gems = CLOSED_CORE_GEMS.to_h { |g| [g, "#{root}/3rd/mruby/mrbgems/#{g}"] }
    gems.merge!('mruby-stringio' => "#{root}/3rd/mruby-stringio", 'mruby-marshal' => "#{root}/3rd/mruby-marshal")
    %w[mruby-lcf mruby-rgss mruby-rpg2k].each { |g| gems[g] = "#{root}/#{g}" }
    BC2CPP_COMPILED_GEMS.each_key { |g| gems[g] = "#{root}/#{g}" }
    gems.transform_values { |d| File.expand_path(d) }
  end

  # The first line of each review-gate abort bc2cpp.rb prints (after every listing).
  REVIEW_ABORT = /\Abc2cpp: \d+ (?:closed-world nomethod|closed-world proven-class miss) violation\(s\) /
  # The line each such abort ends with.
  REVIEW_ABORT_END = /\A(?:Read each site: |Run the verify build over the real workloads, )/

  # [stdout, stderr, status] of one compiled gem's closed-world run.
  # An unreviewed site fails the run like a build; listing_run reads the listings of such a run.
  def run(gem_name, root, mrbc)
    this_gem = BC2CPP_COMPILED_GEMS.fetch(gem_name)
    others = BC2CPP_COMPILED_GEMS.reject { |name, _| name == gem_name }
    native_srcs = bc2cpp_rgss_native_srcs(root, 'closed') + core_native_srcs("#{root}/3rd/mruby") +
                  external_gem_native_srcs(root)
    Dir.mktmpdir('bc2cpp_nomethod_probe') do |tmp|
      env = {
        'MRBC' => mrbc, 'OUT_SYMBOL' => this_gem[:out_symbol], 'OUT_DIR' => tmp,
        'ONLY_OWNERS' => this_gem[:owners].join(','),
        'OTHER_OWNERS' => others.values.flat_map { |g| g[:owners] }.join(','),
        'NATIVE_SRCS' => Shellwords.join(native_srcs),
        'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(root)),
        'SKIP_UNSUPPORTED' => '1',
        'BC2CPP_BUILD_NAME' => 'closed', 'BC2CPP_COLLECTION_EXPORTS' => '1',
        'BC2CPP_BUILD_GEMS' => Shellwords.join(closed_gems(root).map { |n, d| "#{n}=#{d}" }),
      }
      world = closed_world_mrblib_srcs(root, core_gems: :canonical)
      Open3.capture3(env, RbConfig.ruby, File.join(__dir__, 'bc2cpp.rb'), '--annotated', *world)
    end
  end

  # True when `status`/`stderr` is a run that failed only on a review gate: exit 1, every
  # listing printed (the PROVEN_MISS listing is the last of them), and nothing after it but the
  # review-gate abort blocks.
  def review_abort?(status, stderr)
    return false unless status.exitstatus == 1

    lines = stderr.lines.map(&:chomp)
    listed = lines.rindex { |l| l.start_with?('== closed world proven-class miss sites: ') } or return false
    first = lines.index { |l| REVIEW_ABORT.match?(l) } or return false
    return false if first < listed

    tail = lines[first..]
    blocks = 0
    in_block = false
    tail.each do |l|
      if REVIEW_ABORT.match?(l) && !in_block
        in_block = true
        blocks += 1
      elsif in_block && l.start_with?('  ')
        next
      elsif in_block && REVIEW_ABORT_END.match?(l)
        in_block = false
      else
        return false
      end
    end
    blocks.positive? && !in_block
  end

  # [stdout, stderr, status] of `run`, raising unless it succeeded or failed only on the reviewed
  # lists (review_abort?): the listings of such a run are complete.
  def listing_run(gem_name, root, mrbc)
    out, err, status = run(gem_name, root, mrbc)
    unless status.success? || review_abort?(status, err)
      raise "#{gem_name}: bc2cpp.rb failed (not on a review gate):\n#{failure_tail(err)}"
    end

    [out, err, status]
  end

  # The part of a failed run's stderr that says why: from its abort message (a line starting `bc2cpp:` or
  # `[bc2cpp]`, e.g. an unreviewed site (no review annotation), which fails any closed-world run as it fails a build) to the end,
  # or the last 25 lines when there is none (an exception's backtrace).
  def failure_tail(stderr)
    lines = stderr.lines
    reviewed = lines.index { |l| REVIEW_ABORT.match?(l) }
    start = reviewed || lines.rindex { |l| l.match?(/\A(?:bc2cpp: |\[bc2cpp\] |\[bc2pp\] )/) }
    start ? lines[start..].join : lines.last(25).join
  end

  # Every site (one per bc2cpp_nomethod call) of a full closed run of all three
  # gems: {gem:, key:, self_receiver:}.
  def full_sites(root, mrbc)
    runs(root, mrbc).fetch(:full)
  end

  # Every PROVEN_MISS site (ADR 0275) of the same full runs: {gem:, key:}.
  def full_proven_miss_sites(root, mrbc)
    runs(root, mrbc).fetch(:proven_miss)
  end

  # The full runs (listing read past a review-gate abort): {full: sites, proven_miss: sites, strict_hint: sites}.
  # Runs in parallel; each is one single-threaded Ruby.
  def runs(root, mrbc)
    jobs = BC2CPP_COMPILED_GEMS.keys.map { |g| [g, :full] }
    results = jobs.map do |gem_name, kind|
      Thread.new do
        _out, err, status = listing_run(gem_name, root, mrbc)
        [gem_name, kind, err, status]
      end
    end.map(&:value)
    full = results.flat_map do |gem_name, _, err, _|
      NomethodReviewed.parse_listing(err).map { |s| s.merge(gem: gem_name) }
    end
    proven = results.flat_map do |gem_name, _, err, _|
      ProvenMiss.parse_listing(err).map { |s| s.merge(gem: gem_name) }
    end
    strict = results.flat_map do |gem_name, _, err, _|
      StrictHints.parse_listing(err).map { |s| s.merge(gem: gem_name) }
    end
    { full: full, proven_miss: proven, strict_hint: strict }
  end
end
