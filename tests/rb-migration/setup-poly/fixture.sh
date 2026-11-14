mkdir -p build/poly/src/.git build/poly/src/include
: > build/poly/src/include/mruby.h
mkdir -p build/poly/out-pathb/host/lib build/poly/out-pathb/host/include build/poly/out-gcc/host/lib
: > build/poly/out-pathb/host/lib/libmruby.a; : > build/poly/out-gcc/host/lib/libmruby.a
: > build/poly/out-pathb/host/include/mruby.h
touch -d '2000-01-01' scripts/mruby-rt-config.rb
