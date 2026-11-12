#!/usr/bin/env bash
# test/notify_sh_test.sh -- report/notify.sh, no Oracle, no mail, no network.
# A mock sqlplus on PATH prints what report/alert_events.sql would, a mock
# mail command and a mock curl record what they were given. The wrapper runs
# in a temp copy of the repo, so reports/ in the checkout is untouched.
#   usage      no channel, bad flag values, a bad state file    -> exit 2, sqlplus never runs
#   selection  the flags reach report/alert_events.sql as its arguments
#   first run  no state file: after '-' and --since-hours; then the position
#   message    one message, events grouped by target, counts in the subject
#   state      written after every channel succeeded; unchanged after a
#              failed mail, a failed webhook, a failed query, a dry run
#   secret     the webhook URL (argument, file or environment) is in no
#              output line and no curl argument, also when curl prints it
#   content    quotes, pipes, ORA- text, backslashes and line breaks in a
#              message survive into the mail and into valid JSON
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/notify_test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/report" "$T/bin" "$T/out"
cp "$HERE/report/notify.sh" "$T/repo/report/"
chmod +x "$T/repo/report/notify.sh"

POS=2026111201030012300003
SECRET="https://hooks.example.com/services/T000/B000/s3cr3t-token"
TAB=$'\t'

# The escaped lines report/alert_events.sql prints: three events, two targets.
ev() { local IFS=$TAB; printf '%s\n' "$*"; }
{
    ev AWRCAP_EVENT 2026111201030012300002 2026-11-12T01:03:00Z NEW CRIT "" ALPHA 11 12 ALPHA/PDB1 TBSPC_FULL USERS "" \
       "TBSPC_FULL|11|12|USERS|-" "11|12|TBSPC_FULL|USERS|2026-11-12|-" \
       'Tablespace "USERS" | full in 12 days; last error: ORA-01653: unable to extend'
    ev AWRCAP_EVENT 2026111201030012300001 2026-11-12T01:03:00Z ESCALATED WARN INFO ALPHA 11 11 ALPHA CPU_ANOM BUSY_PCT TRAILING \
       "CPU_ANOM|11|11|BUSY_PCT|TRAILING" "11|11|CPU_ANOM|BUSY_PCT|2026-11-11|TRAILING" \
       'line one\nline two with back\\slash and <tag> & more'
    ev AWRCAP_EVENT 2026111201030012300003 2026-11-12T01:03:00Z REOPENED WARN WARN BETA 21 21 BETA DATA_STALE AWR_SNAPSHOT "" \
       "DATA_STALE|21|21|AWR_SNAPSHOT|-" "21|21|DATA_STALE|AWR_SNAPSHOT|2026-11-11|-" \
       'No AWR snapshot copied for BETA'
} > "$T/events.tsv"
ev AWRCAP_EVENT 2026111201030012300004 2026-11-12T01:03:00Z RESOLVED WARN WARN BETA 21 21 BETA TBSPC_FULL DATA "" \
   "TBSPC_FULL|21|21|DATA|-" "21|21|TBSPC_FULL|DATA|2026-11-10|-" 'Resolved: missing from 2 consecutive refresh runs' > "$T/resolved.tsv"

cat > "$T/bin/sqlplus" <<'MOCK'
#!/usr/bin/env bash
call=$(cat)
printf '%s\n' "$call" >> "$MOCK_DIR/sqlplus.calls"
t=$'\t'
begin() { printf 'AWRCAP_EVENTS_BEGIN\t%s\tCAPMON on CDB1/PDB1\t2026-11-12 01:05:00 +01:00\n' "$MOCK_POS"; }
case "${MOCK_MODE:-events}" in
    exit1)    echo "ORA-01435: user does not exist"; exit 1 ;;
    logora)   begin; echo "ORA-20003: no target named NOPE (see CAPR_TARGETS)"; printf 'AWRCAP_EVENTS_END\t0\n' ;;
    none)     begin; printf 'AWRCAP_EVENTS_END\t0\n' ;;
    noend)    begin; cat "$MOCK_DIR/events.tsv" ;;
    short)    begin; head -2 "$MOCK_DIR/events.tsv"; printf 'AWRCAP_EVENTS_END\t3\n' ;;
    resolved) begin; cat "$MOCK_DIR/events.tsv" "$MOCK_DIR/resolved.tsv"; printf 'AWRCAP_EVENTS_END\t4\n' ;;
    *)        begin; cat "$MOCK_DIR/events.tsv"; printf 'AWRCAP_EVENTS_END\t3\n' ;;
esac
exit 0
MOCK

cat > "$T/bin/mockmail" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_DIR/out/mail.args"
cat > "$MOCK_DIR/out/mail.body"
exit "${MOCK_MAIL_RC:-0}"
MOCK

cat > "$T/bin/mocksendmail" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_DIR/out/sendmail.args"
cat > "$MOCK_DIR/out/sendmail.msg"
MOCK

# curl: keeps its arguments, its config (stdin) and the posted body. On a
# failure it prints the URL, as a real curl can.
cat > "$T/bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$MOCK_DIR/out/curl.args"
cat > "$MOCK_DIR/out/curl.cfg"
url=$(sed -n 's/^url = "\(.*\)"$/\1/p' "$MOCK_DIR/out/curl.cfg")
data=$(sed -n 's/^data-binary = "@\(.*\)"$/\1/p' "$MOCK_DIR/out/curl.cfg")
[ -n "$data" ] && cp "$data" "$MOCK_DIR/out/curl.body"
if [ "${MOCK_CURL_RC:-0}" -ne 0 ]; then
    echo "curl: (22) The requested URL returned error: 500 for $url" >&2
    exit "$MOCK_CURL_RC"
fi
exit 0
MOCK
chmod +x "$T/bin/sqlplus" "$T/bin/mockmail" "$T/bin/mocksendmail" "$T/bin/curl"

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'; fails=$((fails+1)); }

# run <mock mode> [notify.sh args...]: output (stdout + stderr) in $out, exit in $rc.
# Environment for one run goes in RUN_ENV (an array of VAR=value).
RUN_ENV=()
run() {
    local mode="$1"; shift
    rm -f "$T/out"/* "$T/sqlplus.calls"
    out=$(cd "$T/repo" && env -u AWRCAP_WEBHOOK_URL -u AWRCAP_SENDMAIL_CMD PATH="$T/bin:$PATH" \
              MOCK_DIR="$T" MOCK_MODE="$mode" MOCK_POS="$POS" AWRCAP_MAIL_CMD="$T/bin/mockmail" \
              "${RUN_ENV[@]+"${RUN_ENV[@]}"}" report/notify.sh "/ as sysdba" "$@" 2>&1)
    rc=$?
    RUN_ENV=()
}
want_rc()   { [ "$rc" -eq "$2" ] && pass "$1 (exit $rc)" || fail "$1: exit $rc, wanted $2" "$out"; }
want_out()  { case "$out" in *"$2"*) pass "$1" ;; *) fail "$1: output lacks '$2'" "$out" ;; esac; }
want_file() { grep -q -F -- "$3" "$2" 2>/dev/null && pass "$1" || fail "$1: $2 lacks '$3'" "$(cat "$2" 2>/dev/null)"; }
want_call() { want_file "$1" "$T/sqlplus.calls" "$2"; }
no_call()   { [ ! -e "$T/sqlplus.calls" ] && pass "$1: sqlplus never ran" || fail "$1: sqlplus ran" "$(cat "$T/sqlplus.calls")"; }
no_secret() {
    if printf '%s' "$out" | grep -q -F -e "$SECRET" -e "s3cr3t" || grep -q -s -F "s3cr3t" "$T/out/curl.args" "$T/out/mail.args" "$T/out/mail.body"; then
        fail "$1: the webhook URL leaked" "$out"
    else
        pass "$1: the webhook URL is nowhere in the output or the arguments"
    fi
}
state_is()  {
    local have="(no file)"
    [ -e "$T/repo/reports/notify.state" ] && have=$(cat "$T/repo/reports/notify.state")
    [ "$have" = "$2" ] && pass "$1: state $2" || fail "$1: state is '$have', wanted '$2'"
}
reset_state() { rm -rf "$T/repo/reports"; }

bash -n "$HERE/report/notify.sh" && pass "bash -n" || fail "bash -n"

# ---- usage errors: exit 2 before sqlplus ----
run events;                                        want_rc "no channel" 2; want_out "no channel names the options" "no channel"; no_call "no channel"
run events --mail-to dba@example.com --min-severity HIGH;    want_rc "bad --min-severity" 2; no_call "bad --min-severity"
run events --mail-to dba@example.com --transitions NEW,GONE; want_rc "bad --transitions" 2; no_call "bad --transitions"
run events --mail-to dba@example.com --since-hours soon;     want_rc "bad --since-hours" 2
run events --mail-to "dba@example.com,-oops";                want_rc "bad --mail-to" 2
run events --mail-to dba@example.com --webhook-format xml;   want_rc "bad --webhook-format" 2
run events --mail-to dba@example.com --target 1cdb;          want_rc "bad --target" 2
run events --mail-to dba@example.com --target cdb1 --scope 5; want_rc "--target with a --scope dbid" 2
run events --webhook "ftp://x/s3cr3t";             want_rc "webhook URL that is not http(s)" 2; no_secret "bad webhook URL"; no_call "bad webhook URL"
run events "--webhook=$SECRET";                    want_rc "unknown argument" 2; no_secret "unknown argument holding a URL"
mkdir -p "$T/repo/reports"; echo "not a number" > "$T/repo/reports/notify.state"
run events --mail-to dba@example.com;              want_rc "state file without an event_id" 2; no_call "bad state file"
reset_state

# ---- selection flags reach the SQL script ----
run events --dry-run
want_call "defaults: first run, 24 hours, WARN, the three transitions" "@report/alert_events.sql - 24 WARN NEW,ESCALATED,REOPENED - -"
run events --dry-run --min-severity crit --transitions new,resolved --since-hours 48 --target cdb1 --scope -:5
want_call "--min-severity, --transitions, --since-hours, --target, --scope" "@report/alert_events.sql - 48 CRIT NEW,RESOLVED cdb1 5"
run events --dry-run --include-resolved --scope 42:43 --container PDB1 --schema CAPMON
want_call "--include-resolved, --scope D:C" "@report/alert_events.sql - 24 WARN NEW,ESCALATED,REOPENED,RESOLVED 42 43"
want_call "--container" "ALTER SESSION SET CONTAINER = PDB1;"
want_call "--schema" "ALTER SESSION SET CURRENT_SCHEMA = CAPMON;"

# ---- dry run: the message, nothing sent, nothing saved ----
RUN_ENV=("AWRCAP_WEBHOOK_URL=$SECRET")
run events --dry-run --mail-to dba@example.com
want_rc  "dry run" 0
want_out "dry run subject counts by severity" "Subject: AWRCAP alerts: 1 CRIT, 2 WARN (2 targets)"
want_out "dry run prints the body" "== ALPHA =="
want_out "dry run prints the webhook body" '"source":"awrcap"'
no_secret "dry run"
state_is "dry run" "(no file)"
[ ! -e "$T/out/mail.args" ] && [ ! -e "$T/out/curl.args" ] && pass "dry run sent nothing" || fail "dry run called a channel"

# ---- mail: one message, grouped by target ----
run events --mail-to dba@example.com,oncall@example.com
want_rc   "mail" 0
want_out  "mail reported" "OK   mail: 3 events to dba@example.com oncall@example.com"
want_file "mail subject" "$T/out/mail.args" "AWRCAP alerts: 1 CRIT, 2 WARN (2 targets)"
want_file "mail to the first address" "$T/out/mail.args" "dba@example.com"
want_file "mail to the second address" "$T/out/mail.args" "oncall@example.com"
want_file "mail keeps quotes, pipes and ORA- text" "$T/out/mail.body" 'Tablespace "USERS" | full in 12 days; last error: ORA-01653: unable to extend'
want_file "mail shows a line break as a blank and one backslash" "$T/out/mail.body" 'line one line two with back\slash and <tag> & more'
want_file "mail names the previous severity" "$T/out/mail.body" "WARN ESCALATED (was INFO)  CPU_ANOM  ALPHA  BUSY_PCT  TRAILING"
want_file "mail carries the state key" "$T/out/mail.body" "key TBSPC_FULL|11|12|USERS|-"
order=$(grep -n -E '^== |^(CRIT|WARN|--) ' "$T/out/mail.body" | sed 's/^[0-9]*://' | awk '{ printf "%s%s", (NR > 1 ? ";" : ""), $1 " " $2 }')
[ "$order" = "== ALPHA;CRIT NEW;WARN ESCALATED;== BETA;WARN REOPENED" ] \
    && pass "events grouped by target, one header each" || fail "grouping: got '$order'"
state_is "mail delivered" "$POS"

# ---- the next run asks after the saved position; nothing new keeps it ----
run none --mail-to dba@example.com
want_rc   "nothing to send" 0
want_out  "nothing to send says so" "nothing to send"
want_call "the saved position is the next run's start" "@report/alert_events.sql $POS 24 WARN"
state_is  "nothing to send" "$POS"
[ ! -e "$T/out/mail.args" ] && pass "nothing to send: no mail" || fail "nothing to send: mail was called"

# ---- first run with nothing in the window still records the position ----
reset_state
run none --mail-to dba@example.com
want_rc  "first run, nothing in the window" 0
state_is "first run, nothing in the window" "$POS"

# ---- a failed mail leaves the position ----
reset_state
RUN_ENV=("MOCK_MAIL_RC=1")
run events --mail-to dba@example.com
want_rc  "mail failed" 1
want_out "mail failure reported" "FAIL mail"
state_is "mail failed, first run" "(no file)"
mkdir -p "$T/repo/reports"; echo 2026111001000000000007 > "$T/repo/reports/notify.state"
RUN_ENV=("MOCK_MAIL_RC=1")
run events --mail-to dba@example.com
want_rc  "mail failed again" 1
state_is "mail failed, position kept" 2026111001000000000007
run events --mail-to dba@example.com
want_rc  "mail works again" 0
want_call "the retry starts at the kept position" "@report/alert_events.sql 2026111001000000000007 24"
state_is "the retry delivered" "$POS"

# ---- webhook, generic JSON, URL from the environment ----
reset_state
RUN_ENV=("AWRCAP_WEBHOOK_URL=$SECRET")
run events
want_rc   "webhook" 0
want_out  "webhook reported" "OK   webhook: 3 events (generic format)"
want_file "curl got the URL in its config" "$T/out/curl.cfg" "url = \"$SECRET\""
want_file "curl reads its config from stdin" "$T/out/curl.args" "--config"
no_secret "webhook"
state_is  "webhook delivered" "$POS"
if python3 - "$T/out/curl.body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ev = d["events"]
assert d["source"] == "awrcap" and d["position"] == "2026111201030012300003", d
assert d["subject"] == "AWRCAP alerts: 1 CRIT, 2 WARN (2 targets)", d["subject"]
assert d["counts"] == {"events": 3, "CRIT": 1, "WARN": 2, "INFO": 0, "resolved": 0, "targets": 2}, d["counts"]
assert [e["target"] for e in ev] == ["ALPHA", "ALPHA", "BETA"]
assert ev[0]["message"] == 'Tablespace "USERS" | full in 12 days; last error: ORA-01653: unable to extend', ev[0]["message"]
assert ev[1]["message"] == 'line one\nline two with back\\slash and <tag> & more', ev[1]["message"]
assert ev[0]["event_id"] == "2026111201030012300002" and ev[0]["dbid"] == 11 and ev[0]["con_dbid"] == 12
assert ev[0]["prev_severity"] is None and ev[1]["prev_severity"] == "INFO" and ev[0]["baseline_mode"] is None
assert ev[1]["baseline_mode"] == "TRAILING" and ev[0]["at_time"] == "2026-11-12T01:03:00Z"
assert "== ALPHA ==" in d["text"] and 'back\\slash' in d["text"]
PY
then pass "generic body is valid JSON with every field"; else fail "generic JSON body" "$(cat "$T/out/curl.body")"; fi

# ---- slack format, URL from a file ----
reset_state
printf '%s\n' "$SECRET" > "$T/hook.url"
run events --webhook-file "$T/hook.url" --webhook-format slack
want_rc   "slack format" 0
want_file "URL read from the file" "$T/out/curl.cfg" "url = \"$SECRET\""
no_secret "webhook file"
if python3 - "$T/out/curl.body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert list(d) == ["text"], list(d)
t = d["text"]
assert t.startswith("AWRCAP alerts: 1 CRIT, 2 WARN (2 targets)\n"), t[:80]
assert "&lt;tag&gt; &amp; more" in t and 'Tablespace "USERS" | full' in t and "== BETA ==" in t, t
PY
then pass "slack body is {\"text\": ...} with &, <, > escaped"; else fail "slack JSON body" "$(cat "$T/out/curl.body")"; fi

# ---- a failed webhook: no position, no URL in the error, mail is repeated ----
reset_state
RUN_ENV=("MOCK_CURL_RC=22")
run events --mail-to dba@example.com --webhook "$SECRET"
want_rc   "webhook failed" 1
want_out  "mail went out before the webhook failed" "OK   mail"
want_out  "webhook failure reported" "FAIL webhook: curl exit 22"
want_out  "curl's own message is kept, the URL cut out" "returned error: 500 for <webhook URL>"
no_secret "webhook failed"
state_is  "webhook failed" "(no file)"
run events --mail-to dba@example.com --webhook "$SECRET"
want_rc   "both channels" 0
state_is  "both channels delivered" "$POS"

# ---- sendmail style ----
reset_state
RUN_ENV=("AWRCAP_MAIL_CMD=" "AWRCAP_SENDMAIL_CMD=$T/bin/mocksendmail -t")
run events --mail-to dba@example.com,oncall@example.com
want_rc   "sendmail style" 0
want_file "sendmail gets its own arguments" "$T/out/sendmail.args" "-t"
want_file "sendmail To header" "$T/out/sendmail.msg" "To: dba@example.com,oncall@example.com"
want_file "sendmail Subject header" "$T/out/sendmail.msg" "Subject: AWRCAP alerts: 1 CRIT, 2 WARN (2 targets)"
want_file "sendmail body" "$T/out/sendmail.msg" "== ALPHA =="

# ---- resolved events are counted apart ----
reset_state
run resolved --mail-to dba@example.com --include-resolved
want_rc   "with a RESOLVED event" 0
want_file "subject counts resolved apart" "$T/out/mail.args" "AWRCAP alerts: 1 CRIT, 2 WARN, 1 resolved (2 targets)"
want_file "a resolved line carries no severity" "$T/out/mail.body" "--   RESOLVED (was WARN)  TBSPC_FULL  BETA  DATA"

# ---- a failed or incomplete query: exit 1, no state ----
reset_state
run exit1  --mail-to dba@example.com; want_rc "sqlplus exit 1" 1;          want_out "sqlplus error shown" "ORA-01435"
run logora --mail-to dba@example.com; want_rc "ORA- line in the output" 1; want_out "ORA- line shown" "ORA-20003"
run noend  --mail-to dba@example.com; want_rc "no END line" 1;             want_out "incomplete output named" "incomplete output"
run short  --mail-to dba@example.com; want_rc "END count differs" 1;       want_out "incomplete output named again" "incomplete output"
state_is "failed queries" "(no file)"
[ ! -e "$T/out/mail.args" ] && pass "failed queries: no mail" || fail "failed queries: mail was called"

if [ $fails -eq 0 ]; then
    echo "notify.sh test: all passed"
else
    echo "notify.sh test: $fails failed"
    exit 1
fi
