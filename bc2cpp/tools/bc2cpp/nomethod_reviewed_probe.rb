# frozen_string_literal: true

# Runs bc2cpp.rb the way a wio build's compiled-gem codegen task does
# (mruby-*-compiled/mrbgem.rake with bc2cpp_closed_world_env), for the
# NOMETHOD_REVIEWED check and update scripts (docs/adr/0226).
require 'open3'
require 'rbconfig'
require 'shellwords'
require 'tmpdir'
require_relative 'compiled_gems'
require_relative 'nomethod_reviewed'

module NomethodReviewedProbe
  # The wio build's gem list: build_config.rb's rpg_maker_gems for
  # conf.name == 'wio', hal-wio-io, and every add_dependency they pull in.
  WIO_CORE_GEMS = %w[mruby-array-ext mruby-hash-ext mruby-enum-ext mruby-io mruby-numeric-ext mruby-range-ext
                     mruby-fiber mruby-exit mruby-sprintf mruby-bigint mruby-pack mruby-string-ext mruby-struct
                     mruby-metaprog mruby-enumerator].freeze

  module_function

  def wio_gems(root)
    gems = WIO_CORE_GEMS.to_h { |g| [g, "#{root}/3rd/mruby/mrbgems/#{g}"] }
    gems.merge!('hal-wio-io' => "#{root}/app/wio/hal-wio-io", 'mruby-math-wio' => "#{root}/app/wio/mruby-math-wio",
                'mruby-stringio' => "#{root}/3rd/mruby-stringio", 'mruby-marshal' => "#{root}/3rd/mruby-marshal")
    %w[mruby-lcf mruby-rgss mruby-rpg2k].each { |g| gems[g] = "#{root}/#{g}" }
    BC2CPP_COMPILED_GEMS.each_key { |g| gems[g] = "#{root}/#{g}" }
    gems.transform_values { |d| File.expand_path(d) }
  end

  # [stdout, stderr, status] of one compiled gem's closed-world run.
  # `hot_methods`: the list a real (hot-only) wio build passes; nil compiles
  # every method, the superset the exact check needs. `allow` sets
  # NomethodReviewed::ALLOW_ENV so the listing survives violations.
  def run(gem_name, root, mrbc, hot_methods: nil, allow: true)
    this_gem = BC2CPP_COMPILED_GEMS.fetch(gem_name)
    others = BC2CPP_COMPILED_GEMS.reject { |name, _| name == gem_name }
    native_srcs = Dir["#{root}/mruby-rgss/src/*.cxx"] + core_native_srcs("#{root}/3rd/mruby") +
                  external_gem_native_srcs(root)
    Dir.mktmpdir('bc2cpp_nomethod_probe') do |tmp|
      env = {
        'MRBC' => mrbc, 'OUT_SYMBOL' => this_gem[:out_symbol], 'OUT_DIR' => tmp,
        'ONLY_OWNERS' => this_gem[:owners].join(','),
        'OTHER_OWNERS' => others.values.flat_map { |g| g[:owners] }.join(','),
        'NATIVE_SRCS' => Shellwords.join(native_srcs),
        'FOREIGN_RUBY_SRCS' => Shellwords.join(foreign_mrblib_srcs(root)),
        'SKIP_UNSUPPORTED' => '1',
        'BC2CPP_CLOSED_WORLD' => '1', 'BC2CPP_BUILD_NAME' => 'wio',
        'BC2CPP_BUILD_GEMS' => Shellwords.join(wio_gems(root).map { |n, d| "#{n}=#{d}" }),
        'BC2CPP_HOT_METHODS' => hot_methods,
        NomethodReviewed::ALLOW_ENV => (allow ? 'allow' : nil)
      }
      Open3.capture3(env, RbConfig.ruby, File.join(__dir__, 'bc2cpp.rb'), *closed_world_mrblib_srcs(root))
    end
  end

  # Every site (one per bc2cpp_nomethod call) of a full wio run of all three
  # gems: {gem:, key:, self_receiver:}.
  def full_sites(root, mrbc)
    runs(root, mrbc, hot: false).fetch(:full)
  end

  # The full runs (listing kept past violations), plus with `hot:` the real
  # build's hot-only runs held to NOMETHOD_REVIEWED: {full: sites, hot: {gem =>
  # [status, stderr]}}. Runs in parallel; each is one single-threaded Ruby.
  def runs(root, mrbc, hot: true)
    jobs = BC2CPP_COMPILED_GEMS.keys.map { |g| [g, :full] }
    jobs += BC2CPP_COMPILED_GEMS.keys.map { |g| [g, :hot] } if hot
    results = jobs.map do |gem_name, kind|
      Thread.new do
        hot_methods = kind == :hot ? BC2CPP_HOT_METHODS_PATH : nil
        _out, err, status = run(gem_name, root, mrbc, hot_methods: hot_methods, allow: kind == :full)
        [gem_name, kind, err, status]
      end
    end.map(&:value)
    full = results.select { |_, kind, _, _| kind == :full }.flat_map do |gem_name, _, err, status|
      raise "#{gem_name}: bc2cpp.rb failed:\n#{err[-4000..] || err}" unless status.success?

      NomethodReviewed.parse_listing(err).map { |s| s.merge(gem: gem_name) }
    end
    hot_runs = results.select { |_, kind, _, _| kind == :hot }.to_h { |gem_name, _, err, status| [gem_name, [status, err]] }
    { full: full, hot: hot_runs }
  end
end
