// STD: c++17
// PAPER: P0061R1
// EXPECT: 4
#if __has_include(<nfcxx_no_such_header_zz.h>)
#error the header does not exist
#endif
int main() { return 4; }
