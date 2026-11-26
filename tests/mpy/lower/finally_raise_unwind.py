# An exception raised in a finally body that a return ran is handled by the code around it, and an except inside a finally body
# handles its own exception. A raise out of the body of a finally that a return ran skips that finally.
log = []

def h2():
    try:
        return 'body'
    finally:
        try:
            raise KeyError('inner')
        except KeyError:
            log.append('handled')

def h3():
    r = []
    for i in range(2):
        try:
            try:
                r.append(i)
                return r
            finally:
                r.append('f')
        except KeyError:
            r.append('never')
    return r

def h4():
    try:
        return 'a'
    finally:
        try:
            raise ValueError('v')
        except ValueError as e:
            log.append(str(e))

def h7():
    try:
        try:
            return 'unused'
        finally:
            log.append('h7 finally')
            raise IndexError('from finally')
    except IndexError:
        return 'caught'

b = h2()
c = h3()
d = h4()
e = h7()
result = (b, c, d, e, log)
