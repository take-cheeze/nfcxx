# mruby-compare-by-identity: Hash#compare_by_identity and Set#compare_by_identity, which mruby does not have.
#
# An identity hash or set keeps its entries keyed by object_id, in a store of its own, and the methods of
# mrblib/compare_by_identity.rb shadow the core ones on that one object. Other hashes and sets are untouched.
MRuby::Gem::Specification.new('mruby-compare-by-identity') do |spec|
  spec.license = 'MIT'
  spec.authors = 'take-cheeze'
  spec.summary = 'compare_by_identity for Hash and Set, for mruby'
  # each, each_pair, each_key and each_value return an Enumerator without a block, as Hash's do.
  spec.add_dependency 'mruby-enumerator', core: 'mruby-enumerator'
end
