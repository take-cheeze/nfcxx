import sys, decode_generic as g
for k in sys.argv[1:]:
    d = open("gen_%s_auto.bin" % k, "rb").read()
    r = g.decode(d)
    print(k, "bytes", sum(n for _, n in r), "of", len(d), "unknown", sum(n for t, n in r if t == "??"))
