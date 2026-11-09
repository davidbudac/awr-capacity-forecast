#!/usr/bin/env bash
# test/docs_lint.sh -- catch documentation drift against the DDL.
# Bash + grep/awk, and git for checks 8 and 9. Nine checks, each prints one OK / FAIL
# summary line (6 and 7 one per document they read):
#   1. every knob the ddl/05 seed MERGE inserts is named in docs/reference.html;
#   2. every view / table / package / procedure that ddl/, ml/ and repository/ create is
#      named in the object index of docs/reference.html (id="objects" up to
#      id="teardown"), case-insensitive;
#   3. no document hard-codes an assertion count (the harness prints its own;
#      docs point at its summary lines instead);
#   4. no document claims the site is generated (it is maintained by hand);
#   5. every alert kind CAPR_ALERTS can emit is named in docs/reference.html.
#      The kinds come from CAPR_SEVERITY (ddl/45), the alert_kind column of
#      CAPA_OBS (ddl/40) and the extra branches of CAPR_ALERTS (ddl/55);
#   6. every table a CREATE TABLE in ddl/ or repository/ makes, plus CAP_H_* for
#      the ddl/13 copies, is named in the persisted-tables section of
#      docs/reference.html (id="tables" up to the next section head) and in the
#      CLAUDE.md "Persisted tables survive a re-install" bullet, case-insensitive;
#   7. every profiles/*.env is named in docs/reference.html as --profile NAME or
#      NAME.env, and in the --profile help of install.sh;
#   8. no tracked file but PLAN.md and bench/ names the retired warehouse mode
#      (M24.9): its views, owner, seam file, profile, role or deploy_mode;
#   9. no tracked file but PLAN.md and bench/ names the retired local mode
#      (M25): its deploy_mode value, create_owner's owner_mode define or
#      ddl/10's old file name, except the allow-listed lines that exist to
#      reject or explain it.
# Exit 1 when any check fails.
set -u
cd "$(dirname "$0")/.." || exit 2
REF=docs/reference.html
DOCS="README.md CLAUDE.md PLAN.md LAB.md docs/*.html docs/design.md grafana/API.md
      elk/README.md apex/README.md bench/README.md"
rc=0

report() {   # report <label> <checked> <missing list>
  local n_miss
  n_miss=$(printf '%s' "$3" | grep -c . || true)
  if [ "$n_miss" -eq 0 ]; then
    echo "OK   $1: $2 checked, 0 missing"
  else
    echo "FAIL $1: $2 checked, $n_miss missing:"
    printf '%s\n' "$3" | grep . | sed 's/^/       /'
    rc=1
  fi
}

# ---- 1. knobs ---------------------------------------------------------------
knobs=$(awk '/^-- Idempotent seed/{on=1} on && /^\) s$/{exit} on' ddl/05_config.sql \
        | grep -oE "SELECT '[a-z0-9_]+'" | sed -E "s/SELECT '([a-z0-9_]+)'/\1/" | sort -u)
miss=""
for k in $knobs; do
  grep -qE "(^|[^a-z0-9_])${k}([^a-z0-9_]|$)" "$REF" || miss="$miss$k"$'\n'
done
report "knobs seeded in ddl/05 named in $REF" "$(echo "$knobs" | grep -c .)" "$miss"

# ---- 2. objects -------------------------------------------------------------
objects=$(cat ddl/*.sql ml/*.pks ml/*.pkb repository/*.sql 2>/dev/null \
  | grep -v -E '^\s*--' \
  | grep -oiE "CREATE( OR REPLACE)?( FORCE)? (VIEW|TABLE|PACKAGE|PROCEDURE|FUNCTION|TYPE) +[a-z0-9_\$]+" \
  | grep -viE 'PACKAGE BODY|TYPE BODY' \
  | awk '{print toupper($NF)}' | sort -u)
index_txt=$(awk '/id="objects"/{on=1} /id="teardown"/{on=0} on' "$REF" | sed 's/<[^>]*>/ /g' | tr 'a-z' 'A-Z')
miss=""
for o in $objects; do
  printf '%s' "$index_txt" | grep -qE "(^|[^A-Z0-9_\$])${o//\$/\\\$}([^A-Z0-9_\$]|$)" || miss="$miss$o"$'\n'
done
report "objects created in ddl/ + ml/ + repository/ named in the $REF object index" "$(echo "$objects" | grep -c .)" "$miss"

# ---- 3. hard-coded assertion counts ------------------------------------------
# A standalone number of two or more digits (not part of 19c, 18:00 or M15)
# within a short clause of "assertion(s)", or right before "passed" / "PASS".
NUM='(^|[^A-Za-z0-9_.:+-])[*]*[0-9]{2,}[*]*([^A-Za-z0-9_:.]|$)'
hits=$(grep -n -i -E \
  "${NUM}[^.;]{0,40}assertion|assertion[^.;]{0,40}${NUM}|[0-9]{2,} (passed|PASS)" \
  $DOCS 2>/dev/null)
report "documents without a hard-coded assertion count" "$(echo $DOCS | wc -w)" "$hits"

# ---- 4. "generated" claims ----------------------------------------------------
hits=$(grep -n -i -E 'documentation (is )?generated|generated from[^.]{0,40}(README|design\.md)|(site|pages) (is|are) generated' \
  $DOCS 2>/dev/null)
report "documents not claiming the site is generated" "$(echo $DOCS | wc -w)" "$hits"

# ---- 5. alert kinds -------------------------------------------------------------
sev_kinds=$(awk '/CREATE OR REPLACE VIEW capr_severity/{on=1} on && /^CREATE OR REPLACE VIEW/ && !/capr_severity/{exit} on' \
              ddl/45_report_views.sql | grep -oE "SELECT '[A-Z]+_[A-Z_]+'" | grep -oE "[A-Z]+_[A-Z_]+")
anom_kinds=$(grep -oE "'[A-Z]+_ANOM'" ddl/40_anomaly_views.sql | tr -d "'")
alert_kinds=$(awk '/CREATE OR REPLACE VIEW capr_alerts AS/{on=1} on' ddl/55_report_views_ml.sql \
              | grep -oE "^ +'[A-Z]+_[A-Z_]+',$" | grep -oE "[A-Z]+_[A-Z_]+" \
              | grep -vE '^(AWR_SNAPSHOT|ESM_MODELS)$')
kinds=$(printf '%s\n%s\n%s\n' "$sev_kinds" "$anom_kinds" "$alert_kinds" | grep . | sort -u)
miss=""
for k in $kinds; do
  grep -qE "(^|[^A-Z0-9_])${k}([^A-Z0-9_]|$)" "$REF" || miss="$miss$k"$'\n'
done
report "alert kinds ($(echo $kinds | tr ' ' ',')) named in $REF" "$(echo "$kinds" | grep -c .)" "$miss"

# ---- 6. persisted tables ---------------------------------------------------------
# Every table is persisted: ddl/00_drop drops views only. ddl/13 creates the
# copies under a computed name, so they count as the one entry CAP_H_*.
tables=$(cat ddl/*.sql repository/*.sql 2>/dev/null \
  | grep -v -E '^\s*--' \
  | grep -oiE "CREATE TABLE +[a-z][a-z0-9_\$#]*" \
  | awk '{print toupper($NF)}' | sort -u)
grep -q "ensure('cap_h_" ddl/13_seam_repository.sql && tables="$tables"$'\n''CAP_H_*'
tables_ref=$(awk '/id="tables"/{on=1; next} on && /class="section-head"/{exit} on' "$REF" \
             | sed 's/<[^>]*>/ /g' | tr 'a-z' 'A-Z')
tables_claude=$(awk '/^- \*\*Persisted tables survive a re-install:\*\*/{on=1; print; next}
                     on && /^- \*\*/{exit} on' CLAUDE.md | tr 'a-z' 'A-Z')
miss_ref=""; miss_claude=""
for t in $tables; do
  re="(^|[^A-Z0-9_\$])$(printf '%s' "$t" | sed 's/[$*]/\\&/g')([^A-Z0-9_\$]|$)"
  printf '%s' "$tables_ref"    | grep -qE "$re" || miss_ref="$miss_ref$t"$'\n'
  printf '%s' "$tables_claude" | grep -qE "$re" || miss_claude="$miss_claude$t"$'\n'
done
n_tables=$(echo "$tables" | grep -c .)
report "persisted tables named in $REF#tables" "$n_tables" "$miss_ref"
report "persisted tables named in the CLAUDE.md 'Persisted tables' bullet" "$n_tables" "$miss_claude"

# ---- 7. profiles -------------------------------------------------------------------
# reference.html must show a profile as --profile NAME or NAME.env, so the
# English word "target" alone does not count. The install.sh help block is a
# plain list of names.
profiles=$(ls profiles/*.env 2>/dev/null | sed -E 's|.*/||; s|\.env$||')
ref_txt=$(sed 's/<[^>]*>/ /g' "$REF")
help_txt=$(awk '/^#   --profile P/{on=1; print; next} on && /^#   --/{exit} on' install.sh)
miss_ref=""; miss_help=""
for p in $profiles; do
  printf '%s' "$ref_txt" | grep -qE "(--profile +${p}|(^|[^A-Za-z0-9_.-])${p}\.env)([^A-Za-z0-9_-]|$)" \
    || miss_ref="$miss_ref$p"$'\n'
  printf '%s' "$help_txt" | grep -qE "(^|[^A-Za-z0-9_-])${p}([^A-Za-z0-9_-]|$)" \
    || miss_help="$miss_help$p"$'\n'
done
n_profiles=$(echo "$profiles" | grep -c .)
report "profiles/*.env named in $REF (--profile NAME or NAME.env)" "$n_profiles" "$miss_ref"
report "profiles/*.env named in the install.sh --profile help" "$n_profiles" "$miss_help"

# ---- 8. retired warehouse mode -----------------------------------------------------
# PLAN.md keeps the milestone history, bench/'s warehouses are SwingBench's, and
# this script spells out the tokens it looks for.
not_wh=(-- . ':!PLAN.md' ':!bench' ':!test/docs_lint.sh')
hits=$(git grep -n -I -i -E \
  "awrv_|awrwh|11_seam_warehouse|warehouse\.env|profile +warehouse|role *= *warehouse|deploy_mode *= *'?warehouse" \
  "${not_wh[@]}")
report "tracked files without a retired warehouse-mode token" "$(git ls-files "${not_wh[@]}" | grep -c .)" "$hits"

# ---- 9. retired local mode -------------------------------------------------------
not_local=(-- . ':!PLAN.md' ':!bench' ':!test/docs_lint.sh')
local_ok=(
  "^install\.sql:[0-9]+: .*'deploy_mode = local is retired \(M25\)"
  "^doctor\.sql:[0-9]+: +ELSIF v_deploy_mode = 'local' THEN\$"
)
hits=$(git grep -n -I -i -E \
  "deploy_mode[\"']? *= *[\"']?local\b|owner_mode|10_seam_local" \
  "${not_local[@]}" | grep -v -E "$(IFS='|'; echo "${local_ok[*]}")")
report "tracked files without a retired local-mode token" "$(git ls-files "${not_local[@]}" | grep -c .)" "$hits"

exit $rc
