# mruby-bc2cpp-runner

The bc2cpp command as an mruby executable. `mruby-bc2cpp-sources` bakes the bc2cpp source graph for `require`;
this gem names its entry (`BC2CPPRunner.run`), and `bc2cpp_main.rb` is the script the executable runs.

Build (from the repository root):

    cd 3rd/mruby && MRUBY_CONFIG=../../host-libs/mruby-bc2cpp-runner/build_config.rb MRUBY_BUILD_DIR=<dir> rake
    <dir>/bc2cpp-runner/bin/mruby ../../host-libs/mruby-bc2cpp-runner/bc2cpp_main.rb <bc2cpp args>

## Status

The executable builds and runs bc2cpp's entry up to the first missing piece. Blockers, in the order a run hits them:

1. `Open3` (process spawn): `native_vm`, `lcf_schema_oracle`, `profile_annotations` and others run `mrbc` or
   `RbConfig.ruby` with `Open3.capture3`. mruby has no spawn primitive. `shared_generation` also forks.
2. `Marshal` (`scan_cache` marshals the scan cache). The gem is `3rd/mruby-marshal`, which depends on
   `mruby-onig-regexp`; the build needs Onigmo bundled as `build_config.rb` does (`bundle_onigmo`) before Marshal loads.
3. Later steps are unknown until 1 and 2 are done.

Fixed on the way: `mruby-prism` renders its generated headers when the gem is defined (its presym scan read them before
their rake tasks ran); `mruby-require` defines `LoadError`/`ScriptError` (mruby core has neither) and no longer needs
`Struct` (it loads before mruby-struct); `ENV` comes from `mruby-env` (mruby has none).
