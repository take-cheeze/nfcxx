# Prints the gcc define options for one gem from corpus_flags.json: --define NAME[=VALUE] as -DNAME[=VALUE], --undefine NAME as -UNAME.
import json, sys
flags = json.load(open(sys.argv[1])).get(sys.argv[2], [])
out = []
i = 0
while i < len(flags):
    if flags[i] == '--define' and i + 1 < len(flags):
        out.append('-D' + flags[i + 1]); i += 2
    elif flags[i] == '--undefine' and i + 1 < len(flags):
        out.append('-U' + flags[i + 1]); i += 2
    else:
        i += 1
print(' '.join(out))
