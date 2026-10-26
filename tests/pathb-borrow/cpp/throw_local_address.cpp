// EXIT: 3
// DIAG: store into the exception object may escape a local address
// The exception object outlives the frame, so a local's address may not be thrown.
void throw_local_address() {
  int x = 1;
  throw &x;
}
