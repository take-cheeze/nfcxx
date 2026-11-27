MRuby::Gem::Specification.new('mruby-signal') do |spec|
  spec.license = 'MIT'
  spec.author  = 'mruby developers'
  spec.summary = 'Signal module (Signal.trap) on the platform sigaction'
  # Hosted in nfcxx (bc2cpp/host-libs), not in the mruby fork: a build adds it with conf.gem on this directory.
end
