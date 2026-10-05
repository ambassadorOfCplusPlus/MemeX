#!/usr/bin/env bash
# Level-1 rename: brand + binary only. llama-memex-fwd -> llama-skiff, brand "MemeX" banner -> "Skiff".
# Does NOT touch internals: namespace memex::, env vars MEMEX_*, dir examples/memex-fwd/, file memex-fwd.cpp,
# the other memex-* example dirs, memex_core. Those are level-3 and stay.
#
# RUN ONLY AFTER Phase-2 consolidation has merged into `memex` and you are on the memex checkout.
# Usage:  bash rename_engine_to_skiff.sh            # dry-run: list what would change
#         bash rename_engine_to_skiff.sh APPLY      # actually edit files
# After APPLY: rebuild under lock and run regress_tokens.ps1 (16/16) to prove nothing broke by name,
# then commit on memex.
set -o pipefail
R=/d/MemeX/src/ik_llama.cpp
B=/c/Users/User11/Desktop/MemeX
MODE="${1:-DRYRUN}"

OLD_BIN='llama-memex-fwd'
NEW_BIN='llama-skiff'

say(){ echo "[skiff-rename] $*"; }

# Files to touch: active scripts (*.ps1 *.sh), the engine CMakeLists, and memex-fwd.cpp (banner+usage).
# EXCLUDE: *.log (history), build*/ (generated), .git/, .claude/ worktrees.
mapfile -t ENGINE_SCRIPTS < <(find "$R/examples/memex-fwd" -maxdepth 1 -type f \( -name '*.ps1' -o -name '*.sh' \) 2>/dev/null)
CMAKE="$R/examples/memex-fwd/CMakeLists.txt"
CPP="$R/examples/memex-fwd/memex-fwd.cpp"
mapfile -t BENCH_SCRIPTS < <(find "$B/bench" -maxdepth 1 -type f \( -name '*.ps1' -o -name '*.sh' \) 2>/dev/null | grep -v '/rename_engine_to_skiff.sh$')

apply_bin_sub(){ # $1 = file : replace exe basename references
  [ -f "$1" ] || return 0
  grep -q "$OLD_BIN" "$1" || return 0
  if [ "$MODE" = "APPLY" ]; then sed -i "s/${OLD_BIN}/${NEW_BIN}/g" "$1"; fi
  echo "   $1"
}

say "mode=$MODE   $OLD_BIN -> $NEW_BIN"

say "1) CMake target (set(TARGET ...)):"
if [ -f "$CMAKE" ]; then
  grep -n "set(TARGET $OLD_BIN)" "$CMAKE" || echo "   (set(TARGET) line not found - check manually)"
  if [ "$MODE" = "APPLY" ]; then sed -i "s/set(TARGET ${OLD_BIN})/set(TARGET ${NEW_BIN})/" "$CMAKE"; fi
  # also any other exe mentions in comments of the CMake
  apply_bin_sub "$CMAKE"
fi

say "2) Brand banner + usage in memex-fwd.cpp (MemeX brand word -> Skiff, only the banner + top comment):"
if [ -f "$CPP" ]; then
  grep -n 'llama-memex-fwd (MemeX)' "$CPP" || echo "   (banner not found - check manually)"
  if [ "$MODE" = "APPLY" ]; then
    sed -i 's/llama-memex-fwd (MemeX)/llama-skiff (Skiff)/' "$CPP"      # identity banner :6404
    sed -i '1 s#^// MemeX computes#// Skiff computes#' "$CPP"            # top comment line 1
    sed -i "s/${OLD_BIN}/${NEW_BIN}/g" "$CPP"                           # remaining exe-name mentions (usage/help)
  fi
  echo "   $CPP"
  echo "   NOTE: left untouched on purpose (level-3, not brand): 'MemeX/cpp/...' path refs (zoned-cache msgs), namespace memex::, MEMEX_* env vars."
fi

say "3) Engine active scripts:"
for f in "${ENGINE_SCRIPTS[@]}"; do apply_bin_sub "$f"; done

say "4) Bench active scripts (Desktop repo) - logs/build artifacts EXCLUDED:"
for f in "${BENCH_SCRIPTS[@]}"; do apply_bin_sub "$f"; done

say "DONE ($MODE). Next (only after APPLY): rebuild under lock, regress_tokens.ps1 = 16/16, then commit."
if [ "$MODE" != "APPLY" ]; then say "This was a DRY-RUN. Re-run with 'APPLY' to edit."; fi
