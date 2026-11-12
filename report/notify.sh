#!/usr/bin/env bash
#
# report/notify.sh -- deliver new alert state changes by mail and / or webhook (cron).
# =====================================================================
# Reads the alert events cap_results.refresh recorded (CAP_ALERT_EVENT, through
# report/alert_events.sql) after the position of the last delivery, and sends
# ONE message that lists them grouped by target: a mail through the local MTA
# and / or a JSON POST to a webhook. The position (an event_id) is kept in a
# state file and moves only after every channel accepted the message, so an
# event is delivered once: a failed delivery leaves the position, exits
# non-zero (cron reports it) and the next run sends the same events again.
# Read-only against the database. Nothing is sent from inside the database.
#
# Usage:
#   report/notify.sh [connect] [--mail-to ADDR[,ADDR]] [--webhook URL] [--webhook-file FILE]
#                    [--webhook-format generic|slack] [--min-severity INFO|WARN|CRIT]
#                    [--transitions LIST] [--include-resolved] [--scope dbid[:con_dbid]]
#                    [--target NAME] [--since-hours N] [--state-file FILE] [--dry-run]
#                    [--container PDB] [--schema OWNER]
#     connect             sqlplus connect string, default "/ as sysdba" (quote it)
#     --mail-to A[,B]     mail the message to these addresses
#     --webhook URL       POST the message as JSON to this URL. The URL is
#                         often a secret: prefer --webhook-file or the
#                         environment variable AWRCAP_WEBHOOK_URL, which keep it
#                         off the command line. It is never printed or logged.
#     --webhook-file F    read the webhook URL from the first line of F
#     --webhook-format X  generic (default): {"subject", "text", "counts",
#                         "events": [...]}. slack: {"text": "..."} only, for
#                         Slack and other endpoints that take that shape.
#     --min-severity S    INFO, WARN (default) or CRIT: events whose severity,
#                         or previous severity, is at least S
#     --transitions LIST  comma list of NEW, ESCALATED, DEESCALATED, RESOLVED,
#                         REOPENED (default NEW,ESCALATED,REOPENED)
#     --include-resolved  add RESOLVED to the transitions
#     --scope D[:C]       only dbid D (and con_dbid C); C alone: --scope -:C
#     --target NAME       only target NAME (as run_report.sh; unknown = failure)
#     --since-hours N     without a state file (the first run): only events of
#                         the last N hours (default 24), so a new job does not
#                         send the whole history. Ignored once a position exists.
#     --state-file F      where the position is kept (default
#                         reports/notify.state; a relative path is relative to
#                         the suite's directory). One file per job: two jobs
#                         with different selections or channels need two files.
#                         Where flock exists, <F>.lock keeps two runs of one
#                         job apart (the second exits 1).
#     --dry-run           print the message (and the JSON body) and change
#                         nothing: nothing sent, no state file written
#     --container P       ALTER SESSION SET CONTAINER = P first (SYSDBA runs)
#     --schema O          ALTER SESSION SET CURRENT_SCHEMA = O first
#
# Environment:
#   AWRCAP_WEBHOOK_URL    the webhook URL (when neither --webhook nor --webhook-file)
#   AWRCAP_MAIL_CMD       a mailx-style command, called as
#                         <cmd> -s <subject> <addr>... with the body on stdin.
#                         Default: mailx, else mail, when one is on PATH.
#   AWRCAP_SENDMAIL_CMD   a sendmail-style command that reads a whole message
#                         (headers included) on stdin, e.g. "/usr/sbin/sendmail -t".
#                         Default when no mailx / mail exists: sendmail -t.
#   AWRCAP_CURL_CMD       the curl command (default curl)
#
# Exit: 0 delivered, or nothing to send; 1 the query or a delivery failed (the
# position did not move); 2 a usage or setup error (nothing was run).
# With two channels the position moves only when both succeeded, so a failing
# webhook repeats the mail on the next run. Run one job per channel, each with
# its own --state-file, to keep them independent.
#
# Cron example (hourly at :20, after the nightly refresh and any refresh in
# between; environment from the oracle user's profile):
#   20 * * * * . /home/oracle/.bash_profile; AWRCAP_WEBHOOK_URL="$(cat /home/oracle/.awrcap_webhook)" /opt/awrcap/report/notify.sh "/ as sysdba" --container PDB1 --schema AWRCAP --mail-to dba@example.com --webhook-format slack >> /var/log/awrcap_notify.log 2>&1
#
set -u
err_re='^(ORA|SP2)-[0-9]{4,5}'
me="notify.sh"

cd "$(dirname "$0")/.." || exit 2

conn="/ as sysdba"
mail_to=""
hook="${AWRCAP_WEBHOOK_URL:-}"
hook_file=""
hook_arg=""
hook_fmt="generic"
min_sev="WARN"
trans="NEW,ESCALATED,REOPENED"
with_resolved=0
sdbid="-"
scon="-"
target=""
has_target=0
since="24"
state="reports/notify.state"
dry=0
container=""
schema=""

die() { echo "$me: $*" >&2; exit 2; }

if [ $# -gt 0 ] && [ "${1#--}" = "$1" ] && [ "$1" != "-h" ]; then
    conn="$1"
    shift
fi
while [ $# -gt 0 ]; do
    case "$1" in
        --mail-to)          shift; mail_to="${1:-}";   [ -n "$mail_to" ]   || die "--mail-to wants an address" ;;
        --webhook)          shift; hook_arg="${1:-}";  [ -n "$hook_arg" ]  || die "--webhook wants a URL" ;;
        --webhook-file)     shift; hook_file="${1:-}"; [ -n "$hook_file" ] || die "--webhook-file wants a file" ;;
        --webhook-format)   shift; hook_fmt="${1:-}" ;;
        --min-severity)     shift; min_sev="${1:-}" ;;
        --transitions)      shift; trans="${1:-}" ;;
        --include-resolved) with_resolved=1 ;;
        --scope)            shift
                            a="${1:-}"
                            sdbid="${a%%:*}"
                            case "$a" in *:*) scon="${a#*:}" ;; esac ;;
        --target)           shift; target="${1:-}"; has_target=1 ;;
        --since-hours)      shift; since="${1:-}" ;;
        --state-file)       shift; state="${1:-}";     [ -n "$state" ]     || die "--state-file wants a file" ;;
        --dry-run)          dry=1 ;;
        --container)        shift; container="${1:-}" ;;
        --schema)           shift; schema="${1:-}" ;;
        -h|--help)          awk 'NR > 1 { if (!/^#/) exit; print }' "$0"; exit 0 ;;
        *)                  a="${1%%=*}"
                            # a mistyped webhook option must not put its URL in a log
                            case "$1" in *://*) a="${a%%://*}://..." ;; esac
                            die "unknown argument '$a'" ;;
    esac
    shift
done

# ---- validate: everything that reaches SQL*Plus is checked here ----
for v in "$sdbid" "$scon"; do
    case "$v" in -|'') ;; *[!0-9]*) die "--scope wants digits, got '$v'" ;; esac
done
[ -z "$sdbid" ] && sdbid="-"
[ -z "$scon" ] && scon="-"
if [ $has_target -eq 1 ]; then
    [[ "$target" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || die "--target wants a target name (a letter, then letters, digits or _), got '$target'"
    [ "$sdbid" = "-" ] || die "--target and a --scope dbid both name the database; use --scope -:C with --target"
    sdbid="$target"
fi
case "$container$schema" in *[!A-Za-z0-9_\$#]*) die "bad --container / --schema name" ;; esac
min_sev=$(printf '%s' "$min_sev" | tr '[:lower:]' '[:upper:]')
case "$min_sev" in INFO|WARN|CRIT) ;; *) die "--min-severity wants INFO, WARN or CRIT, got '$min_sev'" ;; esac
trans=$(printf '%s' "$trans" | tr '[:lower:]' '[:upper:]')
[ $with_resolved -eq 1 ] && case ",$trans," in *,RESOLVED,*) ;; *) trans="$trans,RESOLVED" ;; esac
[ -n "$trans" ] || die "--transitions wants a list"
case "$trans" in ,*|*,|*,,*|*[!A-Z,]*) die "--transitions wants a comma list of NEW, ESCALATED, DEESCALATED, RESOLVED, REOPENED" ;; esac
IFS=, read -r -a parts <<< "$trans"
for t in "${parts[@]}"; do
    case "$t" in
        NEW|ESCALATED|DEESCALATED|RESOLVED|REOPENED) ;;
        *) die "--transitions wants a comma list of NEW, ESCALATED, DEESCALATED, RESOLVED, REOPENED, got '$t'" ;;
    esac
done
case "$since" in ''|*[!0-9]*) die "--since-hours wants a number" ;; esac
[ ${#since} -le 6 ] || die "--since-hours is too large"
case "$hook_fmt" in generic|slack) ;; *) die "--webhook-format wants generic or slack, got '$hook_fmt'" ;; esac

# The webhook URL: --webhook, else --webhook-file, else AWRCAP_WEBHOOK_URL.
# No message below ever contains it.
if [ -n "$hook_arg" ]; then
    hook="$hook_arg"
elif [ -n "$hook_file" ]; then
    [ -r "$hook_file" ] || die "cannot read the --webhook-file"
    IFS= read -r hook < "$hook_file" || [ -n "$hook" ] || die "the --webhook-file is empty"
fi
hook="${hook%$'\r'}"
if [ -n "$hook" ]; then
    case "$hook" in
        *[[:space:]]*|*[[:cntrl:]]*) die "the webhook URL contains a blank or a control character" ;;
        http://?*|https://?*) ;;
        *) die "the webhook URL must start with http:// or https://" ;;
    esac
fi

addrs=()
if [ -n "$mail_to" ]; then
    case "$mail_to" in ,*|*,|*,,*) die "--mail-to wants ADDR[,ADDR]" ;; esac
    IFS=, read -r -a addrs <<< "$mail_to"
    for a in "${addrs[@]}"; do
        [[ "$a" =~ ^[A-Za-z0-9_][A-Za-z0-9._%+@-]*$ ]] || die "--mail-to: bad address '$a'"
    done
fi

if [ $dry -eq 0 ] && [ ${#addrs[@]} -eq 0 ] && [ -z "$hook" ]; then
    die "no channel: give --mail-to and / or a webhook (--webhook, --webhook-file, AWRCAP_WEBHOOK_URL), or --dry-run"
fi

# How mail leaves: mailx style (-s subject, addresses, body on stdin) or
# sendmail style (a whole message on stdin).
mail_style=""
mail_cmd=""
if [ ${#addrs[@]} -gt 0 ]; then
    if [ -n "${AWRCAP_MAIL_CMD:-}" ]; then
        mail_style="mailx"; mail_cmd="$AWRCAP_MAIL_CMD"
    elif [ -n "${AWRCAP_SENDMAIL_CMD:-}" ]; then
        mail_style="sendmail"; mail_cmd="$AWRCAP_SENDMAIL_CMD"
    elif command -v mailx >/dev/null 2>&1; then
        mail_style="mailx"; mail_cmd="mailx"
    elif command -v mail >/dev/null 2>&1; then
        mail_style="mailx"; mail_cmd="mail"
    else
        for c in sendmail /usr/sbin/sendmail /usr/lib/sendmail; do
            if command -v "$c" >/dev/null 2>&1; then mail_style="sendmail"; mail_cmd="$c -t"; break; fi
        done
    fi
    [ -n "$mail_cmd" ] || [ $dry -eq 1 ] || die "no mail command: install mailx or sendmail, or set AWRCAP_MAIL_CMD / AWRCAP_SENDMAIL_CMD"
fi
curl_cmd="${AWRCAP_CURL_CMD:-curl}"
if [ -n "$hook" ] && [ $dry -eq 0 ]; then
    command -v "${curl_cmd%% *}" >/dev/null 2>&1 || die "curl not on PATH (or set AWRCAP_CURL_CMD)"
fi

command -v sqlplus >/dev/null 2>&1 || die "sqlplus not on PATH"

# ---- the position of the last delivery ----
after="-"
if [ -e "$state" ]; then
    IFS= read -r after < "$state" || true
    [[ "$after" =~ ^[0-9]{1,30}$ ]] || die "the state file $state does not hold an event_id; remove it to start over"
fi
last="$after"
[ "$after" = "-" ] && last="none, the first run"
if [ $dry -eq 0 ]; then
    mkdir -p "$(dirname "$state")" || die "cannot create the directory of $state"
    # One run per state file: a second one would send the same events.
    if command -v flock >/dev/null 2>&1; then
        exec 9>>"$state.lock" || die "cannot write $state.lock"
        flock -n 9 || { echo "$me: another run holds $state.lock" >&2; exit 1; }
    fi
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/awrcap_notify.XXXXXX")" || die "cannot create a temporary directory"
trap 'rm -rf "$tmp"' EXIT
log="$tmp/sqlplus.log"
ev="$tmp/events.tsv"
body="$tmp/body.txt"
payload="$tmp/payload.json"

pre=""
[ -n "$container" ] && pre="${pre}ALTER SESSION SET CONTAINER = ${container};"$'\n'
[ -n "$schema" ]    && pre="${pre}ALTER SESSION SET CURRENT_SCHEMA = ${schema};"$'\n'

# ---- read the events ----
sqlplus -S -L "$conn" > "$log" 2>&1 <<SQL
WHENEVER OSERROR EXIT 9
WHENEVER SQLERROR EXIT FAILURE
${pre}@report/alert_events.sql $after $since $min_sev $trans $sdbid $scon
EXIT
SQL
st=$?
if [ $st -ne 0 ]; then
    echo "FAIL notify: sqlplus exit $st (sqlplus said:)" >&2
    grep -E "$err_re" "$log" | head -5 >&2
    exit 1
fi
if grep -q -E "$err_re" "$log"; then
    echo "FAIL notify: session output contains errors:" >&2
    grep -E "$err_re" "$log" | head -5 >&2
    exit 1
fi
tab=$'\t'
grep -E "^AWRCAP_EVENT(S_BEGIN)?${tab}" "$log" > "$ev"
pos=$(sed -n "s/^AWRCAP_EVENTS_BEGIN${tab}\([0-9][0-9]*\).*/\1/p" "$log" | tail -1)
n_end=$(sed -n "s/^AWRCAP_EVENTS_END${tab}\([0-9][0-9]*\).*/\1/p" "$log" | tail -1)
n=$(grep -c "^AWRCAP_EVENT${tab}" "$ev")
if [ -z "$pos" ] || [ -z "$n_end" ] || [ "$n" != "$n_end" ]; then
    echo "FAIL notify: incomplete output from report/alert_events.sql ($n event lines, END says '${n_end:-nothing}')" >&2
    grep -E 'ORA-|SP2-|ERROR' "$log" | head -5 >&2
    exit 1
fi

# Writes the position, atomically. A dry run never gets here.
save_pos() {
    printf '%s\n' "$pos" > "$state.tmp.$$" && mv -f "$state.tmp.$$" "$state" \
        || { echo "FAIL notify: cannot write $state" >&2; rm -f "$state.tmp.$$"; return 1; }
}

if [ "$n" -eq 0 ]; then
    if [ $dry -eq 1 ]; then
        echo "OK   notify: nothing to send (dry run, position $pos not saved)"
    else
        save_pos || exit 1
        echo "OK   notify: nothing to send (position $pos)"
    fi
    exit 0
fi

# ---- the message ----
# One awk program, four outputs (mode): subject, text (the mail body), json
# (the generic webhook body), slack ({"text": ...}). Fields arrive escaped by
# report/alert_events.sql: \\ \t \n \r, no other control character.
render() {
    awk -F '\t' -v mode="$1" '
    # Plain string replace. gsub() is not used on purpose: awks disagree on
    # backslashes in its replacement text.
    function repl(s, a, b,   i, out) {
        out = ""
        while ((i = index(s, a)) > 0) { out = out substr(s, 1, i - 1) b; s = substr(s, i + length(a)) }
        return out s
    }
    # an escaped field as display text, on one line
    function txt(s) {
        s = repl(s, bs bs, soh); s = repl(s, bs "n", " "); s = repl(s, bs "t", " "); s = repl(s, bs "r", "")
        return repl(s, soh, bs)
    }
    # an escaped field as the inside of a JSON string: only the quote is left to escape
    function jesc(s) { return repl(s, "\"", bs "\"") }
    # raw text (what this program composed) as the inside of a JSON string
    function jraw(s) { return repl(repl(repl(s, bs, bs bs), "\"", bs "\""), "\n", bs "n") }
    function jstr(s) { return s == "" ? "null" : "\"" jesc(s) "\"" }
    function jnum(s) { return s ~ /^[0-9]+$/ ? s : "null" }
    function counts(   s, k, i) {
        s = ""
        for (i = 1; i <= 3; i++) {
            k = sevs[i]
            if (nsev[k] > 0) s = s (s == "" ? "" : ", ") nsev[k] " " k
        }
        if (nres > 0) s = s (s == "" ? "" : ", ") nres " resolved"
        return s
    }
    function subject() {
        return "AWRCAP alerts: " counts() " (" (ntgt == 1 ? txt(tgt[1]) : ntgt " targets") ")"
    }
    function text(   s, i, t, line, m) {
        s = n " alert event" (n == 1 ? "" : "s") ": " counts() "\n"
        s = s "Repository " txt(repo) ", " txt(gen) "\n"
        t = ""
        for (i = 1; i <= n; i++) {
            if (i == 1 || e_tgt[i] != t) {
                t = e_tgt[i]
                s = s "\n== " txt(t) " ==\n"
            }
            line = sprintf("%-4s %s", (e_ev[i] == "RESOLVED" ? "--" : e_sev[i]), e_ev[i])
            if (e_prev[i] != "" && e_ev[i] != "NEW") line = line " (was " e_prev[i] ")"
            line = line "  " txt(e_kind[i]) "  " txt(e_pdb[i]) "  " txt(e_series[i])
            if (e_mode[i] != "") line = line "  " txt(e_mode[i])
            s = s line "\n"
            m = txt(e_msg[i])
            # mail lines have a length limit; the JSON body keeps the whole message
            if (length(m) > 900) m = substr(m, 1, 897) "..."
            s = s "     " m "\n"
            s = s "     " substr(e_at[i], 1, 10) " " substr(e_at[i], 12, 5) "  key " txt(e_key[i]) "\n"
        }
        s = s "\nOpen alerts: SELECT * FROM capr_alerts_latest\n"
        s = s "Acknowledge one: EXEC cap_results.ack(<key>)\n"
        return s
    }
    BEGIN { bs = "\\"; soh = sprintf("%c", 1)
            sevs[1] = "CRIT"; sevs[2] = "WARN"; sevs[3] = "INFO"; n = 0; ntgt = 0; nres = 0 }
    $1 == "AWRCAP_EVENTS_BEGIN" { pos = $2; repo = $3; gen = $4; next }
    $1 == "AWRCAP_EVENT" {
        n++
        e_id[n] = $2; e_at[n] = $3; e_ev[n] = $4; e_sev[n] = $5; e_prev[n] = $6; e_tgt[n] = $7
        e_dbid[n] = $8; e_con[n] = $9; e_pdb[n] = $10; e_kind[n] = $11; e_series[n] = $12
        e_mode[n] = $13; e_key[n] = $14; e_akey[n] = $15; e_msg[n] = $16
        if ($4 == "RESOLVED") nres++; else nsev[$5]++
        if (!($7 in seen)) { seen[$7] = 1; tgt[++ntgt] = $7 }
    }
    END {
        if (mode == "subject") { print subject(); exit }
        if (mode == "text")    { printf "%s", text(); exit }
        if (mode == "slack") {
            s = subject() "\n" text()
            s = repl(repl(repl(s, "&", "&amp;"), "<", "&lt;"), ">", "&gt;")
            print "{\"text\":\"" jraw(s) "\"}"
            exit
        }
        printf "{\"source\":\"awrcap\",\"subject\":\"%s\",\"repository\":%s,\"generated\":%s,\"position\":\"%s\",", jraw(subject()), jstr(repo), jstr(gen), pos
        printf "\"counts\":{\"events\":%d,\"CRIT\":%d,\"WARN\":%d,\"INFO\":%d,\"resolved\":%d,\"targets\":%d},", n, nsev["CRIT"], nsev["WARN"], nsev["INFO"], nres, ntgt
        printf "\"text\":\"%s\",\"events\":[", jraw(text())
        for (i = 1; i <= n; i++) {
            printf "%s{\"event_id\":\"%s\",\"at_time\":%s,\"event\":%s,\"severity\":%s,\"prev_severity\":%s,", (i > 1 ? "," : ""), e_id[i], jstr(e_at[i]), jstr(e_ev[i]), jstr(e_sev[i]), jstr(e_prev[i])
            printf "\"target\":%s,\"dbid\":%s,\"con_dbid\":%s,\"db_pdb\":%s,\"kind\":%s,\"series_key\":%s,", jstr(e_tgt[i]), jnum(e_dbid[i]), jnum(e_con[i]), jstr(e_pdb[i]), jstr(e_kind[i]), jstr(e_series[i])
            printf "\"baseline_mode\":%s,\"state_key\":%s,\"alert_key\":%s,\"message\":%s}", jstr(e_mode[i]), jstr(e_key[i]), jstr(e_akey[i]), jstr(e_msg[i])
        }
        print "]}"
    }' "$ev"
}

subject=$(render subject) || { echo "FAIL notify: cannot build the message" >&2; exit 1; }
render text > "$body"     || { echo "FAIL notify: cannot build the message" >&2; exit 1; }
if [ -n "$hook" ] || [ $dry -eq 1 ]; then
    render "$([ "$hook_fmt" = slack ] && echo slack || echo json)" > "$payload" \
        || { echo "FAIL notify: cannot build the webhook body" >&2; exit 1; }
fi

if [ $dry -eq 1 ]; then
    echo "DRY RUN: nothing sent, position $pos not saved (last delivered: $last)"
    [ ${#addrs[@]} -gt 0 ] && echo "Mail to: ${addrs[*]}"
    [ -n "$hook" ] && echo "Webhook: set ($hook_fmt format)"
    echo "Subject: $subject"
    echo
    cat "$body"
    echo
    echo "Webhook body ($hook_fmt):"
    cat "$payload"
    exit 0
fi

# ---- deliver ----
send_mail() {
    if [ "$mail_style" = "mailx" ]; then
        # shellcheck disable=SC2086
        $mail_cmd -s "$subject" "${addrs[@]}" < "$body"
    else
        {
            printf 'To: %s\n' "$(IFS=,; echo "${addrs[*]}")"
            printf 'Subject: %s\n' "$subject"
            printf 'MIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\n\n'
            cat "$body"
        } | $mail_cmd
    fi
}

# The URL goes to curl in a config on stdin, never as an argument (ps shows
# arguments), and is cut out of anything curl prints.
send_webhook() {
    local q out st
    q=${hook//\\/\\\\}
    q=${q//\"/\\\"}
    # shellcheck disable=SC2086
    out=$(printf 'url = "%s"\nheader = "Content-Type: application/json"\ndata-binary = "@%s"\n' "$q" "$payload" \
          | $curl_cmd --silent --show-error --fail --max-time 30 --output /dev/null --config - 2>&1)
    st=$?
    if [ $st -ne 0 ]; then
        out=${out//"$hook"/<webhook URL>}
        echo "FAIL webhook: curl exit $st${out:+: $out}" >&2
    fi
    return $st
}

rc=0
if [ ${#addrs[@]} -gt 0 ]; then
    if send_mail; then
        echo "OK   mail: $n events to ${addrs[*]}"
    else
        echo "FAIL mail: '${mail_cmd%% *}' exit non-zero" >&2
        rc=1
    fi
fi
if [ -n "$hook" ]; then
    if send_webhook; then
        echo "OK   webhook: $n events ($hook_fmt format)"
    else
        rc=1
    fi
fi

if [ $rc -ne 0 ]; then
    echo "FAIL notify: position stays at $last, the next run sends these $n events again" >&2
    exit 1
fi
save_pos || exit 1
echo "OK   notify: $subject, position $pos"
exit 0
