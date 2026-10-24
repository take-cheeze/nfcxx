# Refused by mruby-ninja: rake's rule tasks are not modelled (tests/mruby-ninja/run.sh expects the generation to fail).
MRuby::Gem::Specification.new('mruby-rule-demo') do |spec|
  spec.license = 'MIT'
  rule '.o' => '.c' do |t|
    sh "cc -c #{t.source}"
  end
end
