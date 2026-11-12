#!/usr/bin/env bash
# test/lint_secrets.sh -- no tracked file holds a login literal (the
# repository is public). A password is written as a placeholder (<password>,
# "...", ********), a variable ($VAR, ${VAR}, &var), or one of the words
# pw / pwd / pass / passwd / password / secret / change-me, which this lint
# reads as placeholders, never as a real password. It fails on:
#   default-login   the default logins of the lab images (changeme,
#                   admin/admin, admin:admin)
#   curl-user       -u user:literal / --user user:literal
#   shell-default   a password variable with a default: ${X_PASSWORD:-literal}
#   identified-by   IDENTIFIED BY literal (CREATE / ALTER USER, a link's
#                   CONNECT TO)
#   connect         connect / sqlplus / sqlcl / expdp / impdp user/literal,
#                   and any user/literal@//host or @host:port
#   assignment      X_PASSWORD=literal, DEFINE x_pw = literal, and
#                   "password: literal" in a .yml / .yaml / .json / .env file
# Not judged: plans/ (a plan is a work order and may quote the literal it
# tells its executor to remove, as "before" text or a grep) and this file
# (it names the patterns).
# Exit 1 and list file:line:match per offender on a violation.
set -u
cd "$(dirname "$0")/.." || exit 2
. test/repo_files.sh
rc=0
list=$(mktemp)
trap 'rm -f "$list"' EXIT
repo_files '*' | grep -vE '^(plans/|test/lint_secrets\.sh$)' > "$list"

TOK='[A-Za-z0-9][A-Za-z0-9_#$!%^*+-]*'
WORDS='(pw|pwd|pass|passwd|password|secret|change-me)'
# The match ends in the password: a placeholder word after its delimiter.
END_PH="[^A-Za-z0-9_-]$WORDS\$"

# rule NAME FLAGS REGEX [DROP] [FILE-FILTER]
#   FLAGS        grep flags besides -noIE ("i" = ignore case, "-" = none)
#   DROP         matches to let through (the placeholder words)
#   FILE-FILTER  judge only the files whose path matches
rule() {
  local name=$1 flags=$2 re=$3 drop=${4:-} only=${5:-} hits
  [ "$flags" = - ] && flags=""
  hits=$(grep -E -- "${only:-.}" "$list" | tr '\n' '\0' \
           | xargs -0 grep -noIE$flags -e "$re" /dev/null 2>/dev/null)
  [ -n "$drop" ] && hits=$(printf '%s\n' "$hits" | grep -viE -- "$drop")
  [ -n "$hits" ] || return 0
  printf '%s\n' "$hits" | sed "s/^/lint_secrets: $name: /"
  rc=1
}

rule default-login i 'changeme|admin */ *admin|admin:admin'
rule curl-user     i "(^|[^A-Za-z0-9_-])(-u|--user)[ =]+[\"']?[A-Za-z_][A-Za-z0-9_.-]*:$TOK" "$END_PH"
rule shell-default i "[A-Za-z0-9_]*(passw|_pass|pwd|_pw|secret)[A-Za-z0-9_]*:-[\"']?[A-Za-z0-9]"
rule shell-default i ":-[\"']?[a-z]*pass"
# Upper case anywhere; lower case only in a statement ("identified by" is
# also plain English).
rule identified-by - "IDENTIFIED +BY +[\"']?$TOK" "$END_PH"
rule identified-by i "(user|role|connect +to) +[^ ]+ +identified +by +[\"']?$TOK" "$END_PH"
rule connect       i "(^|[^A-Za-z0-9_])(conn|connect|sqlplus|sqlcl|expdp|impdp)( +-[A-Za-z]+)* +[\"']?[A-Za-z_][A-Za-z0-9_#$]*/$TOK" "$END_PH"
rule connect       i "[A-Za-z_][A-Za-z0-9_#$]*/$TOK@(//|[A-Za-z0-9_.-]+:[0-9])" "/$WORDS@"
# Four characters or more: flags such as per_pw=1 are not passwords.
VAL='[A-Za-z0-9][A-Za-z0-9_#$!%^*+-]{3,}'
PWNAME='([A-Za-z0-9_]*passw(or)?d|([A-Za-z0-9]+_)*(pass|pwd|pw))'
rule assignment    i "(^|[^A-Za-z0-9_])$PWNAME=[\"']?$VAL" "$END_PH"
rule assignment    i "(^|[^A-Za-z0-9_])define +$PWNAME *= *[\"']?$VAL" "$END_PH"
rule assignment    i "passw(or)?d[\"']? *: *[\"']?$VAL" "$END_PH" '\.(ya?ml|json|env)$'

[ $rc = 0 ] && echo "lint_secrets: OK"
exit $rc
