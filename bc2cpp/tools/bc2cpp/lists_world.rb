# frozen_string_literal: true

require_relative 'world_root'

# LISTS_WORLD: the build whose binary the closed-list proof (static_dispatch_registrations.rb) reads, named by
# BC2CPP_LISTS_WORLD (default `closed`). A lists file is proven for that one build's world and records it (`world`):
# only a build of that name takes its closed-only parts (StaticDispatchLists::Lists#closed_for?).
#
# A world differs from the closed one only in what its binary links: its gem list (build_config.rb's rpg_maker_gems for
# that conf.name, the stanza's own gems, and their add_dependency closure) and its native host sources. Its Ruby is
# the closed world's (closed_world_mrblib_srcs): a world is VM-free, as the closed build is, so no gem's mrblib loads
# beside it (wio's rewritten copies and LCF::Schema blob go with bc2cpp_drop_mrblib).
module ListsWorld
  ENV_NAME = 'BC2CPP_LISTS_WORLD'
  # name => the native sources outside the gems its binary links: the closed library runs in trace_host.cxx; the wio
  # firmware is platformio.ini's env:wio (build_src_filter: wio_rgss_boot_main.cxx).
  HOSTS = {
    'closed' => ->(_root) { [File.expand_path('scripts/bc2cpp/trace_host.cxx', BC2CPP_TREE_ROOT)] },
    'wio' => ->(root) { ["#{root}/app/wio/src/wio_rgss_boot_main.cxx"] }
  }.freeze
  # name => gem directories the build adds outside rpg_maker_gems' core gems: the wio stanza's
  # `conf.gem .../hal-wio-io`, and the mruby-math-wio its rpg_maker_gems branch takes instead of mruby-math.
  EXTRA_GEMS = { 'closed' => [], 'wio' => %w[app/wio/hal-wio-io app/wio/mruby-math-wio] }.freeze

  module_function

  def name(env = ENV)
    world = @override || env[ENV_NAME].to_s
    world = 'closed' if world.empty?
    raise "#{ENV_NAME}=#{world} is not one of #{HOSTS.keys.join('/')}" unless HOSTS.key?(world)

    world
  end

  def closed?(env = ENV)
    name(env) == 'closed'
  end

  # Runs the block as if BC2CPP_LISTS_WORLD were `world` (a consumer verifying a lists file of that world).
  def use(world)
    saved = @override
    @override = world
    yield
  ensure
    @override = saved
  end

  def host_natives(root, world = name)
    HOSTS.fetch(world).call(File.expand_path(root)).map { |p| File.expand_path(p) }
  end

  # The world's own gem directories, as directory prefixes (app/ is unlinked otherwise).
  def linked_app_dirs(root, world = name)
    root = File.expand_path(root)
    EXTRA_GEMS.fetch(world).map { |d| "#{root}/#{d}/" }
  end

  # Files the world's proof reads beside the closed one's, for the lists digest: its own gems' rakes.
  def digest_inputs(root, world = name)
    root = File.expand_path(root)
    EXTRA_GEMS.fetch(world).map { |d| "#{root}/#{d}/mrbgem.rake" }
  end
end
