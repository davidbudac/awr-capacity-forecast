# Plan 005: The generated reader password never leaves its bind, and no wrapper puts a password on a command line

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat d91e3f8..HEAD -- target/self.sql target/prepare.sql repository/self.sql quickstart.sh report/run_report.sh test/run_report_sh_test.sh CLAUDE.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW for the code; the database check changes a shared test account and is the operator's to run
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `d91e3f8`, 2026-11-10

## Why this matters

In the "standalone" install the suite creates a read-only reader account and
gives it a random password that the docs promise is "held only in the bind
`:cap_self_pw`". It is not: `target/self.sql` copies the bind into a SQL*Plus
substitution variable, and `target/prepare.sql` splices that into the text of
a PL/SQL block. The block's text, password included, is then visible in the
shared pool (`V$SQL`) and, because the session is SYSDBA, in the operating
system audit files. Separately, two wrapper scripts pass the operator's
connect string, which may contain a password, as a `sqlplus` argument, where
any local user can read it with `ps`. Both leaks are avoidable.

One leak is **not** avoidable in SQL*Plus and is out of scope: a password the
operator types (`DEFINE reader_pw = ...`, `cap_repo.add_target(..., '<password>')`)
must travel to the server as a literal in one statement. Only a password
generated on the server can stay in a bind from start to end.

## Current state

- `target/self.sql` — SYSDBA script for the standalone path. Lines 90-91
  generate the password into a bind:
  ```
  VARIABLE cap_self_pw VARCHAR2(64)
  EXEC :cap_self_pw := 'Rd' || DBMS_RANDOM.STRING('X', 22) || 'q7_'
  ```
  Lines 93-124 are one `SELECT ... FROM dual` that fills substitution
  variables through `COLUMN ... NEW_VALUE`. Two of its lines copy the
  password out of the bind:
  ```
  COLUMN cap_pw  NEW_VALUE reader_pw        NOPRINT          -- line 99
         :cap_self_pw AS cap_pw                              -- line 122, last select item
  ```
  and line 130 clears the column: `COLUMN cap_pw CLEAR`. Line 137 then runs
  `@@target/prepare.sql`.
- `target/prepare.sql` — creates / alters the reader. Lines 38-44 define the
  optional inputs as empty when the caller did not:
  ```
  COLUMN cap_r_in NEW_VALUE reader        NOPRINT
  COLUMN cap_w_in NEW_VALUE reader_pw     NOPRINT
  COLUMN cap_n_in NEW_VALUE cap_self_name NOPRINT
  SELECT NULL AS cap_r_in, NULL AS cap_w_in, NULL AS cap_n_in FROM dual WHERE 1 = 0;
  ```
  Line 59, inside the main `DECLARE` block, splices the password:
  ```
      v_pw     VARCHAR2(200) := q'~&reader_pw~';
  ```
  `'&cap_self_name' IS NOT NULL` is how this script recognises the standalone
  path (line 127). The script ends with `UNDEFINE reader_pw`.
- `repository/self.sql` — already reads the bind (lines 63-64 and 70-71):
  `USING v_name, v_conn, v_reader, :cap_self_pw, '&cap_self_gname';`
- `quickstart.sh` — last two lines:
  ```
  [[ $# -eq 0 ]] && set -- / as sysdba
  printf '%s@quickstart.sql\nEXIT\n' "$defs" | sqlplus -S -L "$@"
  ```
  Its header documents `./quickstart.sh 'sys/pw@//host/svc as sysdba'`.
- `report/run_report.sh` — function `run_driver` (line 109):
  ```
      sqlplus -S -L "$conn" > "$log" 2>&1 <<SQL
  WHENEVER OSERROR EXIT 9
  WHENEVER SQLERROR EXIT FAILURE
  ${pre}${call}
  EXIT
  SQL
  ```
- `install.sh` already does it the safe way and is the pattern to copy: it
  runs `sqlplus -L /nolog @driver`, and the driver starts with
  `WHENEVER SQLERROR EXIT FAILURE`, `WHENEVER OSERROR EXIT FAILURE`, then
  `CONNECT / as sysdba`.
- `test/run_report_sh_test.sh` — offline test of `run_report.sh` with a mock
  `sqlplus` (a shell script it writes to a temp `bin/`).
- `CLAUDE.md` line 217: "gives the reader a random password held only in the
  bind `:cap_self_pw`".

SQL*Plus facts that matter here:

- A PL/SQL block that names a bind (`:x`) fails on the client with SP2-0552
  when `VARIABLE x` was never declared. So the script that reads the bind
  must also be the one that declares it.
- Bind variables live in the SQL*Plus client: they survive
  `ALTER SESSION SET CONTAINER` and `@@` includes, until the session ends.
- Included scripts may leave `SET DEFINE OFF` or `WHENEVER SQLERROR CONTINUE`
  behind; callers re-assert them. Do not add either to these scripts.
- Every runnable script keeps its two lines `SET APPINFO OFF` /
  `SET APPINFO "AWRCAP/<path>"` (`test/lint_appinfo.sh` checks).

## Design (decided)

`target/prepare.sql` becomes the owner of the bind: it declares
`cap_self_pw`, and a small first block fills it — with a server-generated
random password on the standalone path, with the operator's `reader_pw`
otherwise. The main block reads the bind. `target/self.sql` no longer
generates or copies anything. `repository/self.sql` is unchanged.

## Commands you will need

| Purpose | Command (repo root) | Expected on success |
|---|---|---|
| Shell syntax | `bash -n quickstart.sh report/run_report.sh` | exit 0 |
| Report wrapper test | `test/run_report_sh_test.sh` | last line `run_report.sh test: all passed` |
| Offline lints | `test/lint_appinfo.sh && test/lint_dba_hist.sh && test/docs_lint.sh && python3 repository/build.py --check` | exit 0 |
| Installer dry run | `./install.sh --profile profiles/standalone.env --dry-run` | exit 0 |

## Scope

**In scope**: `target/self.sql`, `target/prepare.sql`, `repository/self.sql`
(header comment only), `quickstart.sh`, `report/run_report.sh`,
`test/run_report_sh_test.sh`, `CLAUDE.md` (the one sentence at line 217).

**Out of scope**: `create_owner.sql`, `apex/workspace.sql`, `install.sh`,
`install.sql`, `doctor.sql`, `repository/cap_repo.sql` (typed passwords: see
"Why this matters"); `quickstart.sql`; any docs page.

## Git workflow

- Branch: `advisor/005-passwords`
- Two commits: (1) the bind path, (2) the wrappers. Style: imperative
  subject, bullet body.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: `target/prepare.sql` declares and fills the bind

(a) Directly after the `SET TERMOUT ON` that follows the zero-row `SELECT`
shown above (line 45), add:

```
-- The password stays in this bind. On the standalone path (cap_self_name
-- set by target/self.sql) it is generated here, on the server, and never
-- appears in a statement's text; otherwise it is the caller's reader_pw.
-- repository/self.sql reads the same bind for the loopback link.
VARIABLE cap_self_pw VARCHAR2(200)
BEGIN
    :cap_self_pw := CASE WHEN '&cap_self_name' IS NOT NULL
                         THEN 'Rd' || DBMS_RANDOM.STRING('X', 22) || 'q7_'
                         ELSE q'~&reader_pw~' END;
END;
/
```

(b) Line 59: change `v_pw     VARCHAR2(200) := q'~&reader_pw~';` to
`v_pw     VARCHAR2(200) := :cap_self_pw;`

(c) In the header comment (lines 1-27), after the bullet list "What it
does", add one line: `-- Leaves the reader's password in the bind :cap_self_pw (not printed).`

Leave everything else, including the validation
`IF v_pw IS NULL OR REGEXP_LIKE(v_pw, '["'']')` and `UNDEFINE reader_pw`.

**Verify**: `grep -c "q'~&reader_pw~'" target/prepare.sql` → `1` (only the
new first block); `grep -c ":cap_self_pw" target/prepare.sql` → `3` or more.

### Step 2: `target/self.sql` stops generating and copying the password

- Delete lines 90-91 (`VARIABLE cap_self_pw ...` and the `EXEC` that sets it).
- Delete line 99 (`COLUMN cap_pw  NEW_VALUE reader_pw        NOPRINT`).
- In the `SELECT`, delete the last select item `:cap_self_pw AS cap_pw` and
  the comma that ends the item before it (the `cap_r` item), so the select
  list ends with `... END)) AS cap_r` followed by `FROM   dual;`.
- Delete line 130 (`COLUMN cap_pw CLEAR`).
- Header comment line 18-19 says "The reader gets a new random password,
  held only in this session (bind :cap_self_pw), then target/prepare.sql
  and target/check.sql run". Change to "target/prepare.sql gives the reader
  a new random password, held only in this session's bind :cap_self_pw; then
  target/check.sql runs".

In `repository/self.sql`, the header (line 6) mentions "its bind
:cap_self_pw": no code change; adjust the sentence only if it says self.sql
generates the password.

**Verify**:
- `grep -c "cap_pw" target/self.sql` → `0`
- `grep -c "reader_pw" target/self.sql` → `0`
- `grep -c "DBMS_RANDOM" target/self.sql` → `0`; `grep -c "DBMS_RANDOM" target/prepare.sql` → `1`
- `test/lint_appinfo.sh` → exit 0

### Step 3: `quickstart.sh` connects from stdin

Replace the last line with:

```
{
  printf 'WHENEVER SQLERROR EXIT FAILURE\nWHENEVER OSERROR EXIT FAILURE\nCONNECT %s\n' "$*"
  printf '%s@quickstart.sql\nEXIT\n' "$defs"
} | sqlplus -S -L /nolog
```

Keep the line before it (`[[ $# -eq 0 ]] && set -- / as sysdba`). In the
header comment, under the two usage lines, add:
`# The connect string is sent on sqlplus's standard input, not its command line.`

**Verify**: `bash -n quickstart.sh` → exit 0;
`grep -c 'sqlplus -S -L "\$@"' quickstart.sh` → `0`.

### Step 4: `report/run_report.sh` connects from the heredoc

In `run_driver`, change the invocation to `/nolog` and make `CONNECT` the
third line of the heredoc:

```
    sqlplus -S -L /nolog > "$log" 2>&1 <<SQL
WHENEVER OSERROR EXIT 9
WHENEVER SQLERROR EXIT FAILURE
CONNECT ${conn}
${pre}${call}
EXIT
SQL
```

Then open `test/run_report_sh_test.sh` and read its mock `sqlplus` (the
heredoc written to `$T/bin/sqlplus`, around lines 23-56). If the mock reads
its arguments (`$1`, `$@`) to decide anything, change it to ignore them (the
only argument is now `/nolog`); if a test case asserts the connect string
reached `sqlplus`, assert instead that the mock's standard input contains a
line starting `CONNECT `. Keep every existing case.

**Verify**: `bash -n report/run_report.sh` → exit 0;
`test/run_report_sh_test.sh` → `run_report.sh test: all passed`;
`grep -c 'sqlplus -S -L "\$conn"' report/run_report.sh` → `0`.

### Step 5: `CLAUDE.md` sentence

Line 217 region reads: "(SYSDBA in CDB$ROOT or a non-CDB: picks the one open
PDB or `container`, else stops before any change; gives the reader a random
password held only in the bind `:cap_self_pw`; runs target/prepare.sql +
check.sql; ...". Change the middle clause to: "runs target/prepare.sql, which
gives the reader a random password held only in the bind `:cap_self_pw`, and
check.sql;". Touch nothing else in the file.

**Verify**: `test/docs_lint.sh` → exit 0.

### Step 6: Offline gates, then hand the database check to the operator

Run every command in "Commands you will need". Then STOP and hand back with
this request for the operator (do not run it yourself unless the operator
told you to and named the owner):

> Database check (changes the password of the shared test reader
> `C##AWRM25`): from the repo root on the workstation, with the checkout
> synced as the standalone smoke in `CLAUDE.md` describes,
> `CAP_OWNER=CAPM<n> CAP_READER=C##AWRM25 ./quickstart.sh` must end with a
> report and no `FAIL`. Then, as SYSDBA in CDB$ROOT:
> `SELECT COUNT(*) FROM v$sql WHERE sql_fulltext LIKE '%q''~Rd%q7_~''%';` → 0
> (no cached statement carries the generated password as a `q'~...~'` literal;
> before this change the `DECLARE` block of target/prepare.sql did).
> Afterwards rotate `C##AWRM25` and run `cap_repo.set_link_password` in the
> other CAPM schemas, as `CLAUDE.md` ("Standalone smoke") says.

## Test plan

- `test/run_report_sh_test.sh` (adapted mock) covers step 4.
- Steps 1-3 have no offline test: the gate is the operator's standalone
  smoke above. Mark the plan `DONE (database check pending operator)` if the
  operator has not run it.

## Done criteria

- [ ] `grep -c "cap_pw\|reader_pw\|DBMS_RANDOM" target/self.sql` → `0`
- [ ] `grep -c ":cap_self_pw" target/prepare.sql` → `3` or more
- [ ] `grep -rn 'sqlplus -S -L "\$' quickstart.sh report/run_report.sh` → no output
- [ ] `test/run_report_sh_test.sh` → all passed
- [ ] Offline lints and the installer dry run exit 0
- [ ] `git status --short` lists only in-scope files
- [ ] Hand-back contains the operator's database check, verbatim
- [ ] `plans/README.md` status row updated

## STOP conditions

- `target/self.sql`'s big `SELECT` no longer ends with the `cap_r` and
  `cap_pw` items as described.
- Another script reads `&reader_pw` after `target/self.sql` on the
  standalone path: check with
  `grep -rn "reader_pw" --include=*.sql --include=*.sh . | grep -v "^./target/prepare.sql\|^./docs/\|^./plans/"`.
  Expected hits: `install.sh` (the `target` role only, lines 415 and 418).
  Any other hit: stop and report it.
- The mock in `test/run_report_sh_test.sh` cannot be adapted without
  rewriting test cases.

## Maintenance notes

- A password the operator types still reaches the server as a literal once
  (`target/prepare.sql` in the `target` role, `create_owner.sql`,
  `cap_repo.add_target` / `set_link_password` called by hand). SQL*Plus has no
  way to move a substitution variable into a bind without a statement that
  contains it. If that matters, the fix is outside SQL*Plus (a wallet-based
  link or a client that binds).
- `CREATE USER ... IDENTIFIED BY "..."` is DDL built by `EXECUTE IMMEDIATE`;
  it cannot take a bind. Oracle does not keep DDL text with the password in
  the audit trail, but the dynamic string exists in the server process for
  the call.
- Reviewer: confirm that in the standalone path nothing prints or `DEFINE`s
  the password, and that `install.sh`'s `target` role still works (it
  `DEFINE`s `reader_pw` before `@@target/prepare.sql`).
