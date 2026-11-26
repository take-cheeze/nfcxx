# A break out of a finally body in a loop over a range. The finally's pending value is dropped on the way out (the VM cancels the
# finally it leaves), so the loop's exit sees the counter alone, as on the normal path. A range loop has no iterator to drop.
def f():
    out = []
    for i in range(4):
        try:
            out.append(i)
        finally:
            if i == 1:
                break
    out.append('end')
    return out

log = []

def g():
    out = []
    for i in range(3):
        try:
            log.append(i)
        finally:
            out.append(i)
            if i == 1:
                break
    return out

result = (f(), g(), log)
