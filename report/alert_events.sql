--
-- report/alert_events.sql -- the alert state changes after a position.
-- =====================================================================
-- Prints the CAPR_ALERT_EVENTS rows (NEW / ESCALATED / DEESCALATED /
-- RESOLVED / REOPENED, written by cap_results.refresh) after a given
-- event_id, one event per line, for a program to read. report/notify.sh is
-- that program: it mails or posts them and remembers the position.
-- READ-ONLY: only SELECTs (CAPR_ALERT_EVENTS, CAPV_TARGET, report/scope.sql).
-- Never prompts.
--
-- Run from the REPO ROOT:
--   SQL> @report/alert_events.sql                           -- the last 24 hours, WARN and worse
--   SQL> @report/alert_events.sql 2026111201030012300002    -- after that event
--   SQL> @report/alert_events.sql - 48 CRIT                 -- the last 48 hours, CRIT only
--   SQL> @report/alert_events.sql - - - NEW,RESOLVED CDB1   -- two transitions, one target
--   SQL> @report/alert_events.sql - - - - - - Y             -- acknowledged alerts too
-- Arguments, each optional, '-' skips one, UNDEFINEd at the end:
--   1 after_event_id  only events with a higher event_id. Without it: only
--                     events of the last since_hours.
--   2 since_hours     that window (default 24). Ignored with an after_event_id.
--   3 min_severity    INFO, WARN (default) or CRIT. An event passes when its
--                     severity or its previous severity is at least this, so
--                     a WARN that fell to INFO still counts as a WARN event.
--   4 transitions     comma list, no blanks (default NEW,ESCALATED,REOPENED)
--   5 dbid | target   one database (report/scope.sql; unknown name = ORA-20003)
--   6 con_dbid        one container
--   7 include_acked   Y: also the events of alerts that are acknowledged now
--                     (CAPR_ALERT_EVENTS.acked, cap_results.ack). Default N:
--                     they are skipped, and the position moves past them, so
--                     a later unack does not bring them back.
--
-- Output, three kinds of line, fields separated by one TAB:
--   AWRCAP_EVENTS_BEGIN  position  schema-on-database  generated-at
--   AWRCAP_EVENT  event_id  at_time  event  severity  prev_severity  target
--                 dbid  con_dbid  db_pdb  kind  series_key  baseline_mode
--                 state_key  alert_key  message
--   AWRCAP_EVENTS_END  number-of-event-lines
-- position is the highest event_id in CAP_ALERT_EVENT when the run started
-- (every database and kind, 0 for none; never below after_event_id). Events
-- above it are not printed, so "after position" on the next run misses
-- nothing and repeats nothing: event_id = run_id * 100000 + n and refresh
-- runs are serialised, so event_id order is commit order. A missing END line
-- means the output is incomplete.
-- In a field a backslash reads \\, a TAB \t, a line feed \n, a carriage
-- return \r, and any other control character a blank, so a line never
-- breaks and never starts with a quoted ORA- text. A NULL is an empty field.
-- at_time is the refresh time on the repository's clock, labelled Z like
-- every export. Events are ordered by target, then RESOLVED last, then
-- severity, then event_id. target is the CAPV_TARGET name of the dbid, else
-- the database part of db_pdb.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/report/alert_events.sql"
SET DEFINE '&'
SET VERIFY     OFF
SET FEEDBACK   OFF
SET ECHO       OFF
SET TERMOUT    OFF
SET TAB        OFF
SET TRIMOUT    ON
SET TRIMSPOOL  ON
SET LINESIZE   32767
SET PAGESIZE   0
WHENEVER SQLERROR CONTINUE

ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';

COLUMN 1 NEW_VALUE 1 NOPRINT
COLUMN 2 NEW_VALUE 2 NOPRINT
COLUMN 3 NEW_VALUE 3 NOPRINT
COLUMN 4 NEW_VALUE 4 NOPRINT
COLUMN 5 NEW_VALUE 5 NOPRINT
COLUMN 6 NEW_VALUE 6 NOPRINT
COLUMN 7 NEW_VALUE 7 NOPRINT
SELECT NULL AS "1", NULL AS "2", NULL AS "3", NULL AS "4", NULL AS "5", NULL AS "6", NULL AS "7"
FROM   dual WHERE 1 = 0;

-- Anything that is not a valid value reads as the default.
COLUMN ev_after NEW_VALUE cap_ev_after NOPRINT
COLUMN ev_since NEW_VALUE cap_ev_since NOPRINT
COLUMN ev_sev   NEW_VALUE cap_ev_sev   NOPRINT
COLUMN ev_trans NEW_VALUE cap_ev_trans NOPRINT
COLUMN ev_acked NEW_VALUE cap_ev_acked NOPRINT
COLUMN cap_a1   NEW_VALUE cap_arg_db   NOPRINT
COLUMN cap_a2   NEW_VALUE cap_arg_con  NOPRINT
SELECT NVL(REGEXP_SUBSTR(TRIM('&1'), '^[0-9]{1,30}$'), 'NULL')              AS ev_after,
       NVL(REGEXP_SUBSTR(TRIM('&2'), '^[0-9]{1,6}$'), '24')                 AS ev_since,
       CASE UPPER(TRIM('&3')) WHEN 'CRIT' THEN '1' WHEN 'INFO' THEN '3' ELSE '2' END AS ev_sev,
       NVL(REGEXP_SUBSTR(UPPER(TRIM('&4')), '^[A-Z]+(,[A-Z]+)*$'),
           'NEW,ESCALATED,REOPENED')                                        AS ev_trans,
       CASE UPPER(TRIM('&7')) WHEN 'Y' THEN 'Y' ELSE 'N' END                AS ev_acked,
       NVL(TRIM('&5'), '-')                                                 AS cap_a1,
       NVL(TRIM('&6'), '-')                                                 AS cap_a2
FROM   dual;
@@report/scope.sql
COLUMN 1 CLEAR
COLUMN 2 CLEAR
COLUMN 3 CLEAR
COLUMN 4 CLEAR
COLUMN 5 CLEAR
COLUMN 6 CLEAR
COLUMN 7 CLEAR
COLUMN ev_after CLEAR
COLUMN ev_since CLEAR
COLUMN ev_sev   CLEAR
COLUMN ev_trans CLEAR
COLUMN ev_acked CLEAR
COLUMN cap_a1   CLEAR
COLUMN cap_a2   CLEAR

SET TERMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT TRUNCATED
DECLARE
    c_tab   CONSTANT VARCHAR2(1) := CHR(9);
    l_after NUMBER := &cap_ev_after;
    l_pos   NUMBER;
    l_n     PLS_INTEGER := 0;

    FUNCTION esc(p IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN REGEXP_REPLACE(
                   REPLACE(REPLACE(REPLACE(REPLACE(p, '\', '\\'), CHR(9), '\t'), CHR(10), '\n'), CHR(13), '\r'),
                   '[[:cntrl:]]', ' ');
    END esc;
BEGIN
    -- The position first: a refresh that commits after this line is the
    -- next run's, whole.
    SELECT GREATEST(NVL(MAX(event_id), 0), NVL(l_after, 0)) INTO l_pos FROM capr_alert_events;
    DBMS_OUTPUT.PUT_LINE('AWRCAP_EVENTS_BEGIN' || c_tab || TO_CHAR(l_pos, 'TM9')
                         || c_tab || esc('&cap_user') || c_tab || esc('&cap_gen'));
    FOR r IN (SELECT e.event_id, e.at_time, e.event, e.severity, e.prev_severity,
                     COALESCE(t.target_name, REGEXP_SUBSTR(e.db_pdb, '^[^/]+'),
                              CASE WHEN e.dbid IS NOT NULL THEN 'dbid ' || TO_CHAR(e.dbid, 'TM9') END,
                              'unknown')                                      AS target,
                     e.dbid, e.con_dbid, e.db_pdb, e.kind, e.series_key, e.baseline_mode,
                     e.state_key, e.alert_key, e.message
              FROM   capr_alert_events e
              LEFT   JOIN (SELECT dbid, MIN(target_name) AS target_name
                           FROM   capv_target
                           WHERE  dbid IS NOT NULL
                           GROUP  BY dbid) t
                ON   t.dbid = e.dbid
              WHERE  e.event_id > NVL(l_after, 0)
                AND  e.event_id <= l_pos
                AND  (l_after IS NOT NULL OR e.at_time >= SYSDATE - &cap_ev_since / 24)
                AND  INSTR(',&cap_ev_trans,', ',' || e.event || ',') > 0
                AND  LEAST(DECODE(e.severity, 'CRIT', 1, 'WARN', 2, 3),
                           DECODE(e.prev_severity, 'CRIT', 1, 'WARN', 2, 3)) <= &cap_ev_sev
                AND  ('&cap_ev_acked' = 'Y' OR e.acked = 'N')
                AND  (&cap_sdbid IS NULL OR e.dbid = &cap_sdbid)
                AND  (&cap_scon  IS NULL OR e.con_dbid = &cap_scon)
              ORDER  BY 6, DECODE(e.event, 'RESOLVED', 1, 0),
                        DECODE(e.severity, 'CRIT', 1, 'WARN', 2, 3), e.event_id) LOOP
        l_n := l_n + 1;
        DBMS_OUTPUT.PUT_LINE('AWRCAP_EVENT'
            || c_tab || TO_CHAR(r.event_id, 'TM9')
            || c_tab || TO_CHAR(r.at_time, 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
            || c_tab || esc(r.event)
            || c_tab || esc(r.severity)
            || c_tab || esc(r.prev_severity)
            || c_tab || esc(r.target)
            || c_tab || TO_CHAR(r.dbid, 'TM9')
            || c_tab || TO_CHAR(r.con_dbid, 'TM9')
            || c_tab || esc(r.db_pdb)
            || c_tab || esc(r.kind)
            || c_tab || esc(r.series_key)
            || c_tab || esc(r.baseline_mode)
            || c_tab || esc(r.state_key)
            || c_tab || esc(r.alert_key)
            || c_tab || esc(r.message));
    END LOOP;
    DBMS_OUTPUT.PUT_LINE('AWRCAP_EVENTS_END' || c_tab || TO_CHAR(l_n));
END;
/
SET SERVEROUTPUT OFF

-- The scope report/scope.sql set would otherwise outlive this script.
EXEC DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL)

UNDEFINE 1 2 3 4 5 6 7
UNDEFINE cap_ev_after cap_ev_since cap_ev_sev cap_ev_trans cap_ev_acked
