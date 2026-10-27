// Freed blocks that nothing points to go back to glibc: two million 1 KiB blocks allocated and freed (2 GB if none came
// back), while a linked list stays live; the peak resident size must stay small. A node that is unlinked and freed is
// not referenced any more (its neighbour's pointer was overwritten), so it is collected too.
// EXPECT: 0
#include <cstdio>
#include <cstdlib>
#include <cstring>
struct Node { Node *next; char pad[1000]; };
static long peak_kb() {
  FILE *f = std::fopen("/proc/self/status", "r");
  char line[256];
  long kb = -1;
  while (f && std::fgets(line, sizeof line, f))
    if (std::strncmp(line, "VmHWM:", 6) == 0) kb = std::atol(line + 6);
  if (f) std::fclose(f);
  return kb;
}
int main() {
  Node *head = nullptr;
  for (int i = 0; i < 1000; i++) { Node *n = new Node; n->next = head; head = n; }
  for (int i = 0; i < 2000000; i++) {
    Node *n = new Node;
    n->pad[0] = (char)i;
    n->next = head->next;   // insert after the head, then unlink and free it
    head->next = n;
    head->next = n->next;
    delete n;
  }
  long len = 0;
  for (Node *p = head; p; p = p->next) len++;
  if (len != 1000) return 1;
  long kb = peak_kb();
  if (kb < 0) return 2;
  if (kb > 512 * 1024) { std::printf("peak %ld KiB\n", kb); return 3; }
  return 0;
}
