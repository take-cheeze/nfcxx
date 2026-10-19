// The Mac's libc++ does not export basic_streambuf<char>::seekpos under the spelling the cross-compiled objects reference
// (their libc++ headers declare it through extern template). Explicitly instantiating the class here emits the
// definitions, including seekpos, in this archive member, so the executable binds to them. The bodies are the ones the
// open libc++ headers at the pinned LLVM commit define (see LLVM_PIN).
#include <streambuf>

template class std::basic_streambuf<char>;
