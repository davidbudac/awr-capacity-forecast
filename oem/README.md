# oem/ : Oracle Enterprise Manager hook

Opt-in, outside `install.sql`. Two things for a site that runs Enterprise
Manager Cloud Control (13c, 24ai):

1. **Alerts as incidents.** A SQL metric extension on the repository database
   collects the suite's alert states (`oem/awrcap_alerts.sql`). Thresholds on
   one numeric column raise Warning and Critical alerts, and an incident rule
   turns them into incidents.
2. **Targets from the inventory.** `oem/prepare_targets.sh` lists the
   databases Enterprise Manager knows, prepares the selected ones as targets
   (by hand, or through one EM job) and writes the `cap_repo.add_target`
   calls for the repository.

| File | What it is |
|---|---|
| `awrcap_alerts.sql` | The metric extension query, runnable in SQL*Plus |
| `grant_monitor.sql` | The two grants the monitoring user needs |
| `prepare_targets.sh` | Inventory, target preparation, `add_target` calls |
| `../test/oem_test.sh` | Offline test with a mock emcli |

Nothing here writes to AWR or to the suite's tables. `grant_monitor.sql`
makes two grants. `prepare_targets.sh` changes something only with
`--submit`.

## What was verified, and what is from documentation

Read this first. The hook was written against a live OMS (EM 24.1) with
read-only emcli verbs only (`list`, `get_targets`, `describe_job_type`,
`help`). Nothing was created in Enterprise Manager.

Verified:

- The query on Oracle 19.27: as a SQL*Plus script, and the extracted
  statement as one statement through `DBMS_SQL`, in an installed schema. That
  schema had no refresh run, so the alert rows were proven on synthetic rows
  (open, acknowledged, resolved, long key, multi-line message), not on stored
  ones.
- EM stores a metric key in 256 characters, a metric string value and an
  alert message in 4000 (the columns of `MGMT$METRIC_CURRENT` and
  `MGMT$ALERT_CURRENT`).
- Which emcli verbs exist (below), and the property keys of the SQLScript
  job type (`describe_job_type`).
- `prepare_targets.sh` in its list and print modes against the live
  inventory: the candidates, the standby and RAC instance rules, the
  addresses and global names.
- `grant_monitor.sql` up to its two `GRANT` statements (argument and object
  checks).

From Oracle's documentation (Cloud Control Monitoring Guide, "Creating a New
Metric Extension"), not run here:

- Every step of the metric extension wizard, the thresholds, the alert
  message variables, the test run, deployment and the incident rule.
- That a metric extension on a database target runs as the monitoring user
  (`dbsnmp`).

Not verified at all:

- The two `GRANT READ` statements and the query run as the monitoring user.
- `prepare_targets.sh --submit` against an OMS (mock only), and how
  Enterprise Manager shows a job step that ends with `AWRCAP-SKIP`.
- Whether Enterprise Manager clears an alert whose key is no longer in the
  result. The query does not depend on it: a closed alert stays in the
  result for 7 days with severity 0.

## 1. Alerts as incidents

### The query

`oem/awrcap_alerts.sql` reads the table `CAP_ALERT_STATE` and the view
`CAPR_RUNS`. Both hold stored rows, so a collection costs a table scan. The
alert states change when `cap_results.refresh` runs (`CAP_NIGHTLY_JOB`,
01:00) and when somebody acknowledges an alert (`cap_results.ack`).

| # | Column | EM column type | Value type | Content |
|---|---|---|---|---|
| 1 | `ALERT_KEY` | Key Column | String | The alert's `state_key` (kind, dbid, con_dbid, series, mode). Stable while the issue lasts. Over 200 characters it is cut to 167 plus `~` and its MD5 |
| 2 | `SEV_NUM` | Data Column | Number | 3 CRIT, 2 WARN, 1 INFO for an open alert nobody acknowledged, else 0 |
| 3 | `SEVERITY` | Data Column | String | `CRIT`, `WARN`, `INFO` or `CLEAR` |
| 4 | `KIND` | Data Column | String | The alert kind (`TBSPC_FULL`, `CPU_SAT`, ...) or `REFRESH_STALE` |
| 5 | `TARGET_NAME` | Data Column | String | The measured database |
| 6 | `DB_PDB` | Data Column | String | The database, plus `/` and the container for a PDB |
| 7 | `SERIES_KEY` | Data Column | String | The tablespace or series, `-` when the kind has none |
| 8 | `MESSAGE` | Data Column | String | The alert text, one line, at most 500 characters |

Rows:

- Every open alert that is not acknowledged, as in `CAPR_ALERTS_LATEST`.
- An alert that is acknowledged, or was resolved less than 7 days ago, with
  `SEV_NUM` 0 and `SEVERITY` `CLEAR`. Its message starts with `Acknowledged`
  or `Resolved <time>`. Enterprise Manager clears an alert when the threshold
  is no longer met, so the row has to stay for a while.
- One row with the key `REFRESH`. `SEV_NUM` is 2 when no OK refresh run ended
  inside `refresh_stale_hours` (36), or none ever ran. Without it a stopped
  nightly job looks like "no alerts".

See the rows in SQL*Plus:

```
SQL> @oem/awrcap_alerts.sql            -- as the owner, or SYSDBA with CURRENT_SCHEMA
SQL> @oem/awrcap_alerts.sql AWRCAP     -- as the monitoring user
```

### The grants

Enterprise Manager runs the query as the target's monitoring user, `DBSNMP`
unless the monitoring credentials name another. Where the suite is installed
(the owner's PDB, or the non-CDB), as the owner or as SYSDBA with
`CURRENT_SCHEMA` set to the owner:

```
SQL> @oem/grant_monitor.sql DBSNMP
```

It grants `READ` on `CAP_ALERT_STATE` and `CAPR_RUNS` and prints the two
`REVOKE` lines. `READ` allows a query and no `SELECT ... FOR UPDATE`. The
grants survive a re-install.

### Create the metric extension (console)

Steps from Oracle's documentation. No emcli verb creates a metric extension
from a definition.

1. **Enterprise > Monitoring > Metric Extensions > Create > Metric
   Extension.**
2. General properties. Target type: **Pluggable Database** when the owner
   lives in a PDB (the default), **Database Instance** for a non-CDB owner or
   an owner in CDB$ROOT. Name `AWRCAP_ALERTS` (EM prefixes `ME$`). Adapter:
   **SQL**.
3. Collection schedule: enabled, **Alerting Only**. The alert states change
   once a day, so collect once a day after the nightly job has ended
   (Repeat Every 1 Day, for example 04:00). Collect hourly instead if an
   acknowledgement should clear the incident soon. The collection is a table
   scan either way.
4. Adapter: paste the statement. Print it with the owner's name in it. It
   has no comment and no closing `;`:

   ```
   sed -n '/^-- ME-QUERY-BEGIN/,/^;$/p' oem/awrcap_alerts.sql \
     | sed -e '1d' -e '$d' -e 's/&cap_owner\.\./AWRCAP./g'
   ```

5. Columns: add the eight columns of the table above, in that order and with
   those names. `ALERT_KEY` is the only key column. Key columns are final
   once the draft is saved.
6. On `SEV_NUM`: Comparison Operator `>=`, Warning `2`, Critical `3`, Number
   of Occurrences Before Alert `1`, Manually Clearable Alert off. Alert
   message, for example:

   ```
   %MESSAGE% (%KIND%, %DB_PDB%, %SERIES_KEY%)
   ```

   The documentation lists `%columnName%`, `%keyValue%`, `%value%`,
   `%warning_threshold%`, `%critical_threshold%` and any other column's name
   between `%`. Use the same text as the clear message: the row then reads
   `Resolved ...` or `Acknowledged ...`. To raise INFO alerts as Warning, set
   Warning to `1`.
7. Credentials: keep the default monitoring credentials. For another user,
   create a monitoring credential set with `emcli create_credential_set` and
   run `grant_monitor.sql` for that user.
8. Test: add the repository database as a test target and **Run Test**. One
   row `REFRESH` at least must come back.
9. **Save As Deployable Draft**, then **Actions > Deploy To Targets** and
   choose the repository database. **Publish** when it is right.

### emcli, where a verb exists

Seen in the verb list of EM 24.1. None was run.

| Step | Verb |
|---|---|
| Carry the metric extension from one OMS to another | `export_metric_extension -file_name=awrcap.zip -target_type=oracle_pdb -name='ME$AWRCAP_ALERTS' -version=1`, then `import_metric_extension -file_name=awrcap.zip` |
| Editable to deployable draft | `save_metric_extension_draft -target_type=oracle_pdb -name='ME$AWRCAP_ALERTS' -version=1` |
| Publish | `publish_metric_extension -target_type=oracle_pdb -name='ME$AWRCAP_ALERTS' -version=1` |
| Deploy to targets | No verb. The console, or a monitoring template that holds the metric extension and `apply_template -name=... -targets="<pdb target>:oracle_pdb"` |
| Other monitoring user | `create_credential_set` |
| Collect now | `collect_metric`, read with `get_metric_data` |
| Carry an incident rule set | `export_incident_rule_set`, `import_incident_rule_set`, `add_target_to_rule_set` |

### The incident rule (console)

A metric alert becomes an incident only where a rule says so. The rule set
Oracle ships creates incidents for critical metric alerts. For Warning too:
**Setup > Incidents > Incident Rules > Create Rule Set**, targets: the
repository database. Add a rule for **Incoming events and updates to
events**, type **Metric Alert**, the metric `AWRCAP_ALERTS` / `SEV_NUM`,
severity Critical and Warning. Action: **Create Incident**, and notify as the
site does. Each `ALERT_KEY` is its own event, so one incident per alert.

### Day to day

- An incident clears when the suite resolves the alert, or when somebody
  acknowledges it: `EXEC cap_results.ack('<ALERT_KEY>', SYSDATE + 7, 'note')`.
  The key is the `state_key` unless it was shortened.
- `REFRESH_STALE` Warning: the nightly job stopped or fails. See
  `SELECT summary FROM capr_runs WHERE is_last = 'Y'` and doctor section 10.
- A resolved alert leaves the result after 7 days. Change the `7` in the
  statement for another window.

## 2. Targets from the inventory

`oem/prepare_targets.sh` needs bash 4.4 and an emcli session
(`emcli login`). It reads the inventory with one `emcli list -sql` on the
repository views `MGMT$TARGET`, `MGMT$TARGET_PROPERTIES`,
`MGMT$DB_DBNINSTANCEINFO` and `MGMT$AVAILABILITY_CURRENT`. The EM user needs
access to those views. `EMCLI` names the command (`emcli`, or `emx raw`).

```
oem/prepare_targets.sh                              # list the candidates
oem/prepare_targets.sh --targets prod1_db01,hr_db03 # print what to run
oem/prepare_targets.sh --match 'prod*' --out plan/  # the same, into files
oem/prepare_targets.sh --all --submit --db-cred NC_SYSDBA --host-cred NC_ORACLE
```

Candidates are the CDBs and non-CDBs: targets of type `oracle_database` that
are no RAC instance, and `rac_database`. A standby is listed and cannot be
selected: prepare its primary, the reader arrives with the redo. A target
that is not up is selected with a warning.

### Print mode (the default)

Changes nothing. Per selected target it prints the commands for its host:

```
sqlplus /nolog
  CONNECT / AS SYSDBA
  DEFINE reader = C##AWRRDR
  ACCEPT reader_pw CHAR PROMPT 'Password for the reader (not shown): ' HIDE
  @target/prepare.sql
  @target/check.sql
```

Then it prints `add_targets.sql` for the repository: one
`cap_repo.add_target` call per target, with the name, the address
`//host:port/service`, the reader and the global name.

- The repository name is the database's unique name in upper case. Two
  selected databases with the same name both get their host name appended
  (`HR_DB03`, `HR_DB04`).
- The address is the inventory's host and port and the default service
  (`DB_UNIQUE_NAME`, plus the domain when the inventory has one; a cluster
  database's `ServiceName`). `target/prepare.sql` prints the call with what
  it sees on the target. Where the two differ, that one is right. A cluster
  database wants its SCAN name, and the suite is untested on RAC.

### Submit mode

`--submit` creates one EM job of type SQLScript per target type. It runs
`target/prepare.sql` and `target/check.sql` on every selected target, as the
named SYSDBA credential `--db-cred` (host credential `--host-cred`). With
`--out DIR` the property files stay in DIR for review.

The job changes a database only where the reader does not exist yet. There
it creates the reader with a random password made on the server and shown
nowhere, and all its grants. Where the reader exists the script ends before
`prepare.sql` with a line `AWRCAP-SKIP`: `prepare.sql` would reset the
password and break the repository's link. To refresh an existing reader's
grants, run `prepare.sql` by hand.

Watch the job with `emcli get_jobs -name=AWRCAP_PREPARE%` and
`emcli get_job_execution_detail -execution=<id> -xml -showOutput`.

### Passwords

The script reads, writes and passes no password, in any mode. No generated
file and no command line holds one.

- **On a target, by hand:** `ACCEPT ... HIDE` asks at a prompt that does not
  echo, and `prepare.sql` uses the value.
- **After `--submit`:** nobody knows the new reader's password. Set the real
  one on the target: `sqlplus / as sysdba`, then `PASSWORD C##AWRRDR`. That
  command asks twice and does not echo.
- **On the repository:** `add_targets.sql` asks once with `ACCEPT ... HIDE`
  and hands the value to every `cap_repo.add_target` call.
  `--per-target-password` asks before each target. Run it in a terminal.

A typed password still travels to the server inside one statement
(`CREATE USER`, `add_target`). SQL*Plus has no way around that.

### Then

```
SQL> @add_targets.sql
SQL> EXEC cap_repo.collect
```

The first collect of a target copies all the AWR history it still holds.
`doctor.sql` section 11 checks every target afterwards.

## Test

```
test/oem_test.sh
```

No OMS and no database. A mock emcli serves a canned inventory and records
every call. It checks the selection, the generated commands and job files,
that no output or emcli argument holds a password, and that the statement
extracted for the metric extension is one plain `SELECT` with the eight
columns above.
