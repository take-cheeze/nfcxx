import re,sys
test=open(sys.argv[1]).read()
ours=open(sys.argv[2]).read()
def func_block(s):
    i=s.index("llvm.func @generated_0")
    j=s.index("\n    }\n", i)+len("\n    }\n")
    # start of the line containing llvm.func
    k=s.rfind("\n",0,i)+1
    return k,j
tk,tj=func_block(test)
ok,oj=func_block(ours)
out=test[:tk]+ours[ok:oj]+test[tj:]
open(sys.argv[3],"w").write(out)
print("spliced",len(out))
