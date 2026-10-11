// Tier 0 borrow facts at jumps (docs/notes/borrowck-plan.md section 1.3): a continue, a break (a goto to the label after the
// loop), and a goto each close the locals they leave, as (scope-end) before the jump. The locals still open at the target
// stay open. The golden borrow/borrow_exits.ir is printed with NFCXX_PATHB_BORROW=1 by tests/pathb-ir/run.sh.
struct Own {
  int *p;
  Own(int v);
  ~Own();
};

int loop_exits(int n) {
  int total = 0;
  for (int i = 0; i < n; i++) {
    Own a(i);
    if (i == 2) continue;  // closes a, the body block still ends after the label
    if (i == 5) break;     // closes a, i stays open (the label after the loop is in its block)
    total += i;
  }
  while (n > 0) {
    Own b(n);
    n--;
    if (n == 3) goto done;  // closes b, the label done is outside the loop
  }
done:
  return total;
}

int goto_exits(int n) {
  int acc = 0;
retry:
  Own x(n);
  {
    Own y(acc);
    if (acc > 9) goto retry;  // a backward goto closes y and x: both are declared after the label
    {
      Own z(1);
      if (acc == 4) goto out;  // a forward goto out of two blocks closes z and y; x stays open at out
    }
  }
out:
  for (int i = 0; i < n; i++) {
    Own w(i);
    if (i == 1) continue;
    switch (i) {
      case 2: { Own q(i); break; }  // a break out of a switch closes q
      default: acc++;
    }
  }
  return acc;
}
