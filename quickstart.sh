#!/usr/bin/env bash
# quickstart.sh -- this database as its own target, the suite, a first report,
# in one command.
#
#   ./quickstart.sh                              # sqlplus / as sysdba (CDB$ROOT)
#   ./quickstart.sh 'sys/pw@//host/svc as sysdba'  # any SYSDBA connect sqlplus accepts
#
# Optional environment, passed to quickstart.sql as DEFINEs:
#   CAP_OWNER         the suite owner (default AWRCAP, in the PDB)
#   CAP_READER        the read-only reader (default C##AWRRDR; AWRRDR in a non-CDB)
#   CAP_CONTAINER     the PDB the suite lives in (default: the one open PDB)
#   CAP_SELF_CONNECT  the loopback link's address (default
#                     //localhost:<listener port>/<the root's default service>)
#
# Needs sqlplus on PATH (source oraenv first on the DB host) and a SYSDBA
# connection: it creates the reader and a schema-only owner and installs into
# that owner, never into SYS. Runs from the repo directory regardless of
# where you call it from, because the SQL*Plus @@ includes resolve relative to
# the outermost script. Exits non-zero if doctor.sql reports a FAIL or a step
# fails.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

command -v sqlplus >/dev/null 2>&1 || {
  echo "quickstart: sqlplus not found on PATH (on the DB host: . oraenv)" >&2
  exit 1
}
mkdir -p reports

defs=""
define() {   # define NAME VALUE PATTERN WHAT
  [[ -z $2 ]] && return 0
  [[ $2 =~ $3 ]] || { echo "quickstart: $4" >&2; exit 2; }
  defs+="DEFINE $1 = '$2'"$'\n'
}
name='^[A-Za-z][A-Za-z0-9_$#]{0,127}$'
define owner        "${CAP_OWNER:-}"        "$name"        "CAP_OWNER must be a plain SQL name"
define reader       "${CAP_READER:-}"       "$name"        "CAP_READER must be a plain SQL name"
define container    "${CAP_CONTAINER:-}"    "$name"        "CAP_CONTAINER must be a plain SQL name"
define self_connect "${CAP_SELF_CONNECT:-}" "^[^\"'&]+$"   "CAP_SELF_CONNECT may not contain quotes or &"

[[ $# -eq 0 ]] && set -- / as sysdba
printf '%s@quickstart.sql\nEXIT\n' "$defs" | sqlplus -S -L "$@"
