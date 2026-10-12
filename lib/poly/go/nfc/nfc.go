// Package nfc holds the types a Go script sees from the nfcpoly bridge (lib/poly/nfcpoly_go.cpp). They are compiled
// types exported to the interpreter as the package "nfc", which every script can use without importing it.
package nfc

// Obj is the Go side of one C++ object of a registered class. The wrapper types that the backend generates for a class
// (`type Vec3 struct{ H *nfc.Obj }`) hold one; the C++ object is released when the wrapper becomes garbage.
type Obj struct {
	ID    uint64 // key in the host's object table
	Class uint32 // the backend's number of the class
}

// Error is an error raised by the binding layer into a script as a panic: a bound function was given a value of the
// wrong type (Class "TypeError"), a host function was called from a goroutine ("GoroutineError"), a read-only variable
// was written ("ReadOnlyError"), and so on. A recovered value is a *Error; Error() is the message.
type Error struct {
	Class string
	Msg   string
}

func (e *Error) Error() string { return e.Msg }

// HostError is a C++ exception that a bound function threw. A script can recover it as an ordinary error; when nothing
// recovers it, the host rethrows the original C++ exception (same type and payload). ID names the host's
// std::exception_ptr.
type HostError struct {
	Msg string
	ID  uint64
}

func (e *HostError) Error() string { return e.Msg }
