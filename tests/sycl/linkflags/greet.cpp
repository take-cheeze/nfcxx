// libgreet.so for tests/sycl/linkflags: the host program links it through the -L/-l/-rpath flags of sycl-build.sh
extern "C" int greet(void) { return 42; }
