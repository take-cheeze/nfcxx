// A pointer operand of an asm statement whose value is a null pointer (the kernel's `cmpxchg_relaxed(&node->next, NULL,
// WAKE_Q_TAIL)`, __wake_q_add): the SSA emitter typed the null operand as the bare word `ptr`, which is no type, and
// refused the function ("type ptr").
struct node { struct node *next; };
#define TAIL ((struct node *)0x01)

__attribute__((noinline)) static int queue(struct node *n)
{
  struct node *ret;
  struct node *old = 0, *new = TAIL;
  asm volatile("lock cmpxchgq %2,%1" : "=a"(ret), "+m"(n->next) : "r"(new), "0"(old) : "memory");
  return ret == 0;   /* the node was free: it is queued now */
}

int main(void)
{
  struct node n = { 0 };
  int first = queue(&n);
  int second = queue(&n);
  return (first == 1 && second == 0 && n.next == TAIL) ? 5 : 1;
}
