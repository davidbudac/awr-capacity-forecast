--
-- ddl/60_results.sql -- the results layer: run history, alert state, events.
-- =====================================================================
-- The suite writes only to CAP_* tables it owns, never to AWR. Operator
-- tables (CAP_CONFIG, CAP_TBSPC_OVERRIDE) survive re-install; derived tables
-- (CAP_ML_MODEL, and the four below) are a cache that a re-install also keeps
-- but that the live views never need. The live CAPR_* views stay the one
-- tested definition of every number: this layer only snapshots them.
--
--   CAP_RUN          one row per CAP_RESULTS.refresh call (RUNNING, then OK or
--                    FAILED with error_text), with CAPR_COVERAGE as it was
--                    at the run (cov_n_dbid, cov_n_current, cov_summary)
--   CAP_FIT_HIST     CAPR_FIT as it was at each run, keyed (run_id, kind,
--                    dbid, con_dbid, series)
--   CAP_ALERT_STATE  one row per CAPR_ALERTS state_key: OPEN / RESOLVED,
--                    first / last seen, severities, the operator's ack
--   CAP_ALERT_EVENT  NEW / ESCALATED / DEESCALATED / RESOLVED / REOPENED, one
--                    row per state change, event_id = run_id * 100000 + n
--
--   <view>_S         one per view in cap_results.snap_views: snap_run_id and
--                    the view's columns, the newest OK run's rows. A cache,
--                    not persisted: every install drops and re-creates them
--                    (cap_results.build_snap_tables, end of this file), so
--                    they always match the views; the next refresh fills
--                    them. The SNAPSHOT reports read them.
--
-- Only the CAP_RESULTS package (bottom of this file) writes them. The views
-- over them never break on empty tables, so an install that never ran
-- refresh still installs and reports.
--
--   CAPR_ALERTS_LATEST     OPEN, not acked states: the poller's state view
--   CAPR_ALERT_EVENTS      events newest first, with the run's as_of_day
--   CAPR_RUNS              runs + is_last + the stale_run flag
--   CAPR_COVERAGE          per dbid: snapshot age, history, series by
--                          quality, the retired flag (live; every refresh
--                          run keeps its roll-up on CAP_RUN)
--   CAPR_FIT_HISTORY       CAP_FIT_HIST of the OK runs
--   CAPR_WEEKLY_DIGEST     latest run vs the latest run digest_days older
--   CAPR_FORECAST_ACCURACY issued forecasts vs today's actual values
--   CAPR_FIT_TRACK         per series of the newest OK run: how its stored
--                          forecasts fared, the band factor and reliability
--
-- Tables: created with their key columns, then every other column is added
-- one at a time (ORA-01430 = already there), so an older install gains new
-- columns on re-install and the column list lives in one place. ddl/00_drop
-- never drops them; uninstall.sql does.
--
SET DEFINE OFF

DECLARE
    PROCEDURE create_tab(p_ddl VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_ddl;
    EXCEPTION
        WHEN OTHERS THEN IF SQLCODE != -955 THEN RAISE; END IF;
    END;
    PROCEDURE add_col(p_tab VARCHAR2, p_def VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE ' || p_tab || ' ADD (' || p_def || ')';
    EXCEPTION
        WHEN OTHERS THEN IF SQLCODE != -1430 THEN RAISE; END IF;
    END;
    -- ORA-00904 old name absent (fresh install or already renamed),
    -- ORA-00957 new name already present.
    PROCEDURE rename_col(p_tab VARCHAR2, p_old VARCHAR2, p_new VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'ALTER TABLE ' || p_tab || ' RENAME COLUMN ' || p_old || ' TO ' || p_new;
    EXCEPTION
        WHEN OTHERS THEN IF SQLCODE NOT IN (-904, -957) THEN RAISE; END IF;
    END;
    -- ORA-00955 name used, ORA-01408 column list already indexed.
    PROCEDURE add_ix(p_ddl VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_ddl;
    EXCEPTION
        WHEN OTHERS THEN IF SQLCODE NOT IN (-955, -1408) THEN RAISE; END IF;
    END;
BEGIN
    -- ---- CAP_RUN ----
    create_tab('CREATE TABLE cap_run (run_id NUMBER CONSTRAINT cap_run_pk PRIMARY KEY)');
    add_col('cap_run', 'as_of_day  DATE');
    rename_col('cap_run', 'seam_mode', 'deploy_mode');
    add_col('cap_run', 'deploy_mode VARCHAR2(16)');
    add_col('cap_run', 'started_at TIMESTAMP');
    add_col('cap_run', 'ended_at   TIMESTAMP');
    add_col('cap_run', 'status     VARCHAR2(8)');
    add_col('cap_run', 'backdated  CHAR(1)');
    add_col('cap_run', 'n_fit      NUMBER');
    add_col('cap_run', 'n_alert    NUMBER');
    add_col('cap_run', 'n_anom     NUMBER');
    add_col('cap_run', 'n_event    NUMBER');
    add_col('cap_run', 'error_text VARCHAR2(4000)');
    add_col('cap_run', 'run_by     VARCHAR2(128)');
    add_col('cap_run', 'cov_n_dbid    NUMBER');
    add_col('cap_run', 'cov_n_current NUMBER');
    add_col('cap_run', 'cov_summary   VARCHAR2(4000)');

    -- ---- CAP_FIT_HIST: run_id, as_of_day + every CAPR_FIT column ----
    create_tab('CREATE TABLE cap_fit_hist (
        run_id   NUMBER        NOT NULL,
        kind     VARCHAR2(16)  NOT NULL,
        dbid     NUMBER        NOT NULL,
        con_dbid NUMBER        NOT NULL,
        series   VARCHAR2(256) NOT NULL,
        CONSTRAINT cap_fit_hist_pk PRIMARY KEY (run_id, kind, dbid, con_dbid, series))');
    add_col('cap_fit_hist', 'as_of_day          DATE');
    add_col('cap_fit_hist', 'db                 VARCHAR2(512)');
    add_col('cap_fit_hist', 'db_name            VARCHAR2(128)');
    add_col('cap_fit_hist', 'con_name           VARCHAR2(128)');
    add_col('cap_fit_hist', 'unit               VARCHAR2(32)');
    add_col('cap_fit_hist', 'method             VARCHAR2(16)');
    add_col('cap_fit_hist', 'value              NUMBER');
    add_col('cap_fit_hist', 'limit_value        NUMBER');
    add_col('cap_fit_hist', 'pct                NUMBER');
    add_col('cap_fit_hist', 'slope_per_day      NUMBER');
    add_col('cap_fit_hist', 'r2                 NUMBER');
    add_col('cap_fit_hist', 'quality            VARCHAR2(32)');
    add_col('cap_fit_hist', 'days_to_full       NUMBER');
    add_col('cap_fit_hist', 'days_to_full_lo    NUMBER');
    add_col('cap_fit_hist', 'days_to_full_hi    NUMBER');
    add_col('cap_fit_hist', 'accel              NUMBER');
    add_col('cap_fit_hist', 'train_n            NUMBER');
    add_col('cap_fit_hist', 'sev                VARCHAR2(8)');
    add_col('cap_fit_hist', 'sev_rank           NUMBER');
    add_col('cap_fit_hist', 'limit_source       VARCHAR2(16)');
    add_col('cap_fit_hist', 'last_day           DATE');
    add_col('cap_fit_hist', 'is_current         NUMBER');
    add_col('cap_fit_hist', 'limit_below_used   NUMBER');
    add_col('cap_fit_hist', 'cycle_n            NUMBER');
    add_col('cap_fit_hist', 'cycle_days         NUMBER');
    add_col('cap_fit_hist', 'cycle_peak_pct     NUMBER');
    add_col('cap_fit_hist', 'peak_slope_per_day NUMBER');
    add_col('cap_fit_hist', 'slope_sig          NUMBER');
    add_col('cap_fit_hist', 'hot_now            NUMBER');
    add_col('cap_fit_hist', 'need_gib_30        NUMBER');
    add_col('cap_fit_hist', 'need_gib_90        NUMBER');
    add_col('cap_fit_hist', 'need_gib_180       NUMBER');
    add_col('cap_fit_hist', 'add_by_day         DATE');
    add_col('cap_fit_hist', 'restart_reason     VARCHAR2(5)');
    add_col('cap_fit_hist', 'restart_day        DATE');
    add_ix('CREATE INDEX cap_fit_hist_day_ix ON cap_fit_hist (as_of_day)');

    -- ---- CAP_ALERT_STATE ----
    create_tab('CREATE TABLE cap_alert_state (
        state_key VARCHAR2(400) CONSTRAINT cap_alert_state_pk PRIMARY KEY)');
    add_col('cap_alert_state', 'kind            VARCHAR2(16)');
    add_col('cap_alert_state', 'dbid            NUMBER');
    add_col('cap_alert_state', 'con_dbid        NUMBER');
    add_col('cap_alert_state', 'db_pdb          VARCHAR2(512)');
    add_col('cap_alert_state', 'series_key      VARCHAR2(256)');
    add_col('cap_alert_state', 'baseline_mode   VARCHAR2(12)');
    add_col('cap_alert_state', 'state           VARCHAR2(8)');
    add_col('cap_alert_state', 'first_seen      DATE');
    add_col('cap_alert_state', 'last_seen       DATE');
    add_col('cap_alert_state', 'cur_severity    VARCHAR2(4)');
    add_col('cap_alert_state', 'max_severity    VARCHAR2(4)');
    add_col('cap_alert_state', 'resolved_at     DATE');
    add_col('cap_alert_state', 'reopen_count    NUMBER');
    add_col('cap_alert_state', 'missed_runs     NUMBER');
    add_col('cap_alert_state', 'last_run_id     NUMBER');
    add_col('cap_alert_state', 'last_alert_key  VARCHAR2(400)');
    add_col('cap_alert_state', 'last_day        DATE');
    add_col('cap_alert_state', 'last_value      NUMBER');
    add_col('cap_alert_state', 'last_threshold  NUMBER');
    add_col('cap_alert_state', 'last_alarm      NUMBER');
    add_col('cap_alert_state', 'last_direction  VARCHAR2(3)');
    add_col('cap_alert_state', 'last_unit       VARCHAR2(8)');
    add_col('cap_alert_state', 'last_message    VARCHAR2(4000)');
    add_col('cap_alert_state', 'last_first_day  DATE');
    add_col('cap_alert_state', 'last_n_days     NUMBER');
    add_col('cap_alert_state', 'last_max_z      NUMBER');
    add_col('cap_alert_state', 'ack_until       DATE');
    add_col('cap_alert_state', 'ack_note        VARCHAR2(400)');
    add_col('cap_alert_state', 'ack_by          VARCHAR2(128)');
    add_col('cap_alert_state', 'acked_at        DATE');

    -- ---- CAP_ALERT_EVENT ----
    create_tab('CREATE TABLE cap_alert_event (event_id NUMBER CONSTRAINT cap_alert_event_pk PRIMARY KEY)');
    add_col('cap_alert_event', 'run_id        NUMBER');
    add_col('cap_alert_event', 'state_key     VARCHAR2(400)');
    add_col('cap_alert_event', 'alert_key     VARCHAR2(400)');
    add_col('cap_alert_event', 'event         VARCHAR2(12)');
    add_col('cap_alert_event', 'at_time       DATE');
    add_col('cap_alert_event', 'severity      VARCHAR2(4)');
    add_col('cap_alert_event', 'prev_severity VARCHAR2(4)');
    add_col('cap_alert_event', 'message       VARCHAR2(4000)');
    add_ix('CREATE INDEX cap_alert_event_run_ix ON cap_alert_event (run_id)');
    add_ix('CREATE INDEX cap_alert_event_key_ix ON cap_alert_event (state_key)');

    -- ---- CAP_FIT_HIST: the +30 projection and its 95% band, as issued ----
    -- Not CAPR_FIT columns: refresh takes them from CAPR_FORECAST_POINTS
    -- (REGR, horizon 30). CAPR_FIT_TRACK checks them against later runs.
    -- Rows of runs before these columns have none.
    add_col('cap_fit_hist', 'proj_30            NUMBER');
    add_col('cap_fit_hist', 'proj_30_lo         NUMBER');
    add_col('cap_fit_hist', 'proj_30_hi         NUMBER');
END;
/

COMMENT ON TABLE cap_run         IS 'Results layer: one row per CAP_RESULTS.refresh call. status RUNNING / OK / FAILED.';
COMMENT ON TABLE cap_fit_hist    IS 'Results layer: CAPR_FIT snapshotted by every refresh run (run_id, as_of_day + every CAPR_FIT column).';
COMMENT ON TABLE cap_alert_state IS 'Results layer: one row per CAPR_ALERTS state_key. state OPEN / RESOLVED, first / last seen, severities, ack.';
COMMENT ON TABLE cap_alert_event IS 'Results layer: alert state changes (NEW, ESCALATED, DEESCALATED, RESOLVED, REOPENED) per refresh run.';
COMMENT ON COLUMN cap_run.as_of_day         IS 'The day the run is as of. Before today = a backdated run: fits only, no alert state.';
COMMENT ON COLUMN cap_run.backdated         IS 'Y when as_of_day is before the day the run executed.';
COMMENT ON COLUMN cap_run.cov_n_dbid        IS 'CAPR_COVERAGE rows (dbids) at the run.';
COMMENT ON COLUMN cap_run.cov_n_current     IS 'CAPR_COVERAGE rows with retired = N at the run.';
COMMENT ON COLUMN cap_run.cov_summary       IS 'CAPR_COVERAGE summaries at the run, by dbid, joined with '' | ''. CAPR_RUNS shows it.';
COMMENT ON COLUMN cap_fit_hist.proj_30      IS 'The REGR projection at last_day + 30 as the run issued it (CAPR_FORECAST_POINTS, horizon 30). NULL without a fit, and on runs that predate the column.';
COMMENT ON COLUMN cap_fit_hist.proj_30_lo   IS 'Lower edge of its 95% band. CAPR_FIT_TRACK checks later values against the band.';
COMMENT ON COLUMN cap_fit_hist.proj_30_hi   IS 'Upper edge of its 95% band.';
COMMENT ON COLUMN cap_alert_state.missed_runs IS 'Consecutive live runs the key was missing from CAPR_ALERTS; resolve_grace_runs of them resolve it.';
COMMENT ON COLUMN cap_alert_state.ack_until IS 'Acknowledged until this time (CAP_RESULTS.ack). 9999-12-31 = until it resolves. CAPR_ALERTS_LATEST hides it until then.';

-- --------------------------------------------------------------------
-- CAPR_ALERTS_LATEST -- the OPEN alert states that nobody acknowledged, as
-- of the last refresh run. The first fifteen columns mirror CAPR_ALERTS
-- (with the values of the last run that saw the key), so a poller can switch
-- between the live view and this one. Then the state:
--   max_severity  worst severity since first_seen
--   first_seen, last_seen  refresh times (DATE) the key was first and last
--                 present; age_days = SYSDATE - first_seen
--   reopen_count  how many times it came back after a RESOLVED
--   events_since  events of this key since it last opened (its NEW or
--                 REOPENED included); last_event, last_event_at the newest
--   first_day, n_days, max_z  CAPR_ALERTS' episode columns as the last run
--                 saw them (anomaly kinds only), so the SNAPSHOT reports
--                 print episodes as the live ones do
-- Reads only CAP_ALERT_STATE and CAP_ALERT_EVENT, so it costs a table scan,
-- not an evaluation of the view chain.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_alerts_latest AS
WITH ev AS (
        SELECT state_key,
               COUNT(*)                                              AS events_since,
               MAX(event) KEEP (DENSE_RANK LAST ORDER BY event_id)   AS last_event,
               MAX(at_time)                                          AS last_event_at
        FROM  (SELECT e.state_key, e.event_id, e.event, e.at_time,
                      MAX(CASE WHEN e.event IN ('NEW', 'REOPENED') THEN e.event_id END)
                          OVER (PARTITION BY e.state_key)            AS open_id
               FROM   cap_alert_event e)
        WHERE  event_id >= NVL(open_id, 0)
        GROUP  BY state_key
     )
SELECT s.cur_severity                                   AS severity,
       DECODE(s.cur_severity, 'CRIT', 1, 'WARN', 2, 3)  AS sev_rank,
       s.kind,
       s.dbid,
       s.con_dbid,
       s.db_pdb,
       s.series_key,
       s.last_day                                       AS day_dt,
       s.last_value                                     AS value,
       s.last_threshold                                 AS threshold,
       s.last_unit                                      AS unit,
       s.last_message                                   AS message,
       s.baseline_mode,
       s.last_alert_key                                 AS alert_key,
       s.state_key,
       s.last_direction                                 AS direction,
       s.last_alarm                                     AS alarm_threshold,
       s.max_severity,
       s.first_seen,
       s.last_seen,
       ROUND(SYSDATE - s.first_seen, 2)                 AS age_days,
       s.reopen_count,
       s.last_run_id                                    AS run_id,
       NVL(ev.events_since, 0)                          AS events_since,
       ev.last_event,
       ev.last_event_at,
       s.last_first_day                                 AS first_day,
       s.last_n_days                                    AS n_days,
       s.last_max_z                                     AS max_z
FROM   cap_alert_state s
LEFT   JOIN ev ON ev.state_key = s.state_key
WHERE  s.state = 'OPEN'
  AND  (s.ack_until IS NULL OR s.ack_until <= SYSDATE);

-- --------------------------------------------------------------------
-- CAPR_ALERT_EVENTS -- every alert state change, newest first. A poller
-- remembers the highest event_id (or run_id) it has seen and asks
--   SELECT * FROM capr_alert_events WHERE run_id > :last_run_id
-- as_of_day is the run's. prev_severity is the severity before the event
-- (NULL on NEW). Refreshes are serialised for their whole lifetime, so
-- run_id order equals commit order and the poller never skips a run.
-- acked (last column) is the alert's state NOW, not at the event: Y while
-- an acknowledgement is in force (CAP_ALERT_STATE.ack_until in the future,
-- the test CAPR_ALERTS_LATEST hides a row by), else N, also for an event
-- whose state row was purged. report/notify.sh skips the Y rows.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_alert_events AS
SELECT e.event_id,
       e.run_id,
       r.as_of_day,
       e.at_time,
       e.event,
       e.severity,
       e.prev_severity,
       s.kind,
       s.dbid,
       s.con_dbid,
       s.db_pdb,
       s.series_key,
       s.baseline_mode,
       e.state_key,
       e.alert_key,
       e.message,
       CASE WHEN s.ack_until > SYSDATE THEN 'Y' ELSE 'N' END AS acked
FROM   cap_alert_event e
LEFT   JOIN cap_run r         ON r.run_id = e.run_id
LEFT   JOIN cap_alert_state s ON s.state_key = e.state_key
ORDER  BY e.event_id DESC;

-- --------------------------------------------------------------------
-- CAPR_RUNS -- CAP_RUN plus the freshness of the refresh itself.
--   duration_sec       ended_at - started_at
--   is_last            'Y' on the newest run (highest run_id)
--   last_ok_run_id     the newest OK live (not backdated) run
--   last_ok_age_hours  hours since it ended, the same on every row
--   stale_run          'Y' when that is refresh_stale_hours or more, or no
--                      OK live run exists: a stalled job, visible
--   summary            one line, e.g. 'refresh run 20261017013000123 at
--                      2026-10-17 01:30 (13 alerts, 36 fits)'
--   cov_n_dbid, cov_n_current, cov_summary
--                      CAPR_COVERAGE at the run (CAP_RUN columns; NULL on a
--                      run that is not OK or predates them)
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_runs AS
WITH lr AS (
        SELECT MAX(run_id)                                                  AS last_run_id,
               MAX(CASE WHEN status = 'OK' AND backdated = 'N' THEN run_id END) AS last_ok_id
        FROM   cap_run
     ),
     lok AS (
        SELECT CAST(r.ended_at AS DATE) AS ended
        FROM   cap_run r JOIN lr ON r.run_id = lr.last_ok_id
     )
SELECT r.run_id,
       r.as_of_day,
       r.deploy_mode,
       r.started_at,
       r.ended_at,
       EXTRACT(DAY    FROM (r.ended_at - r.started_at)) * 86400
         + EXTRACT(HOUR   FROM (r.ended_at - r.started_at)) * 3600
         + EXTRACT(MINUTE FROM (r.ended_at - r.started_at)) * 60
         + EXTRACT(SECOND FROM (r.ended_at - r.started_at))              AS duration_sec,
       r.status,
       r.backdated,
       r.n_fit,
       r.n_alert,
       r.n_anom,
       r.n_event,
       r.error_text,
       r.run_by,
       CASE WHEN r.run_id = lr.last_run_id THEN 'Y' ELSE 'N' END          AS is_last,
       lr.last_ok_id                                                      AS last_ok_run_id,
       ROUND((SYSDATE - lok.ended) * 24, 2)                               AS last_ok_age_hours,
       CASE WHEN lok.ended IS NULL OR (SYSDATE - lok.ended) * 24 >= cfg.refresh_stale_hours
            THEN 'Y' ELSE 'N' END                                         AS stale_run,
       'refresh run ' || r.run_id || ' at ' || TO_CHAR(r.started_at, 'YYYY-MM-DD HH24:MI')
         || CASE WHEN r.status = 'OK' AND r.backdated = 'Y'
                 THEN ' (backdated as of ' || TO_CHAR(r.as_of_day, 'YYYY-MM-DD') || ', '
                      || r.n_fit || ' fits, no alert state)'
                 WHEN r.status = 'OK'
                 THEN ' (' || r.n_alert || ' alerts, ' || r.n_fit || ' fits)'
                 WHEN r.status = 'RUNNING'
                 THEN ' still RUNNING'
                 ELSE ' FAILED: ' || SUBSTR(REGEXP_SUBSTR(r.error_text, '[^' || CHR(10) || ']+'), 1, 200)
            END                                                           AS summary,
       r.cov_n_dbid,
       r.cov_n_current,
       r.cov_summary
FROM   cap_run r
CROSS  JOIN lr
LEFT   JOIN lok ON 1 = 1
CROSS  JOIN cap_cfg cfg;

-- --------------------------------------------------------------------
-- CAPR_COVERAGE -- one row per dbid: what the suite can see, read live.
--   newest_snap, age_hours, is_stale  from CAPR_FRESHNESS
--   history_days  newest minus oldest snapshot day, plus one
--   retired       'Y' when age_hours >= data_stale_max_days * 24: an
--                 imported or decommissioned DBID. CAPR_ALERTS raises no
--                 DATA_STALE for it; this row keeps it visible.
--   n_series      CAPR_FIT rows of the dbid, then split by quality
--                 (n_other = any grade not named here)
--   n_stale       series with is_current = 0
--   summary       the one line the reports print
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_coverage AS
WITH snap AS (
        SELECT dbid, TRUNC(CAST(MIN(end_interval_time) AS DATE)) AS oldest_day
        FROM   capv_snapshot
        GROUP  BY dbid
     ),
     fit AS (
        SELECT dbid,
               COUNT(*)                                                       AS n_series,
               COUNT(CASE WHEN quality = 'OK'                   THEN 1 END)   AS n_ok,
               COUNT(CASE WHEN quality = 'LOW_CONFIDENCE'       THEN 1 END)   AS n_low_confidence,
               COUNT(CASE WHEN quality = 'FLAT'                 THEN 1 END)   AS n_flat,
               COUNT(CASE WHEN quality = 'INSUFFICIENT_HISTORY' THEN 1 END)   AS n_insufficient,
               COUNT(CASE WHEN quality = 'CYCLIC'               THEN 1 END)   AS n_cyclic,
               COUNT(CASE WHEN is_current = 0                   THEN 1 END)   AS n_stale
        FROM   capr_fit
        GROUP  BY dbid
     ),
     c AS (
        SELECT f.dbid,
               f.db_name,
               f.newest_snap,
               ROUND(f.age_hours, 1)                                          AS age_hours,
               TRUNC(f.newest_snap) - s.oldest_day + 1                        AS history_days,
               f.is_stale,
               CASE WHEN f.age_hours >= cfg.data_stale_max_days * 24
                    THEN 'Y' ELSE 'N' END                                     AS retired,
               NVL(t.n_series, 0)                                             AS n_series,
               NVL(t.n_ok, 0)                                                 AS n_ok,
               NVL(t.n_low_confidence, 0)                                     AS n_low_confidence,
               NVL(t.n_flat, 0)                                               AS n_flat,
               NVL(t.n_insufficient, 0)                                       AS n_insufficient,
               NVL(t.n_cyclic, 0)                                             AS n_cyclic,
               NVL(t.n_series, 0) - NVL(t.n_ok, 0) - NVL(t.n_low_confidence, 0) - NVL(t.n_flat, 0)
                 - NVL(t.n_insufficient, 0) - NVL(t.n_cyclic, 0)              AS n_other,
               NVL(t.n_stale, 0)                                              AS n_stale
        FROM   capr_freshness f
        JOIN   snap s ON s.dbid = f.dbid
        LEFT   JOIN fit t ON t.dbid = f.dbid
        CROSS  JOIN cap_cfg cfg
     )
SELECT c.*,
       c.db_name || ' (dbid ' || c.dbid || '): '
         || CASE WHEN c.retired = 'Y'
                 THEN 'RETIRED, no snapshot for ' || TO_CHAR(FLOOR(c.age_hours / 24)) || ' days'
                 WHEN c.is_stale = 'Y'
                 THEN 'STALE, no snapshot for ' || TO_CHAR(c.age_hours, 'FM9999990.0') || ' h'
                 ELSE 'current'
            END
         || ', ' || c.history_days || ' days of AWR, ' || c.n_series || ' series ('
         || c.n_ok || ' OK, ' || c.n_low_confidence || ' low confidence, ' || c.n_flat || ' flat, '
         || c.n_insufficient || ' short history, ' || c.n_cyclic || ' cyclic'
         || CASE WHEN c.n_other > 0 THEN ', ' || c.n_other || ' other' END
         || '), ' || c.n_stale || ' not current'                              AS summary
FROM   c;

-- --------------------------------------------------------------------
-- CAPR_FIT_HISTORY -- CAP_FIT_HIST of the OK runs, with the run's start
-- time and backdated flag. Same columns as CAPR_FIT after the run columns.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_fit_history AS
SELECT h.run_id,
       h.as_of_day,
       r.started_at AS run_started_at,
       r.backdated,
       h.dbid, h.con_dbid, h.db, h.db_name, h.con_name, h.kind, h.series, h.unit, h.method,
       h.value, h.limit_value, h.pct, h.slope_per_day, h.r2, h.quality,
       h.days_to_full, h.days_to_full_lo, h.days_to_full_hi, h.accel, h.train_n,
       h.sev, h.sev_rank, h.limit_source, h.last_day, h.is_current, h.limit_below_used,
       h.cycle_n, h.cycle_days, h.cycle_peak_pct, h.peak_slope_per_day, h.slope_sig, h.hot_now,
       h.need_gib_30, h.need_gib_90, h.need_gib_180, h.add_by_day,
       h.restart_reason, h.restart_day
FROM   cap_fit_hist h
JOIN   cap_run r ON r.run_id = h.run_id
WHERE  r.status = 'OK';

-- --------------------------------------------------------------------
-- CAPR_WEEKLY_DIGEST -- "what changed since last week". The latest OK run
-- (by as_of_day, then run_id) against the latest OK run whose as_of_day is
-- at least digest_days earlier; no such pair, no rows. One row per series in
-- either run, plus one per alerted series without a fit (kind OTHER:
-- DATA_STALE, MODEL_HEALTH):
--   dtf_then / dtf_now / dtf_delta   days_to_full (CAPR_FIT's: days to the
--                                    series' ceiling), now minus then
--   pct_*, quality_*, sev_*, value_*  the same pairs
--   change     NEW (series only now), GONE (only then), WORSE / BETTER
--              (sev_rank moved), SAME, ALERT ONLY (no fit in either run)
--   n_new, n_resolved, n_reopened, n_sev_changes, events
--              the alert events of the runs after the older run up to the
--              latest one, for this series' alert kinds; events lists the
--              counts per kind, e.g. 'TBSPC_FULL NEW 1, TBSPC_ANOM NEW 1'
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_weekly_digest AS
WITH runs AS (
        SELECT run_id, as_of_day,
               ROW_NUMBER() OVER (ORDER BY as_of_day DESC, run_id DESC) AS rk
        FROM   cap_run
        WHERE  status = 'OK'
     ),
     pair AS (
        SELECT n.run_id AS run_now, n.as_of_day AS day_now,
               t.run_id AS run_then, t.as_of_day AS day_then
        FROM  (SELECT run_id, as_of_day FROM runs WHERE rk = 1) n
        JOIN  (SELECT r.run_id, r.as_of_day,
                      ROW_NUMBER() OVER (ORDER BY r.as_of_day DESC, r.run_id DESC) AS rk2
               FROM   runs r
               CROSS  JOIN (SELECT as_of_day FROM runs WHERE rk = 1) l
               CROSS  JOIN cap_cfg cfg
               WHERE  r.as_of_day <= l.as_of_day - cfg.digest_days) t
          ON  t.rk2 = 1
     ),
     fnow AS (
        SELECT h.* FROM cap_fit_hist h JOIN pair p ON h.run_id = p.run_now
     ),
     fthen AS (
        SELECT h.* FROM cap_fit_hist h JOIN pair p ON h.run_id = p.run_then
     ),
     evk AS (
        SELECT CASE WHEN s.kind IN ('TBSPC_FULL', 'TBSPC_NEARFULL', 'TBSPC_ANOM') THEN 'TBSPC'
                    WHEN s.kind IN ('SERIES_LIMIT', 'SERIES_NEARLIMIT', 'SERIES_ANOM') THEN 'SERIES'
                    WHEN s.kind IN ('CPU_SAT', 'CPU_HOT', 'CPU_ANOM', 'CPU_SHIFT',
                                    'DBCPU_SAT', 'DBCPU_HOT', 'DBCPU_ANOM') THEN 'CPU'
                    ELSE 'OTHER' END                AS kind,
               s.dbid, s.con_dbid, s.series_key AS series, s.kind AS alert_kind, e.event,
               COUNT(*)                             AS n
        FROM   cap_alert_event e
        JOIN   cap_run r         ON r.run_id = e.run_id
        JOIN   cap_alert_state s ON s.state_key = e.state_key
        CROSS  JOIN pair p
        WHERE  (r.as_of_day > p.day_then OR (r.as_of_day = p.day_then AND r.run_id > p.run_then))
          AND  (r.as_of_day < p.day_now  OR (r.as_of_day = p.day_now  AND r.run_id <= p.run_now))
        GROUP  BY s.kind, s.dbid, s.con_dbid, s.series_key, e.event
     ),
     evs AS (
        SELECT kind, dbid, con_dbid, series,
               SUM(CASE WHEN event = 'NEW'      THEN n ELSE 0 END)                    AS n_new,
               SUM(CASE WHEN event = 'RESOLVED' THEN n ELSE 0 END)                    AS n_resolved,
               SUM(CASE WHEN event = 'REOPENED' THEN n ELSE 0 END)                    AS n_reopened,
               SUM(CASE WHEN event IN ('ESCALATED', 'DEESCALATED') THEN n ELSE 0 END) AS n_sev_changes,
               LISTAGG(alert_kind || ' ' || event || ' ' || n, ', ')
                   WITHIN GROUP (ORDER BY alert_kind, event)                          AS events
        FROM   evk
        GROUP  BY kind, dbid, con_dbid, series
     ),
     k AS (
        SELECT kind, dbid, con_dbid, series FROM fnow
        UNION
        SELECT kind, dbid, con_dbid, series FROM fthen
        UNION
        SELECT kind, dbid, con_dbid, series FROM evs
     )
SELECT p.run_then,
       p.day_then,
       p.run_now,
       p.day_now,
       k.kind,
       k.dbid,
       k.con_dbid,
       NVL(n.db, t.db)                        AS db,
       k.series,
       t.days_to_full                         AS dtf_then,
       n.days_to_full                         AS dtf_now,
       n.days_to_full - t.days_to_full        AS dtf_delta,
       t.pct                                  AS pct_then,
       n.pct                                  AS pct_now,
       n.pct - t.pct                          AS pct_delta,
       t.quality                              AS quality_then,
       n.quality                              AS quality_now,
       t.sev                                  AS sev_then,
       n.sev                                  AS sev_now,
       t.value                                AS value_then,
       n.value                                AS value_now,
       CASE WHEN t.series IS NULL AND n.series IS NULL THEN 'ALERT ONLY'
            WHEN t.series IS NULL                      THEN 'NEW'
            WHEN n.series IS NULL                      THEN 'GONE'
            WHEN n.sev_rank < t.sev_rank               THEN 'WORSE'
            WHEN n.sev_rank > t.sev_rank               THEN 'BETTER'
            ELSE 'SAME' END                   AS change,
       NVL(e.n_new, 0)                        AS n_new,
       NVL(e.n_resolved, 0)                   AS n_resolved,
       NVL(e.n_reopened, 0)                   AS n_reopened,
       NVL(e.n_sev_changes, 0)                AS n_sev_changes,
       e.events
FROM   k
CROSS  JOIN pair p
LEFT   JOIN fnow n
  ON   n.kind = k.kind AND n.dbid = k.dbid AND n.con_dbid = k.con_dbid AND n.series = k.series
LEFT   JOIN fthen t
  ON   t.kind = k.kind AND t.dbid = k.dbid AND t.con_dbid = k.con_dbid AND t.series = k.series
LEFT   JOIN evs e
  ON   e.kind = k.kind AND e.dbid = k.dbid AND e.con_dbid = k.con_dbid AND e.series = k.series;

-- --------------------------------------------------------------------
-- CAPR_FORECAST_ACCURACY -- how the issued forecasts fared. For every
-- CAP_FIT_HIST row of an OK run whose series has newer data today
-- (elapsed_days = CAPR_FIT.last_day - the row's last_day, at least 1):
--   projected   value_then + slope_then * elapsed_days, the anchored
--               formula every CAPF_ projection uses
--   actual      CAPR_FIT.value today (the same anchor quantity: used bytes,
--               the CPU anchor, the series level)
--   error       actual - projected (positive = grew faster than forecast)
--   error_pct   100 * error / |actual|
-- Filter on elapsed_days for a horizon, e.g. WHERE elapsed_days BETWEEN 28
-- AND 31 for "last month's forecasts".
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_forecast_accuracy AS
SELECT h.run_id,
       h.as_of_day,
       h.kind,
       h.dbid,
       h.con_dbid,
       h.db,
       h.series,
       h.unit,
       h.method,
       h.quality                                                AS quality_then,
       h.last_day                                               AS day_then,
       h.value                                                  AS value_then,
       h.slope_per_day                                          AS slope_then,
       a.last_day                                               AS day_now,
       a.last_day - h.last_day                                  AS elapsed_days,
       h.value + h.slope_per_day * (a.last_day - h.last_day)    AS projected,
       a.value                                                  AS actual,
       a.value - (h.value + h.slope_per_day * (a.last_day - h.last_day)) AS error,
       CASE WHEN a.value <> 0
            THEN ROUND(100 * (a.value - (h.value + h.slope_per_day * (a.last_day - h.last_day)))
                       / ABS(a.value), 2) END                   AS error_pct,
       a.quality                                                AS quality_now
FROM   cap_fit_hist h
JOIN   cap_run r ON r.run_id = h.run_id AND r.status = 'OK'
JOIN   capr_fit a
  ON   a.kind = h.kind AND a.dbid = h.dbid AND a.con_dbid = h.con_dbid AND a.series = h.series
WHERE  a.last_day > h.last_day
  AND  h.value IS NOT NULL
  AND  h.slope_per_day IS NOT NULL
  AND  a.value IS NOT NULL;

-- --------------------------------------------------------------------
-- CAPR_FIT_TRACK -- the forecast track record. One row per series of the
-- newest OK run (the SNAPSHOT tables' run), read from CAP_FIT_HIST and
-- CAP_RUN only, so it costs a table scan and says the same under LIVE and
-- SNAPSHOT. No run, no rows.
--
-- A stored fit is both a forecast and, for the older fits of its series, the
-- actual value. One fit per series and data day (last_day; the newest run
-- that saw the day). A fit graded INSUFFICIENT_HISTORY or CYCLIC issued no
-- straight-line forecast (no projection points, or a cycle judged on its
-- peaks) and is an actual only. A forecast is checked against the fit whose last_day is
-- accuracy_horizon_days later, or failing that the nearest within 2 days
-- (the earlier one on a tie), when that outcome day lies in the last
-- accuracy_window_days before the series' newest day:
--   projected   value_then + slope_then * elapsed days (the anchored formula,
--               as CAPR_FORECAST_ACCURACY)
--   error       actual - projected, error percent = 100 * error / |actual|
--   half        (proj_30_hi - proj_30_lo) / 2 of the forecast, the half-width
--               of the +30 band issued then. A band of width 0 (a FLAT fit)
--               or none (a run before the columns) is not judged.
-- Per series:
--   n_forecasts   forecasts checked
--   abs_err_pct   median |error percent|
--   bias_pct      median error percent. Positive = grew faster than forecast.
--   n_banded, band_hits, band_hit_pct
--                 forecasts with a band, and those whose |error| <= half
--   band_factor   GREATEST(1, the calib_quantile_pct percentile of |error| /
--                 half), 2 decimals: the factor the issued half-width needed
--                 to contain that share of the errors. NULL below
--                 calib_min_forecasts banded forecasts.
--   proj_30, proj_30_lo, proj_30_hi  the newest run's +30 projection and band
--   proj_30_lo_cal, proj_30_hi_cal   proj_30 -/+ band_factor * its half-width
--   reliability   first matching row of `rule`: UNKNOWN (fewer than
--                 calib_min_forecasts checked), BIASED (|bias_pct| above
--                 calib_bias_pct), WIDE (band_factor above
--                 calib_wide_factor), GOOD. reliability_rank orders them.
--   summary       the one line the reports print
--   rank_track    per database: reliability_rank, then abs_err_pct descending
-- The band test uses the +30 band at any accuracy_horizon_days. Nothing here
-- feeds a fit, an alert or the slope method.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capr_fit_track AS
WITH ok AS (
        SELECT run_id FROM cap_run WHERE status = 'OK'
     ),
     cur AS (
        SELECT h.*
        FROM   cap_fit_hist h
        WHERE  h.run_id = (SELECT MAX(run_id) FROM ok)
     ),
     fc AS (
        SELECT kind, dbid, con_dbid, series, last_day, value, slope_per_day, quality, proj_30_lo, proj_30_hi
        FROM  (SELECT h.kind, h.dbid, h.con_dbid, h.series, h.last_day, h.value, h.slope_per_day,
                      h.quality, h.proj_30_lo, h.proj_30_hi,
                      ROW_NUMBER() OVER (PARTITION BY h.dbid, h.con_dbid, h.kind, h.series, h.last_day
                                         ORDER BY h.run_id DESC) AS rn
               FROM   cap_fit_hist h
               JOIN   ok ON ok.run_id = h.run_id
               WHERE  h.last_day IS NOT NULL
                 AND  h.value IS NOT NULL)
        WHERE  rn = 1
     ),
     off AS (
        SELECT LEVEL - 3 AS o FROM dual CONNECT BY LEVEL <= 5
     ),
     pr AS (
        SELECT f.kind, f.dbid, f.con_dbid, f.series,
               a.value                                                 AS actual,
               f.value + f.slope_per_day * (a.last_day - f.last_day)   AS projected,
               CASE WHEN a.last_day > c.last_day - cfg.accuracy_window_days
                    THEN 'Y' ELSE 'N' END                              AS in_window,
               CASE WHEN f.proj_30_hi > f.proj_30_lo
                    THEN (f.proj_30_hi - f.proj_30_lo) / 2 END         AS half,
               ROW_NUMBER() OVER (PARTITION BY f.dbid, f.con_dbid, f.kind, f.series, f.last_day
                                  ORDER BY ABS(off.o), off.o)          AS rn
        FROM   fc f
        CROSS  JOIN cap_cfg cfg
        CROSS  JOIN off
        JOIN   fc a
          ON   a.kind = f.kind AND a.dbid = f.dbid AND a.con_dbid = f.con_dbid AND a.series = f.series
         AND   a.last_day = f.last_day + cfg.accuracy_horizon_days + off.o
        JOIN   cur c
          ON   c.kind = f.kind AND c.dbid = f.dbid AND c.con_dbid = f.con_dbid AND c.series = f.series
        WHERE  f.slope_per_day IS NOT NULL
          AND  f.quality NOT IN ('INSUFFICIENT_HISTORY', 'CYCLIC')
     ),
     e AS (
        SELECT kind, dbid, con_dbid, series,
               CASE WHEN actual <> 0 THEN 100 * (actual - projected) / ABS(actual) END AS err_pct,
               CASE WHEN half IS NOT NULL
                    THEN CASE WHEN ABS(actual - projected) <= half THEN 1 ELSE 0 END END AS hit,
               ABS(actual - projected) / half                                          AS ratio
        FROM   pr
        WHERE  rn = 1
          AND  in_window = 'Y'
     ),
     st AS (
        SELECT e.kind, e.dbid, e.con_dbid, e.series,
               COUNT(*)                                  AS n_forecasts,
               ROUND(MEDIAN(ABS(e.err_pct)), 2)          AS abs_err_pct,
               ROUND(MEDIAN(e.err_pct), 2)               AS bias_pct,
               COUNT(e.hit)                              AS n_banded,
               SUM(e.hit)                                AS band_hits,
               PERCENTILE_CONT(cfg.calib_quantile_pct / 100) WITHIN GROUP (ORDER BY e.ratio) AS ratio_q
        FROM   e
        CROSS  JOIN cap_cfg cfg
        GROUP  BY e.kind, e.dbid, e.con_dbid, e.series, cfg.calib_quantile_pct
     ),
     rule AS (
        SELECT 1 AS n, 'UNKNOWN' AS reliability, 4 AS reliability_rank,
               'N' AS known, CAST(NULL AS VARCHAR2(1)) AS biased, CAST(NULL AS VARCHAR2(1)) AS wide FROM dual
        --                n  reliability rank known biased wide
        UNION ALL SELECT 2, 'BIASED',   1, NULL, 'Y',  NULL FROM dual
        UNION ALL SELECT 3, 'WIDE',     2, NULL, NULL, 'Y'  FROM dual
        UNION ALL SELECT 4, 'GOOD',     3, NULL, NULL, NULL FROM dual
     ),
     t AS (
        SELECT c.run_id, c.as_of_day, c.dbid, c.con_dbid, c.db, c.kind, c.series, c.unit, c.quality,
               c.is_current, c.last_day, c.value, c.proj_30, c.proj_30_lo, c.proj_30_hi,
               cfg.accuracy_horizon_days                 AS horizon_days,
               cfg.calib_min_forecasts                   AS min_forecasts,
               NVL(s.n_forecasts, 0)                     AS n_forecasts,
               s.abs_err_pct,
               s.bias_pct,
               NVL(s.n_banded, 0)                        AS n_banded,
               s.band_hits,
               ROUND(100 * s.band_hits / NULLIF(s.n_banded, 0), 1) AS band_hit_pct,
               CASE WHEN s.n_banded >= cfg.calib_min_forecasts
                    THEN ROUND(GREATEST(1, s.ratio_q), 2) END      AS band_factor,
               cfg.calib_bias_pct,
               cfg.calib_wide_factor
        FROM   cur c
        CROSS  JOIN cap_cfg cfg
        LEFT   JOIN st s
          ON   s.kind = c.kind AND s.dbid = c.dbid AND s.con_dbid = c.con_dbid AND s.series = c.series
     ),
     flagged AS (
        SELECT t.*,
               CASE WHEN t.n_forecasts >= t.min_forecasts      THEN 'Y' ELSE 'N' END AS known,
               CASE WHEN ABS(t.bias_pct) > t.calib_bias_pct    THEN 'Y' ELSE 'N' END AS biased,
               CASE WHEN t.band_factor > t.calib_wide_factor   THEN 'Y' ELSE 'N' END AS wide
        FROM   t
     ),
     graded AS (
        SELECT f.*, r.reliability, r.reliability_rank,
               ROW_NUMBER() OVER (PARTITION BY f.dbid, f.con_dbid, f.kind, f.series ORDER BY r.n) AS rule_rn
        FROM   flagged f
        JOIN   rule r
          ON   (r.known  IS NULL OR r.known  = f.known)
         AND   (r.biased IS NULL OR r.biased = f.biased)
         AND   (r.wide   IS NULL OR r.wide   = f.wide)
     )
SELECT g.run_id,
       g.as_of_day,
       g.dbid,
       g.con_dbid,
       g.db,
       g.kind,
       g.series,
       g.unit,
       g.quality,
       g.is_current,
       g.last_day,
       g.value,
       g.horizon_days,
       g.n_forecasts,
       g.abs_err_pct,
       g.bias_pct,
       g.n_banded,
       g.band_hits,
       g.band_hit_pct,
       g.band_factor,
       g.proj_30,
       g.proj_30_lo,
       g.proj_30_hi,
       g.proj_30 - g.band_factor * (g.proj_30_hi - g.proj_30_lo) / 2 AS proj_30_lo_cal,
       g.proj_30 + g.band_factor * (g.proj_30_hi - g.proj_30_lo) / 2 AS proj_30_hi_cal,
       g.reliability,
       g.reliability_rank,
       CASE WHEN g.n_forecasts = 0
            THEN 'No ' || g.horizon_days || '-day forecast is old enough to check yet.'
            ELSE g.n_forecasts || ' forecast' || CASE WHEN g.n_forecasts <> 1 THEN 's' END
                 || ' checked after ' || g.horizon_days || ' days'
                 || CASE WHEN g.known = 'N' THEN ' (a grade needs ' || g.min_forecasts || ')' END
                 || ': median error ' || NVL(TO_CHAR(g.abs_err_pct, 'FM999999990.0'), '?') || '%, bias '
                 || CASE WHEN g.bias_pct > 0 THEN '+' END || NVL(TO_CHAR(g.bias_pct, 'FM999999990.0'), '?') || '%'
                 || CASE WHEN g.n_banded > 0
                         THEN ', ' || g.band_hits || ' of ' || g.n_banded || ' inside the 95% band' END
                 || CASE WHEN g.band_factor > 1
                         THEN ', band widened x' || TO_CHAR(g.band_factor, 'FM9990.00') END
                 || '.'
       END                                                           AS summary,
       ROW_NUMBER() OVER (PARTITION BY g.dbid
                          ORDER BY g.reliability_rank, g.abs_err_pct DESC NULLS LAST,
                                   g.kind, g.con_dbid, g.series)     AS rank_track
FROM   graded g
WHERE  g.rule_rn = 1;

-- --------------------------------------------------------------------
-- CAP_RESULTS -- the only code in the suite that writes. See the spec.
-- --------------------------------------------------------------------
CREATE OR REPLACE PACKAGE cap_results AUTHID DEFINER AS
    -- Snapshot the live views. Takes an exclusive lock on CAP_ALERT_STATE
    -- first and holds it to the final COMMIT / ROLLBACK, so refreshes are
    -- serialised for their whole lifetime: run_id order equals commit order
    -- (a poller on run_id > :last_seen never skips a run). Then inserts a
    -- CAP_RUN row (RUNNING, committed at once by an autonomous transaction,
    -- so a hung run is visible and the lock stays held), copies CAPR_FIT
    -- into CAP_FIT_HIST, merges CAPR_ALERTS into CAP_ALERT_STATE with events,
    -- keeps the CAPR_COVERAGE roll-up on the run row, marks the run OK and
    -- COMMITs. A second refresh waits at the lock and shows no RUNNING row
    -- until it has it. On any error the run's work is rolled back, the run is
    -- marked FAILED with the error stack, and the error is re-raised (so a
    -- scheduler run ends FAILED too). It commits: call it with no pending
    -- work of your own. Lock order everywhere: CAP_ALERT_STATE, then CAP_RUN.
    --   p_as_of  the run's as_of_day, default today. A day before today
    --            records a backdated run: the fits as the views show them
    --            now, labelled with that day, and no alert state (the state
    --            machine runs in real time). A day after today fails.
    --
    -- Before the fits, every view in snap_views is copied into its table
    -- <view>_S (DELETE, then INSERT the view's rows under snap_run_id =
    -- the run), and the fits, the alert merge and the coverage read those
    -- tables, so each view is evaluated once per run. The tables switch to the
    -- new run at the COMMIT, backdated runs included (the views do not depend
    -- on p_as_of); a FAILED run leaves the previous run's rows.
    PROCEDURE refresh(p_as_of IN DATE DEFAULT NULL);

    -- The views the report drivers read, the one list of them. SNAPSHOT
    -- reports read <view>_S (snap_run_id, then the view's columns) instead.
    FUNCTION snap_views RETURN SYS.ODCIVARCHAR2LIST;

    -- Drop and re-create every <view>_S, empty, from the view's columns as
    -- they are now. ddl/60 runs it at the end of every install; the next
    -- refresh fills them. DDL: it commits.
    PROCEDURE build_snap_tables;

    -- Acknowledge an alert: CAPR_ALERTS_LATEST hides it until p_until
    -- (NULL = until it resolves). p_key is a state_key, or an alert_key the
    -- state last carried. An escalation or a reopen clears the ack.
    PROCEDURE ack(p_key   IN VARCHAR2,
                  p_until IN DATE     DEFAULT NULL,
                  p_note  IN VARCHAR2 DEFAULT NULL,
                  p_by    IN VARCHAR2 DEFAULT SYS_CONTEXT('USERENV', 'SESSION_USER'));
    PROCEDURE unack(p_key IN VARCHAR2);

    -- Delete the runs that started more than p_keep_days days ago, with
    -- their fit snapshots and events, and the RESOLVED states resolved
    -- before then. The newest run and the newest OK live run always stay.
    PROCEDURE purge(p_keep_days IN NUMBER DEFAULT 400);

    -- Forget everything: every run, snapshot, event and alert state, acks
    -- included. For a fresh start (e.g. after a deploy_mode change) and tests.
    PROCEDURE reset;

    -- repository | fixture (unknown otherwise), read from what CAPV_SNAPSHOT
    -- depends on.
    FUNCTION deploy_mode RETURN VARCHAR2;

    -- Every procedure above labels its session MODULE 'AWRCAP/cap_results.<name>'
    -- (refresh: ACTION = the step) and puts the caller's MODULE / ACTION back
    -- when it returns or raises.
END cap_results;
/

CREATE OR REPLACE PACKAGE BODY cap_results AS

    c_far CONSTANT DATE := DATE '9999-12-31';

    FUNCTION rank_of(p_sev VARCHAR2) RETURN PLS_INTEGER IS
    BEGIN
        RETURN CASE p_sev WHEN 'CRIT' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END;
    END rank_of;

    FUNCTION deploy_mode RETURN VARCHAR2 IS
        v VARCHAR2(16);
    BEGIN
        SELECT CASE WHEN COUNT(CASE WHEN referenced_name LIKE 'CAP\_FIXTURE\_%' ESCAPE '\' THEN 1 END) > 0
                    THEN 'fixture'
                    WHEN COUNT(CASE WHEN referenced_name LIKE 'CAP\_H\_%' ESCAPE '\' THEN 1 END) > 0
                    THEN 'repository'
                    ELSE 'unknown' END
        INTO   v
        FROM   all_dependencies
        WHERE  owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
          AND  name  = 'CAPV_SNAPSHOT'
          AND  type  = 'VIEW';
        RETURN v;
    END deploy_mode;

    FUNCTION snap_views RETURN SYS.ODCIVARCHAR2LIST IS
    BEGIN
        RETURN SYS.ODCIVARCHAR2LIST(
            'CAPR_CONTAINER', 'CAPR_FIT', 'CAPR_ALERTS', 'CAPR_COVERAGE', 'CAPR_DATA_WINDOW',
            'CAPR_TBSPC_DAYS_TO_FULL', 'CAPR_TBSPC_RANK', 'CAPR_TBSPC_FORECAST',
            'CAPR_TBSPC_ANOMALIES', 'CAPR_CPU_TREND', 'CAPR_CPU_ANOMALIES', 'CAPR_CPU_SHIFTS',
            'CAPR_ESM_COMPARE', 'CAPR_BACKTEST', 'CAPF_ESM_HEALTH_SUMMARY', 'CAPR_SERIES',
            'CAPR_SERIES_ANOMALIES', 'CAPR_ANOMALIES', 'CAPR_SERIES_POINTS',
            'CAPR_ANOM_VOLUME',
            'CAPR_FORECAST_POINTS', 'CAPR_HOURLY_POINTS', 'CAPR_SEGMENT_GROWTH',
            'CAPR_MEM_VERDICT', 'CAPR_MEM_EVIDENCE', 'CAPR_MEM_COMPONENTS',
            'CAPR_MEM_COMP_POINTS',
            -- tablespace families (ddl/32)
            'CAPR_TBSPC_FAMILY', 'CAPR_TBSPC_FAMILY_MEMBERS',
            'CAPR_DISK');
    END snap_views;

    PROCEDURE build_snap_tables IS
        l_views SYS.ODCIVARCHAR2LIST := snap_views;
        l_mod   VARCHAR2(64);
        l_act   VARCHAR2(64);
    BEGIN
        DBMS_APPLICATION_INFO.READ_MODULE(l_mod, l_act);
        DBMS_APPLICATION_INFO.SET_MODULE('AWRCAP/cap_results.build_snap_tables', NULL);
        FOR i IN 1 .. l_views.COUNT LOOP
            DBMS_APPLICATION_INFO.SET_ACTION(LOWER(l_views(i)) || '_s');
            BEGIN
                EXECUTE IMMEDIATE 'DROP TABLE ' || l_views(i) || '_S PURGE';
            EXCEPTION
                WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF;
            END;
            EXECUTE IMMEDIATE 'CREATE TABLE ' || l_views(i) || '_S AS SELECT CAST(NULL AS NUMBER) AS snap_run_id, v.* FROM '
                              || l_views(i) || ' v WHERE 1 = 0';
        END LOOP;
        DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
            RAISE;
    END build_snap_tables;

    -- One read of CAPR_ALERTS_S (this run's CAPR_ALERTS), one row per
    -- state_key (worst severity, then the latest day: an anomaly key can
    -- carry several episodes), merged into CAP_ALERT_STATE. Event ids are
    -- p_run * 100000 + n.
    PROCEDURE merge_alerts(p_run   IN  NUMBER,
                           p_now   IN  DATE,
                           o_alert OUT PLS_INTEGER,
                           o_anom  OUT PLS_INTEGER,
                           o_event OUT PLS_INTEGER) IS
        -- Dynamic SQL: install drops and re-creates CAPR_ALERTS_S, which
        -- would invalidate this body on every install as a static reference.
        TYPE cur_rec IS RECORD (
            state_key       cap_alert_state.state_key%TYPE,
            alert_key       cap_alert_state.last_alert_key%TYPE,
            kind            cap_alert_state.kind%TYPE,
            dbid            cap_alert_state.dbid%TYPE,
            con_dbid        cap_alert_state.con_dbid%TYPE,
            db_pdb          cap_alert_state.db_pdb%TYPE,
            series_key      cap_alert_state.series_key%TYPE,
            baseline_mode   cap_alert_state.baseline_mode%TYPE,
            severity        cap_alert_state.cur_severity%TYPE,
            day_dt          cap_alert_state.last_day%TYPE,
            value           cap_alert_state.last_value%TYPE,
            threshold       cap_alert_state.last_threshold%TYPE,
            alarm_threshold cap_alert_state.last_alarm%TYPE,
            direction       cap_alert_state.last_direction%TYPE,
            unit            cap_alert_state.last_unit%TYPE,
            message         VARCHAR2(4000),
            first_day       cap_alert_state.last_first_day%TYPE,
            n_days          cap_alert_state.last_n_days%TYPE,
            max_z           cap_alert_state.last_max_z%TYPE,
            n_all           NUMBER,
            n_anom          NUMBER);
        TYPE cur_tab IS TABLE OF cur_rec;
        c_cur   SYS_REFCURSOR;
        l_rows  cur_tab;
        l_grace NUMBER;
        l_n     PLS_INTEGER := 0;
        l_found BOOLEAN;
        l_state cap_alert_state.state%TYPE;
        l_sev   cap_alert_state.cur_severity%TYPE;
        l_max   cap_alert_state.max_severity%TYPE;
        l_reop  cap_alert_state.reopen_count%TYPE;
        l_event cap_alert_event.event%TYPE;
        l_newmax cap_alert_state.max_severity%TYPE;

        PROCEDURE add_event(p_key VARCHAR2, p_akey VARCHAR2, p_event VARCHAR2,
                            p_sev VARCHAR2, p_prev VARCHAR2, p_msg VARCHAR2) IS
        BEGIN
            l_n := l_n + 1;
            INSERT INTO cap_alert_event (event_id, run_id, state_key, alert_key, event, at_time,
                                         severity, prev_severity, message)
            VALUES (p_run * 100000 + l_n, p_run, p_key, p_akey, p_event, p_now,
                    p_sev, p_prev, SUBSTR(p_msg, 1, 4000));
        END add_event;
    BEGIN
        SELECT resolve_grace_runs INTO l_grace FROM cap_cfg;
        -- refresh already holds this lock (taken before run_id allocation);
        -- re-locking in the same transaction is a no-op, kept so merge_alerts
        -- stays safe on its own.
        LOCK TABLE cap_alert_state IN EXCLUSIVE MODE;

        OPEN c_cur FOR
            'SELECT x.state_key, x.alert_key, x.kind, x.dbid, x.con_dbid, x.db_pdb, x.series_key,
                    x.baseline_mode, x.severity, x.day_dt, x.value, x.threshold, x.alarm_threshold,
                    x.direction, x.unit, x.message, x.first_day, x.n_days, x.max_z, x.n_all, x.n_anom
             FROM  (SELECT a.*,
                           ROW_NUMBER() OVER (PARTITION BY a.state_key
                                              ORDER BY a.sev_rank, a.day_dt DESC, a.alert_key) AS rn,
                           COUNT(*) OVER ()                                                    AS n_all,
                           COUNT(CASE WHEN a.kind IN (''TBSPC_ANOM'', ''CPU_ANOM'', ''DBCPU_ANOM'', ''SERIES_ANOM'')
                                      THEN 1 END) OVER ()                                      AS n_anom
                    FROM   capr_alerts_s a
                    WHERE  a.is_current = ''Y'') x
             WHERE  x.rn = 1';
        FETCH c_cur BULK COLLECT INTO l_rows;
        CLOSE c_cur;
        o_alert := 0;
        o_anom  := 0;
        IF l_rows.COUNT > 0 THEN
            o_alert := l_rows(1).n_all;
            o_anom  := l_rows(1).n_anom;
        END IF;

        FOR i IN 1 .. l_rows.COUNT LOOP
            l_found := TRUE;
            BEGIN
                SELECT state, cur_severity, max_severity, NVL(reopen_count, 0)
                INTO   l_state, l_sev, l_max, l_reop
                FROM   cap_alert_state
                WHERE  state_key = l_rows(i).state_key;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN l_found := FALSE;
            END;

            IF NOT l_found THEN
                INSERT INTO cap_alert_state (
                    state_key, kind, dbid, con_dbid, db_pdb, series_key, baseline_mode, state,
                    first_seen, last_seen, cur_severity, max_severity, resolved_at, reopen_count,
                    missed_runs, last_run_id, last_alert_key, last_day, last_value, last_threshold,
                    last_alarm, last_direction, last_unit, last_message,
                    last_first_day, last_n_days, last_max_z)
                VALUES (
                    l_rows(i).state_key, l_rows(i).kind, l_rows(i).dbid, l_rows(i).con_dbid,
                    l_rows(i).db_pdb, l_rows(i).series_key, l_rows(i).baseline_mode, 'OPEN',
                    p_now, p_now, l_rows(i).severity, l_rows(i).severity, NULL, 0,
                    0, p_run, l_rows(i).alert_key, l_rows(i).day_dt, l_rows(i).value, l_rows(i).threshold,
                    l_rows(i).alarm_threshold, l_rows(i).direction, l_rows(i).unit,
                    SUBSTR(l_rows(i).message, 1, 4000),
                    l_rows(i).first_day, l_rows(i).n_days, l_rows(i).max_z);
                add_event(l_rows(i).state_key, l_rows(i).alert_key, 'NEW',
                          l_rows(i).severity, NULL, l_rows(i).message);
            ELSE
                l_event := CASE
                               WHEN l_state = 'RESOLVED'                              THEN 'REOPENED'
                               WHEN rank_of(l_rows(i).severity) < rank_of(l_sev)       THEN 'ESCALATED'
                               WHEN rank_of(l_rows(i).severity) > rank_of(l_sev)       THEN 'DEESCALATED'
                           END;
                l_newmax := CASE WHEN rank_of(l_rows(i).severity) < rank_of(l_max)
                                 THEN l_rows(i).severity ELSE l_max END;
                UPDATE cap_alert_state
                   SET state          = 'OPEN',
                       db_pdb         = l_rows(i).db_pdb,
                       last_seen      = p_now,
                       cur_severity   = l_rows(i).severity,
                       max_severity   = l_newmax,
                       resolved_at    = NULL,
                       reopen_count   = l_reop + CASE WHEN l_event = 'REOPENED' THEN 1 ELSE 0 END,
                       missed_runs    = 0,
                       last_run_id    = p_run,
                       last_alert_key = l_rows(i).alert_key,
                       last_day       = l_rows(i).day_dt,
                       last_value     = l_rows(i).value,
                       last_threshold = l_rows(i).threshold,
                       last_alarm     = l_rows(i).alarm_threshold,
                       last_direction = l_rows(i).direction,
                       last_unit      = l_rows(i).unit,
                       last_message   = SUBSTR(l_rows(i).message, 1, 4000),
                       last_first_day = l_rows(i).first_day,
                       last_n_days    = l_rows(i).n_days,
                       last_max_z     = l_rows(i).max_z,
                       ack_until      = CASE WHEN l_event IN ('REOPENED', 'ESCALATED') THEN NULL ELSE ack_until END,
                       ack_note       = CASE WHEN l_event IN ('REOPENED', 'ESCALATED') THEN NULL ELSE ack_note END,
                       ack_by         = CASE WHEN l_event IN ('REOPENED', 'ESCALATED') THEN NULL ELSE ack_by END,
                       acked_at       = CASE WHEN l_event IN ('REOPENED', 'ESCALATED') THEN NULL ELSE acked_at END
                 WHERE state_key = l_rows(i).state_key;
                IF l_event IS NOT NULL THEN
                    add_event(l_rows(i).state_key, l_rows(i).alert_key, l_event,
                              l_rows(i).severity, l_sev, l_rows(i).message);
                END IF;
            END IF;
        END LOOP;

        -- OPEN keys this run did not see: one more miss, RESOLVED at the grace.
        FOR s IN (SELECT state_key, last_alert_key, cur_severity, NVL(missed_runs, 0) + 1 AS misses,
                         last_seen, last_message
                  FROM   cap_alert_state
                  WHERE  state = 'OPEN'
                    AND  NVL(last_run_id, -1) <> p_run) LOOP
            IF s.misses >= l_grace THEN
                UPDATE cap_alert_state
                   SET state = 'RESOLVED', resolved_at = p_now, missed_runs = s.misses
                 WHERE state_key = s.state_key;
                add_event(s.state_key, s.last_alert_key, 'RESOLVED', s.cur_severity, s.cur_severity,
                          'Resolved: missing from ' || s.misses || ' consecutive refresh runs, last seen '
                          || TO_CHAR(s.last_seen, 'YYYY-MM-DD HH24:MI') || '. Last message: ' || s.last_message);
            ELSE
                UPDATE cap_alert_state SET missed_runs = s.misses WHERE state_key = s.state_key;
            END IF;
        END LOOP;
        o_event := l_n;
    END merge_alerts;

    -- The RUNNING row, committed in its own transaction so refresh's lock on
    -- CAP_ALERT_STATE survives it. Nothing else touches CAP_RUN rows here, so
    -- the lock the main transaction holds cannot block this insert.
    PROCEDURE insert_running(p_run IN NUMBER, p_asof IN DATE, p_back IN CHAR) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        INSERT INTO cap_run (run_id, as_of_day, deploy_mode, started_at, status, backdated, run_by)
        VALUES (p_run, p_asof, deploy_mode, SYSTIMESTAMP, 'RUNNING', p_back,
                SYS_CONTEXT('USERENV', 'SESSION_USER'));
        COMMIT;
    END insert_running;

    PROCEDURE refresh(p_as_of IN DATE DEFAULT NULL) IS
        l_run   NUMBER;
        l_asof  DATE := TRUNC(NVL(p_as_of, SYSDATE));
        l_now   DATE := SYSDATE;
        l_back  CHAR(1);
        l_fit   PLS_INTEGER := 0;
        l_alert PLS_INTEGER;
        l_anom  PLS_INTEGER;
        l_event PLS_INTEGER;
        l_cov_n NUMBER;
        l_cov_c NUMBER;
        l_cov   VARCHAR2(4000);
        l_err   VARCHAR2(4000);
        l_mod   VARCHAR2(64);
        l_act   VARCHAR2(64);
        l_scope NUMBER;
        l_views SYS.ODCIVARCHAR2LIST := snap_views;
    BEGIN
        DBMS_APPLICATION_INFO.READ_MODULE(l_mod, l_act);
        DBMS_APPLICATION_INFO.SET_MODULE('AWRCAP/cap_results.refresh', 'lock');
        -- A run reads every database. A scope an aborted report left in this
        -- session (CAP_SCOPE) would hide the other targets, and their alerts
        -- would resolve.
        SELECT scope_dbid INTO l_scope FROM cap_scope;
        IF l_scope IS NOT NULL THEN
            DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL);
        END IF;
        l_back := CASE WHEN l_asof < TRUNC(l_now) THEN 'Y' ELSE 'N' END;
        -- Serialise first, backdated runs included: the lock is held from
        -- run_id allocation to the final COMMIT, so run_id order is commit
        -- order. Waits here (no CAP_RUN row yet) while another refresh runs.
        LOCK TABLE cap_alert_state IN EXCLUSIVE MODE;
        SELECT GREATEST(TO_NUMBER(TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF3')), NVL(MAX(run_id), 0) + 1)
        INTO   l_run
        FROM   cap_run;
        insert_running(l_run, l_asof, l_back);

        BEGIN
            IF l_asof > TRUNC(l_now) THEN
                RAISE_APPLICATION_ERROR(-20071, 'cap_results.refresh: p_as_of '
                    || TO_CHAR(l_asof, 'YYYY-MM-DD') || ' is after today');
            END IF;

            -- The <view>_S tables are re-created by every install, hence
            -- dynamic SQL wherever this body touches them.
            FOR i IN 1 .. l_views.COUNT LOOP
                DBMS_APPLICATION_INFO.SET_ACTION('snapshot ' || LOWER(l_views(i)));
                EXECUTE IMMEDIATE 'DELETE FROM ' || l_views(i) || '_S';
                EXECUTE IMMEDIATE 'INSERT INTO ' || l_views(i) || '_S SELECT :r, v.* FROM ' || l_views(i) || ' v'
                    USING l_run;
            END LOOP;

            DBMS_APPLICATION_INFO.SET_ACTION('fit snapshot');
            EXECUTE IMMEDIATE
               'INSERT INTO cap_fit_hist (
                    run_id, as_of_day, dbid, con_dbid, db, db_name, con_name, kind, series, unit, method,
                    value, limit_value, pct, slope_per_day, r2, quality, days_to_full, days_to_full_lo,
                    days_to_full_hi, accel, train_n, sev, sev_rank, limit_source, last_day, is_current,
                    limit_below_used, cycle_n, cycle_days, cycle_peak_pct, peak_slope_per_day, slope_sig,
                    hot_now, need_gib_30, need_gib_90, need_gib_180, add_by_day,
                    restart_reason, restart_day)
                SELECT :r, :a, f.dbid, f.con_dbid, f.db, f.db_name, f.con_name, f.kind, f.series,
                       f.unit, f.method, f.value, f.limit_value, f.pct, f.slope_per_day, f.r2, f.quality,
                       f.days_to_full, f.days_to_full_lo, f.days_to_full_hi, f.accel, f.train_n, f.sev,
                       f.sev_rank, f.limit_source, f.last_day, f.is_current, f.limit_below_used,
                       f.cycle_n, f.cycle_days, f.cycle_peak_pct, f.peak_slope_per_day, f.slope_sig,
                       f.hot_now, f.need_gib_30, f.need_gib_90, f.need_gib_180, f.add_by_day,
                       f.restart_reason, f.restart_day
                FROM   capr_fit_s f'
                USING l_run, l_asof;
            l_fit := SQL%ROWCOUNT;

            -- The +30 projection and band each fit issued, for CAPR_FIT_TRACK.
            DBMS_APPLICATION_INFO.SET_ACTION('fit bands');
            EXECUTE IMMEDIATE
               'MERGE INTO cap_fit_hist h
                USING (SELECT kind, dbid, con_dbid, series, value, lo, hi
                       FROM   capr_forecast_points_s
                       WHERE  method = ''REGR'' AND horizon_days = 30) p
                ON    (h.run_id = :r AND h.kind = p.kind AND h.dbid = p.dbid
                       AND h.con_dbid = p.con_dbid AND h.series = p.series)
                WHEN MATCHED THEN UPDATE
                   SET h.proj_30 = p.value, h.proj_30_lo = p.lo, h.proj_30_hi = p.hi'
                USING l_run;

            IF l_back = 'N' THEN
                DBMS_APPLICATION_INFO.SET_ACTION('merge alerts');
                merge_alerts(l_run, l_now, l_alert, l_anom, l_event);
            END IF;

            -- The same aggregation the HTML report's coverage line makes.
            DBMS_APPLICATION_INFO.SET_ACTION('coverage');
            EXECUTE IMMEDIATE
               'SELECT COUNT(*), COUNT(CASE WHEN retired = ''N'' THEN 1 END),
                       LISTAGG(summary, '' | '' ON OVERFLOW TRUNCATE) WITHIN GROUP (ORDER BY dbid)
                FROM   capr_coverage_s'
                INTO l_cov_n, l_cov_c, l_cov;

            UPDATE cap_run
               SET ended_at = SYSTIMESTAMP, status = 'OK', n_fit = l_fit,
                   n_alert = l_alert, n_anom = l_anom, n_event = l_event,
                   cov_n_dbid = l_cov_n, cov_n_current = l_cov_c, cov_summary = l_cov
             WHERE run_id = l_run;
            COMMIT;
        EXCEPTION
            WHEN OTHERS THEN
                l_err := SUBSTR(DBMS_UTILITY.FORMAT_ERROR_STACK || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE, 1, 4000);
                ROLLBACK;
                UPDATE cap_run
                   SET ended_at = SYSTIMESTAMP, status = 'FAILED', error_text = l_err
                 WHERE run_id = l_run;
                COMMIT;
                RAISE;
        END;
        DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
            RAISE;
    END refresh;

    PROCEDURE ack(p_key   IN VARCHAR2,
                  p_until IN DATE     DEFAULT NULL,
                  p_note  IN VARCHAR2 DEFAULT NULL,
                  p_by    IN VARCHAR2 DEFAULT SYS_CONTEXT('USERENV', 'SESSION_USER')) IS
        l_mod VARCHAR2(64);
        l_act VARCHAR2(64);
    BEGIN
        DBMS_APPLICATION_INFO.READ_MODULE(l_mod, l_act);
        DBMS_APPLICATION_INFO.SET_MODULE('AWRCAP/cap_results.ack', NULL);
        UPDATE cap_alert_state
           SET ack_until = NVL(p_until, c_far),
               ack_note  = SUBSTR(p_note, 1, 400),
               ack_by    = SUBSTR(p_by, 1, 128),
               acked_at  = SYSDATE
         WHERE state_key = p_key OR last_alert_key = p_key;
        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20072, 'cap_results.ack: no alert state with state_key or alert_key '
                                            || p_key);
        END IF;
        COMMIT;
        DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
            RAISE;
    END ack;

    PROCEDURE unack(p_key IN VARCHAR2) IS
        l_mod VARCHAR2(64);
        l_act VARCHAR2(64);
    BEGIN
        DBMS_APPLICATION_INFO.READ_MODULE(l_mod, l_act);
        DBMS_APPLICATION_INFO.SET_MODULE('AWRCAP/cap_results.unack', NULL);
        UPDATE cap_alert_state
           SET ack_until = NULL, ack_note = NULL, ack_by = NULL, acked_at = NULL
         WHERE state_key = p_key OR last_alert_key = p_key;
        IF SQL%ROWCOUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20072, 'cap_results.unack: no alert state with state_key or alert_key '
                                            || p_key);
        END IF;
        COMMIT;
        DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
            RAISE;
    END unack;

    PROCEDURE purge(p_keep_days IN NUMBER DEFAULT 400) IS
        l_last    NUMBER;
        l_last_ok NUMBER;
        l_cut     TIMESTAMP := SYSTIMESTAMP - NUMTODSINTERVAL(p_keep_days, 'DAY');
        l_mod     VARCHAR2(64);
        l_act     VARCHAR2(64);
    BEGIN
        DBMS_APPLICATION_INFO.READ_MODULE(l_mod, l_act);
        DBMS_APPLICATION_INFO.SET_MODULE('AWRCAP/cap_results.purge', NULL);
        -- A refresh waits at its first LOCK until this commits. Same lock
        -- order as refresh: CAP_ALERT_STATE, then CAP_RUN.
        LOCK TABLE cap_alert_state IN EXCLUSIVE MODE;
        LOCK TABLE cap_run IN EXCLUSIVE MODE;
        SELECT MAX(run_id), MAX(CASE WHEN status = 'OK' AND backdated = 'N' THEN run_id END)
        INTO   l_last, l_last_ok
        FROM   cap_run;
        DELETE FROM cap_alert_event
         WHERE run_id IN (SELECT run_id FROM cap_run
                          WHERE started_at < l_cut AND run_id NOT IN (l_last, NVL(l_last_ok, -1)));
        DELETE FROM cap_fit_hist
         WHERE run_id IN (SELECT run_id FROM cap_run
                          WHERE started_at < l_cut AND run_id NOT IN (l_last, NVL(l_last_ok, -1)));
        DELETE FROM cap_run
         WHERE started_at < l_cut AND run_id NOT IN (l_last, NVL(l_last_ok, -1));
        DELETE FROM cap_alert_state
         WHERE state = 'RESOLVED' AND resolved_at < CAST(l_cut AS DATE);
        COMMIT;
        DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
            RAISE;
    END purge;

    PROCEDURE reset IS
        l_mod VARCHAR2(64);
        l_act VARCHAR2(64);
    BEGIN
        DBMS_APPLICATION_INFO.READ_MODULE(l_mod, l_act);
        DBMS_APPLICATION_INFO.SET_MODULE('AWRCAP/cap_results.reset', NULL);
        LOCK TABLE cap_alert_state IN EXCLUSIVE MODE;
        LOCK TABLE cap_run IN EXCLUSIVE MODE;
        DELETE FROM cap_alert_event;
        DELETE FROM cap_alert_state;
        DELETE FROM cap_fit_hist;
        DELETE FROM cap_run;
        COMMIT;
        DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_APPLICATION_INFO.SET_MODULE(l_mod, l_act);
            RAISE;
    END reset;

END cap_results;
/

-- Every view exists now: re-create the SNAPSHOT cache tables from them.
BEGIN
    cap_results.build_snap_tables;
END;
/
