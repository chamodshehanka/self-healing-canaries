# Shared helpers. Source me.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "$ROOT/demo.env"; set +a

KSTG=(--context kind-staging)
KPRD=(--context kind-prod)

c_b=$'\033[1m'; c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_c=$'\033[36m'; c_0=$'\033[0m'
say()  { printf '%s==>%s %s\n' "$c_c" "$c_0" "$*"; }
ok()   { printf '%s ✔ %s %s\n' "$c_g" "$*" "$c_0"; }
warn() { printf '%s ! %s %s\n' "$c_y" "$*" "$c_0"; }
die()  { printf '%s ✘ %s %s\n' "$c_r" "$*" "$c_0" >&2; exit 1; }
need() { for t in "$@"; do command -v "$t" >/dev/null || die "missing tool: $t"; done; }

# Presenter pause: press Enter to continue (skip with NO_PAUSE=1).
beat() { printf '\n%s▶ %s%s\n' "$c_b" "$*" "$c_0"; [[ "${NO_PAUSE:-0}" == 1 ]] || read -r -p "  [enter] " _; }

# render FILE: substitute ${UPPER_CASE} vars that are set in the environment; leave everything else.
render() { perl -pe 's/\$\{([A-Z][A-Z0-9_]*)\}/defined $ENV{$1} ? $ENV{$1} : $&/ge' "$1"; }

node_ip() { docker inspect -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}' "$1-control-plane"; }

kctx() { echo "kind-$1"; }
