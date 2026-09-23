# Gemeinsame Helfer für die Akzeptanz-Checks.
set -uo pipefail
CTX="kind-${KIND_CLUSTER_NAME:-korifi}"
K="kubectl --context $CTX"
FAILED=0
pass() { printf "  \033[32mOK\033[0m    %s\n" "$1"; }
fail() { printf "  \033[31mFEHL\033[0m  %s\n" "$1"; [ $# -gt 1 ] && printf "        %s\n" "$2"; FAILED=1; }
check() { # check "Beschreibung" "erwartet" "befehl"
  local desc="$1" want="$2" cmd="$3" got
  got=$(eval "$cmd" 2>&1 | tr -d '\r')
  if [ "$got" = "$want" ]; then pass "$desc"; else fail "$desc" "erwartet '$want', erhalten '$got'"; fi
}
contains() { # contains "Beschreibung" "teilstring" "befehl"
  local desc="$1" want="$2" cmd="$3" got
  got=$(eval "$cmd" 2>&1)
  if printf '%s' "$got" | grep -qF -- "$want"; then pass "$desc"; else fail "$desc" "'$want' nicht gefunden"; fi
}
# Ein Check, der unter der laufenden CNI nichts aussagt, darf weder gruen noch
# rot melden - beides waere eine Behauptung ueber etwas Ungeprueftes.
skip() { printf "  \033[33m--\033[0m    %s\n" "$1"; [ $# -gt 1 ] && printf "        %s\n" "$2"; return 0; }

finish() { [ "$FAILED" = "0" ] && echo "  -> alle Checks grün" || { echo "  -> FEHLGESCHLAGEN"; exit 1; }; }
