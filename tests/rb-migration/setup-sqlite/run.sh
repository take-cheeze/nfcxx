#!/bin/bash
# Differential test: scripts/setup-sqlite.rb against scripts/setup-sqlite.sh (see ../fetch-build/common.sh). The release zip is
# a fixture (a zip of two small files): the script's SHA-256 pins are replaced by the fixture's hashes in both copies, so the
# download, the check, the unzip, the build and the manifest run as they do for the real release. Nothing is downloaded.
here=$(cd "$(dirname "$0")" && pwd -P)
RBM_NAME=setup-sqlite
. "$here/../fetch-build/common.sh"

URL=https://sqlite.org/2026/sqlite-amalgamation-3540100.zip
URL_KEY=$(printf '%s' "$URL" | sed 's#[^A-Za-z0-9._-]#_#g')
OLD_ZIP=0a9c8e34352dad46006aa82836d5383bff9dc6bc9ce5a60553c05aa30e6ad1f9
OLD_C=0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52

# the fixture amalgamation, made once: its files, the zip and the hashes the pins become
FIX=$RBM_OUT/fixtures
mkdir -p "$FIX/tree/sqlite-amalgamation-3540100"
printf '/* a fake amalgamation */\nint sqlite3_fake(void) { return 1; }\n' > "$FIX/tree/sqlite-amalgamation-3540100/sqlite3.c"
printf '#ifndef SQLITE3_H\n#define SQLITE3_H\n#define SQLITE_VERSION "3.54.1"\n#define SQLITE_VERSION_NUMBER 3054001\n#endif\n' \
  > "$FIX/tree/sqlite-amalgamation-3540100/sqlite3.h"
(cd "$FIX/tree" && zip -qrX "$FIX/amalgamation.zip" sqlite-amalgamation-3540100)
ZIP_SHA=$(sha256sum "$FIX/amalgamation.zip" | cut -d' ' -f1)
C_SHA=$(sha256sum "$FIX/tree/sqlite-amalgamation-3540100/sqlite3.c" | cut -d' ' -f1)

# the pins become the fixture's, in both copies of the sandbox
pins() {
  sed -i "s/$OLD_ZIP/$ZIP_SHA/; s/$OLD_C/$C_SHA/" "$SB/repo/scripts/setup-sqlite.sh" "$SB/repo/scripts/setup-sqlite.rb"
  mkdir -p "$SB/fix/urls" "$SB/fix/tree"
  cp -r "$FIX/tree/." "$SB/fix/tree/"
  # unzip -q ZIP -d DIR: the fixture's files
  cat > "$SB/hooks/unzip" <<'H'
#!/bin/bash
d=${*: -1}
mkdir -p "$d" && cp -r "$NFCXX_STUB_FIX/tree/." "$d/"
H
  chmod +x "$SB/hooks/unzip"
}
serve_zip() { pins; cp "$FIX/amalgamation.zip" "$SB/fix/urls/$URL_KEY"; }
setup_zip() { serve_zip; }
setup_none() { pins; }                      # the download fails: curl has no fixture for the URL
setup_cached() {                            # sqlite3.c is there with the pinned hash: no download
  pins
  mkdir -p "$SB/repo/build/sqlite/src"
  cp "$FIX/tree/sqlite-amalgamation-3540100/sqlite3.c" "$FIX/tree/sqlite-amalgamation-3540100/sqlite3.h" "$SB/repo/build/sqlite/src/"
}
setup_stale() {                             # sqlite3.c with another hash: downloaded again
  serve_zip
  mkdir -p "$SB/repo/build/sqlite/src"
  echo stale > "$SB/repo/build/sqlite/src/sqlite3.c"
}
setup_bad_zip() {                           # the served zip is not the pinned one
  pins
  echo "not a zip" > "$SB/fix/urls/$URL_KEY"
}
setup_nfcc_fails() { serve_zip; printf '#!/bin/bash\nexit 3\n' > "$SB/hooks/nfcc"; chmod +x "$SB/hooks/nfcc"; }
setup_unzip_fails() { serve_zip; printf '#!/bin/bash\nexit 9\n' > "$SB/hooks/unzip"; chmod +x "$SB/hooks/unzip"; }

rbm_case default-backend setup_zip ""
rbm_case backend-gcc setup_zip "NFCXX_BACKEND=gcc"
rbm_case backend-empty setup_zip "NFCXX_BACKEND="
rbm_case backend-qbe setup_zip "NFCXX_BACKEND=qbe"
rbm_case cached-no-download setup_cached ""
rbm_case stale-download setup_stale ""
rbm_case download-fails setup_none ""
rbm_case zip-sha-mismatch setup_bad_zip ""
rbm_case nfcc-fails setup_nfcc_fails ""
rbm_case unzip-fails setup_unzip_fails ""
rbm_summary
