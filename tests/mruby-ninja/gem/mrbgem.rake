# A gem whose build step generates its header (tests/mruby-ninja/run.sh): the file task runs as a ninja edge, and
# the source that includes the header depends on it, as rake's file tasks would have it.
MRuby::Gem::Specification.new('mruby-generated-demo') do |spec|
  spec.license = 'MIT'
  spec.author = 'nfcxx'
  spec.summary = 'a gem whose build step generates a header'

  spec.cc.include_paths << build_dir

  header = "#{build_dir}/demo_value.h"
  file header => "#{dir}/demo_value.h.in" do |t|
    FileUtils.mkdir_p File.dirname(t.name)
    File.write(t.name, File.read(t.prerequisites.first).sub('@VALUE@', '42'))
  end
  file "#{dir}/src/demo.c" => [header]
end
