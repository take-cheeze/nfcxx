# rbs_import.rb

Imports RBS signatures for the gems a `Gemfile.lock` names.

    ruby tools/rbs-import/rbs_import.rb --lock Gemfile.lock --out bc2cpp/sig --collection DIR [--only NAME,...]

For each locked gem, the signatures come from the first source that has them:

1. the installed gem's `sig/` directory (the gem must be installed);
2. a `ruby/gem_rbs_collection` checkout given with `--collection`: `gems/<name>/<major.minor>/`, or the nearest
   lower version folder. Each folder's `manifest.yaml` is copied along with the `.rbs` files.

`_test` trees are skipped. Gems with no signatures in either source are reported as `none`, not as errors.

Check: importing the six Rails 8.1 gems from `ruby/gem_rbs_collection` (commit 2ae0901) reproduces
`bc2cpp/sig/rails` exactly.
