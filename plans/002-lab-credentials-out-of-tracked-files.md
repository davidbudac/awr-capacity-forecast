# Plan 002: No login literal remains in a tracked file of this public repository

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Never copy a password value** into a commit message, a comment, this
> plan, `plans/README.md` or your hand-back. Refer to a credential by file,
> line and type only.
>
> **Drift check (run first)**:
> `git diff --stat d91e3f8..HEAD -- LAB.md bench/env.sh.example bench/README.md elk/setup.sh elk/README.md grafana/docker-compose.yml`
> If any in-scope file changed since this plan was written, compare the
> "Current state" notes against the live files before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `d91e3f8`, 2026-11-10

## Why this matters

The repository is public on GitHub (`gh repo view --json visibility` →
`PUBLIC`). Its lab runbook and two helper files carry working logins of the
maintainer's lab as literals, next to the lab's network address. They are
default-type passwords on a private network, so the exposure is small, but a
committed secret stays in git history for good: the fix is removing the
literals **and** the operator rotating the passwords. This plan does the
first half; the second half is listed for the operator.

## Operator actions (NOT for the executor)

The executor cannot and must not do these. The operator does them after the
plan lands:

1. Rotate the Grafana `admin` password of the lab container.
2. Rotate the Elasticsearch `elastic` and Kibana system passwords of the
   docker-elk lab (its own `.env`).
3. Rotate the APEX `AWRCAP_VIEWER` account password named in `LAB.md`.
4. If `bench/env.sh` (untracked) still uses the values from
   `bench/env.sh.example`, change the three bench schema / admin passwords.
5. Do not rewrite git history for this; rotation is the remedy.

## Current state

Locations and types only (open the files to see them; do not quote values):

- `LAB.md`
  - line 12: Grafana row of the endpoint table, a `user / password` login literal.
  - line 15: APEX row, a parenthesised password literal for `AWRCAP_VIEWER`.
  - lines 17 and 19: Kibana and Elasticsearch rows, a `user / password` login literal.
  - line 78: a `curl -s -u user:password` example with the same literal.
- `bench/env.sh.example`
  - lines 26, 28, 33: `export SOE_PASS=...`, `export SH_PASS=...`,
    `export BENCH_ADMIN_PASS=...` with real-looking values. The file's own
    header (lines 3-4) says "No credential ever lives in a tracked file".
- `elk/setup.sh`
  - lines 24 and 27: `ES_PASSWORD="${ES_PASSWORD:-<literal>}"` and
    `KIBANA_PASSWORD="${KIBANA_PASSWORD:-<literal>}"` — a default password
    fallback.
- `grafana/docker-compose.yml`
  - line 3: a comment stating the image-default admin login literally.
  - the Grafana service sets no admin password, so the image default applies.

Conventions that apply:

- Local secrets of this repo live in gitignored files: `bench/env.sh`,
  `grafana/.env`, `grafana/.ords.env` (see `.gitignore`).
- `LAB.md` is the workstation runbook; its URLs (a private tailnet address)
  stay. Only the login literals go.
- The maintainer's lab binds services on all interfaces on purpose (it is
  reached over the tailnet). Do NOT change `BIND_ADDR` defaults or disable
  anonymous viewing in the compose file.

## Commands you will need

| Purpose | Command (repo root) | Expected on success |
|---|---|---|
| Shell syntax | `bash -n elk/setup.sh` | exit 0 |
| Compose syntax (only if docker is installed) | `docker compose -f grafana/docker-compose.yml config -q` | exit 0 |
| Docs lint | `test/docs_lint.sh` | exit 0 |

## Scope

**In scope**: `LAB.md`, `bench/env.sh.example`, `bench/README.md` (only if it
quotes one of the example passwords), `elk/setup.sh`, `elk/README.md` (only
the usage line for `setup.sh`, if it exists there), `grafana/docker-compose.yml`.

**Out of scope**: `bench/env.sh`, `grafana/.env`, `grafana/.ords.env` (untracked,
never open or print them); any running container; git history; `BIND_ADDR`
and anonymous-access settings.

## Git workflow

- Branch: `advisor/002-lab-credentials`
- One commit. Subject in this repo's style, for example:
  `Remove lab login literals from tracked files`. The body must not contain
  any removed value.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: `LAB.md`

Replace each login literal with a pointer, keeping the table layout:

- line 12 (Grafana): the credentials cell becomes
  `admin / (see grafana/.env: GF_ADMIN_PASSWORD); anonymous = viewer`
- line 15 (APEX): replace the parenthesised password with
  `(password: ask the maintainer; not in the repo)`
- lines 17 and 19 (Kibana, Elasticsearch): the credentials cell becomes
  `elastic / (docker-elk .env: ELASTIC_PASSWORD)`
- line 78: `curl -s -u "elastic:$ES_PASSWORD" '<the same URL>'` and, on the
  line above the code block or beside it, a note: `export ES_PASSWORD first`.

**Verify**:
- `grep -cE '\b(admin|elastic) */ *[A-Za-z0-9]' LAB.md` → `0`
- `grep -cE -- '-u [a-z_]+:[A-Za-z0-9]' LAB.md` → `0`
- `grep -ciE 'password [a-z0-9]{4,}\)' LAB.md` → `0`

### Step 2: `bench/env.sh.example`

Set the three values to placeholders: `export SOE_PASS=change-me`,
`export SH_PASS=change-me`, `export BENCH_ADMIN_PASS=change-me`. Add one
comment line above the first: `# Set your own passwords: this file is tracked, bench/env.sh is not.`
If `bench/README.md` quotes any of the old values, replace them the same way.

**Verify**: `grep -cE '^export (SOE_PASS|SH_PASS|BENCH_ADMIN_PASS)=change-me$' bench/env.sh.example` → `3`

### Step 3: `elk/setup.sh` requires its passwords

Change lines 24 and 27 so that there is no default:

```
ES_PASSWORD="${ES_PASSWORD:?set ES_PASSWORD (the elastic user's password)}"
KIBANA_PASSWORD="${KIBANA_PASSWORD:?set KIBANA_PASSWORD}"
```

Leave `ES_URL`, `ES_USER`, `KIBANA_URL`, `KIBANA_USER` defaults as they are.
Search for callers and docs that run the script without the variables:
`grep -rn "setup.sh" LAB.md elk/README.md README.md docs/*.html | grep -i elk`.
Known hits at planning time: `elk/README.md` lines 83 and 112 (command
lines) and `LAB.md`. In each hit that shows a command line, prefix it with
`ES_PASSWORD=... KIBANA_PASSWORD=...` (literally three dots, not a value).
Edit only `LAB.md` and `elk/README.md`; if a hit is in another file, list it
in your hand-back instead of editing it.

**Verify**:
- `bash -n elk/setup.sh` → exit 0
- `grep -cE '(ES|KIBANA)_PASSWORD:-' elk/setup.sh` → `0`
- `env -u ES_PASSWORD -u KIBANA_PASSWORD bash elk/setup.sh; echo "rc=$?"` →
  prints `set ES_PASSWORD` and `rc=1` (it must stop before any `curl`)

### Step 4: `grafana/docker-compose.yml`

- Line 3 (comment): replace the literal login with
  `admin, password from GF_ADMIN_PASSWORD in grafana/.env`.
- In the Grafana service's `environment:` map (the keys that start with
  `GF_`), add:
  `GF_SECURITY_ADMIN_PASSWORD: "${GF_ADMIN_PASSWORD:?set GF_ADMIN_PASSWORD in grafana/.env}"`

Grafana applies this variable only when it initialises an empty data volume;
an existing lab volume keeps its current admin password until the operator
rotates it. That is expected: do not delete any volume.

**Verify**:
- `grep -c "GF_SECURITY_ADMIN_PASSWORD" grafana/docker-compose.yml` → `1`
- `grep -cE 'admin/[a-z]+' grafana/docker-compose.yml` → `0`
- if docker is installed: `GF_ADMIN_PASSWORD=x docker compose -f grafana/docker-compose.yml config -q` → exit 0

### Step 5: Final sweep

`git grep -nIiE '(password|passwd|_pass)[a-z_]*["'"'"' ]*[:=] *["'"'"']?[A-Za-z0-9!@#%^*_+-]{4,}' -- . ':!plans' ':!docs/demo' ':!*.html' ':!apex/awrcap_app.sql'`

Read every hit. A hit is acceptable when the value is a placeholder
(`change-me`, `...`, `<password>`, `secret` in a usage comment), a variable
reference (`$X`, `${X}`, `&x`, `:x`), or SQL that names a column or
parameter. Any other hit that is a real literal: do not print it; report its
`file:line` and type in the hand-back and STOP (it is outside this plan's
scope).

## Test plan

No automated test exists for these files. The gates are the greps in each
step and `bash -n`. Do not start, stop or reconfigure any lab service.

## Done criteria

- [ ] The three `LAB.md` greps of step 1 each print `0`
- [ ] `grep -cE '(ES|KIBANA)_PASSWORD:-' elk/setup.sh` → `0`
- [ ] `grep -cE '^export (SOE_PASS|SH_PASS|BENCH_ADMIN_PASS)=change-me$' bench/env.sh.example` → `3`
- [ ] `grep -c "GF_SECURITY_ADMIN_PASSWORD" grafana/docker-compose.yml` → `1`
- [ ] `bash -n elk/setup.sh` and `test/docs_lint.sh` exit 0
- [ ] `git status --short` lists only in-scope files
- [ ] `git log -1 --format=%B` contains no removed value
- [ ] The hand-back repeats the "Operator actions" list
- [ ] `plans/README.md` status row updated

## STOP conditions

- A line named in "Current state" does not hold a login literal any more.
- Step 5 finds a real literal outside the in-scope files.
- You are tempted to open an untracked secrets file to "check the value":
  do not; stop and ask.

## Maintenance notes

- `elk/setup.sh` still passes the password to `curl -u` on the command line
  (visible in `ps` on the workstation). Left as is for the lab; the fix would
  be `curl --config -` with the credentials on stdin.
- The compose images float on `:latest`; pinning them is a separate, optional
  change.
- Reviewer: check the commit diff itself shows only removals of literals and
  placeholder additions, and that no value was moved into a comment.
