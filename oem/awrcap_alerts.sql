--
-- oem/awrcap_alerts.sql -- the suite's alert states for an Oracle Enterprise
-- Manager metric extension (oem/README.md).
-- =====================================================================
-- READ-ONLY: one SELECT over the table CAP_ALERT_STATE and the view
-- CAPR_RUNS. Both read stored rows only (no view over the AWR data is
-- evaluated), so a collection costs a table scan.
--
-- Run it in SQL*Plus to see what the metric extension will collect:
--   SQL> @oem/awrcap_alerts.sql            -- the current schema is the owner
--   SQL> @oem/awrcap_alerts.sql AWRCAP     -- as the monitoring user
-- (oem/grant_monitor.sql gives the monitoring user its two grants.)
--
-- The metric extension takes the statement between the line ME-QUERY-BEGIN
-- and the terminating ";" with the owner's name in place of the substitution
-- variable. Print it ready to paste (no comment, no ";", one statement):
--   sed -n '/^-- ME-QUERY-BEGIN/,/^;$/p' oem/awrcap_alerts.sql \
--     | sed -e '1d' -e '$d' -e 's/&cap_owner\.\./AWRCAP./g'
--
-- Rows (the column order is the metric extension's column order):
--   ALERT_KEY    key column. The alert's state_key (kind|dbid|con_dbid|
--                series|mode), stable for as long as the issue lasts. EM
--                keys hold 256 characters: a state_key over 200 is cut to
--                167 and ends in "~" and its MD5.
--   SEV_NUM      3 CRIT, 2 WARN, 1 INFO for an open alert nobody
--                acknowledged, else 0. Thresholds: >= 2 Warning, >= 3
--                Critical.
--   SEVERITY     CRIT / WARN / INFO, or CLEAR with SEV_NUM 0
--   KIND         the alert kind (TBSPC_FULL, CPU_SAT, ...), or REFRESH_STALE
--   TARGET_NAME  the measured database: db_pdb up to its "/"
--   DB_PDB       the database, plus "/" and the container for a PDB
--   SERIES_KEY   the tablespace or series, "-" when the kind has none
--   MESSAGE      one line, at most 500 characters
-- Three kinds of row:
--   * Every OPEN alert that is not acknowledged (the rule of CAPR_ALERTS_LATEST).
--   * An alert acknowledged, or resolved less than 7 days ago, with SEV_NUM 0.
--     EM clears an alert when its threshold is no longer met, so the row
--     stays for a while and says why. Change the 7 in the statement to keep
--     it for longer or shorter.
--   * One row REFRESH (kind REFRESH_STALE): SEV_NUM 2 when no OK refresh run
--     ended inside refresh_stale_hours (CAPR_RUNS.stale_run), or none ever
--     ran. The alert list is as old as the last refresh, so a stopped
--     nightly job would otherwise look like "no alerts".
--
SET APPINFO OFF
SET APPINFO "AWRCAP/oem/awrcap_alerts.sql"
SET DEFINE '&'
SET VERIFY   OFF
SET FEEDBACK OFF
SET TAB      OFF
SET LINESIZE 250
SET PAGESIZE 200
SET TRIMOUT  ON

SET TERMOUT OFF
COLUMN 1 NEW_VALUE 1 NOPRINT
SELECT NULL AS "1" FROM dual WHERE 1 = 0;
COLUMN cap_owner_in NEW_VALUE cap_owner NOPRINT
SELECT NVL(UPPER('&1'), SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')) AS cap_owner_in FROM dual;
COLUMN 1 CLEAR
COLUMN cap_owner_in CLEAR
SET TERMOUT ON

COLUMN alert_key   FORMAT A46 WORD_WRAPPED
COLUMN sev_num     FORMAT 9
COLUMN severity    FORMAT A8
COLUMN kind        FORMAT A16
COLUMN target_name FORMAT A14
COLUMN db_pdb      FORMAT A20
COLUMN series_key  FORMAT A24
COLUMN message     FORMAT A90 WORD_WRAPPED

-- ME-QUERY-BEGIN
SELECT alert_key, sev_num, severity, kind, target_name, db_pdb, series_key, message
FROM  (SELECT CASE WHEN LENGTH(s.state_key) <= 200 THEN s.state_key
                   ELSE SUBSTR(s.state_key, 1, 167) || '~'
                        || RAWTOHEX(STANDARD_HASH(s.state_key, 'MD5'))
              END                                                    AS alert_key,
              CASE WHEN s.state <> 'OPEN' OR s.ack_until > SYSDATE THEN 0
                   ELSE DECODE(s.cur_severity, 'CRIT', 3, 'WARN', 2, 1)
              END                                                    AS sev_num,
              CASE WHEN s.state <> 'OPEN' OR s.ack_until > SYSDATE THEN 'CLEAR'
                   ELSE NVL(s.cur_severity, 'INFO')
              END                                                    AS severity,
              NVL(s.kind, '-')                                       AS kind,
              NVL(REGEXP_SUBSTR(s.db_pdb, '^[^/]+'), '-')            AS target_name,
              NVL(s.db_pdb, '-')                                     AS db_pdb,
              NVL(s.series_key, '-')                                 AS series_key,
              SUBSTR(CASE WHEN s.state <> 'OPEN'
                          THEN 'Resolved ' || TO_CHAR(s.resolved_at, 'YYYY-MM-DD HH24:MI') || ': '
                          WHEN s.ack_until > SYSDATE
                          THEN 'Acknowledged'
                               || CASE WHEN s.ack_until < DATE '9999-01-01'
                                       THEN ' until ' || TO_CHAR(s.ack_until, 'YYYY-MM-DD HH24:MI')
                                  END
                               || ': '
                     END
                     || TRIM(REGEXP_REPLACE(s.last_message, '[[:space:]]+', ' ')), 1, 500)
                                                                     AS message
       FROM   &cap_owner..cap_alert_state s
       WHERE  s.state = 'OPEN'
          OR  s.resolved_at > SYSDATE - 7
       UNION ALL
       SELECT 'REFRESH',
              CASE WHEN r.stale = 'N' THEN 0 ELSE 2 END,
              CASE WHEN r.stale = 'N' THEN 'CLEAR' ELSE 'WARN' END,
              'REFRESH_STALE',
              '-',
              '-',
              '-',
              SUBSTR(CASE WHEN r.n_runs = 0
                          THEN 'No refresh run yet: the alert list is empty until'
                               || ' cap_results.refresh runs (CAP_NIGHTLY_JOB).'
                          WHEN r.stale = 'N'
                          THEN 'The last OK refresh run ended ' || r.age_hours
                               || ' hours ago. Last: ' || r.summary
                          ELSE 'No OK refresh run for '
                               || NVL(TO_CHAR(r.age_hours), 'any number of') || ' hours:'
                               || ' the alert list is that old. Last: ' || r.summary
                     END, 1, 500)
       FROM  (SELECT COUNT(*)                                             AS n_runs,
                     NVL(MAX(stale_run), 'Y')                             AS stale,
                     MAX(last_ok_age_hours)                               AS age_hours,
                     MAX(TRIM(REGEXP_REPLACE(summary, '[[:space:]]+', ' '))) AS summary
              FROM   &cap_owner..capr_runs
              WHERE  is_last = 'Y') r)
ORDER  BY sev_num DESC, alert_key
;

UNDEFINE 1 cap_owner
SET FEEDBACK ON
