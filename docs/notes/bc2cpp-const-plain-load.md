# Constant reads as plain loads: measured, not adopted

Every compiled constant read goes through the constant cache (`CONST_SITE_CACHE`, `const_site_cache.rb`):

```c++
return !mrb_nil_p(bc2cpp_cconst_slots[i]) ? bc2cpp_cconst_slots[i] : bc2cpp_cconst_fill(M, i);
```

The idea was to fill every slot once at the end of `bc2cpp_gem_init` and emit a bare `bc2cpp_cconst_slots[i]` load at
sites that cannot run before that. It was built (nfcxx branch `claude/const-plain-load-q7z2`, df12c54; rpg world branch
`claude/const-plain-load-world-q7z2`) and measured, then dropped: it saves too little to be worth the soundness rule.

## Wio Terminal result

World: rpg-maker-clone closed build, `scripts/wio/build.bash`, both builds from one tree.

| Build | Internal flash | QSPI | RAM | ELF text |
| --- | ---: | ---: | ---: | ---: |
| Cached reads (5,296 checked sites) | 456,328 B | 983,732 B | 33,324 B | 1,440,020 |
| All 5,492 sites plain (unsound, measurement only) | -1,888 B | -2,156 B | 0 | -4,036 |

About 0.75 B per removed check. Under `-Os` with LTO the nil test is already one compare and a branch to a shared cold
call, so the 8.5 B per arm measured for nil arms elsewhere does not apply here. About 4 KB is the ceiling for any sound
version.

## Why a sound version reaches almost none of it

A site may be plain only if it never runs before the prefill. Which code can run during gem init is a name-based
closure: class bodies, root statements, protocol names (`initialize` included) and every name native code spells, then
every owner of every name those bodies send. Init code constructs objects, so every `initialize` is reached, and from
there common names (`update`, `dispose`, `[]`, `refresh`) reach nearly everything: 3,556 of 4,304 iseqs, including
2,167 of 2,197 mruby-rpg2k methods. The core gem's methods run from `mrb_open_core` on. Slots whose binding init does
not provably make (conditional or rescue-guarded bindings, call results, bindings made by a later gem or from C) stay
cached too. About 125 rgss sites were left plain.

A class-aware init-time call graph would admit more sites, but it is still capped at the 4 KB above.
