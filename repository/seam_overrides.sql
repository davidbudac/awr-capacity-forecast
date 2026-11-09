--
-- repository/seam_overrides.sql -- repository versions of seam.sql views.
-- =====================================================================
-- Read by repository/build.py, never run on its own. ddl/13 is
-- repository/seam.sql with dba_hist_<x> renamed cap_h_<x>; a view defined
-- here replaces seam.sql's view of the same name in ddl/13 instead (comment
-- lines stripped). Only views seam.sql defines may appear here (build.py
-- --check), and nothing else: text outside a CREATE OR REPLACE VIEW would
-- never reach ddl/13. These read the registry tables of
-- repository/cap_repo.sql, which ddl/13 includes before the seam.
--

-- CAPV_TARGET (M24.6) -- the column contract of seam.sql's, over the registry:
-- one row per registered target and DBID (dbid NULL until the first DBID is
-- found), fed LINK, with the collect health from CAP_COLLECT_LOG. Only log
-- rows since the target was added count, so a removed and re-added target
-- starts clean. An ERROR logged with dbid NULL (the link failed before any
-- DBID was reached) applies to every DBID of the target. n_gaps counts GAP
-- rows: snapshots the target purged before they were copied. The health
-- columns are scalar subqueries, not joins, because the optimizer drops an
-- unselected one: CAPR_CONTAINER, which every report view joins and which
-- reads only target_name, never touches the log (verified 19.27).
-- Scoped (the CAP_SCOPE expression) like every seam view, NULL-safe: a
-- target with no DBID yet is in no database's scope.
CREATE OR REPLACE VIEW capv_target AS
SELECT CAST(t.target_name AS VARCHAR2(30))      AS target_name,
       d.dbid                                   AS dbid,
       CAST('LINK' AS VARCHAR2(10))             AS feed,
       CAST(h.host_name AS VARCHAR2(64))        AS host_name,
       CAST(t.connect_string AS VARCHAR2(4000)) AS address,
       CAST(t.db_link AS VARCHAR2(128))         AS db_link,
       CAST(t.enabled AS VARCHAR2(1))           AS enabled,
       d.last_snap_id                           AS collected_snap_id,
       (SELECT MAX(g.logged_at) FROM cap_collect_log g
        WHERE  g.target_name = t.target_name AND g.dbid = d.dbid
          AND  g.status IN ('OK', 'NOTHING') AND g.logged_at >= t.added_at) AS last_ok_at,
       (SELECT MAX(g.logged_at) FROM cap_collect_log g
        WHERE  g.target_name = t.target_name AND (g.dbid = d.dbid OR g.dbid IS NULL)
          AND  g.status = 'ERROR' AND g.logged_at >= t.added_at)            AS last_error_at,
       (SELECT CAST(MAX(g.message) KEEP (DENSE_RANK LAST ORDER BY g.logged_at, g.log_id)
                    AS VARCHAR2(4000))
        FROM   cap_collect_log g
        WHERE  g.target_name = t.target_name AND (g.dbid = d.dbid OR g.dbid IS NULL)
          AND  g.status = 'ERROR' AND g.logged_at >= t.added_at)            AS last_error,
       (SELECT COUNT(*) FROM cap_collect_log g
        WHERE  g.target_name = t.target_name AND g.dbid = d.dbid
          AND  g.status = 'GAP' AND g.logged_at >= t.added_at)              AS n_gaps
FROM   cap_target t
LEFT   JOIN cap_target_dbid d
  ON   d.target_id = t.target_id
LEFT   JOIN (SELECT dbid,
                    MAX(host_name) KEEP (DENSE_RANK LAST ORDER BY startup_time NULLS FIRST) AS host_name
             FROM   cap_h_database_instance
             WHERE  dbid = NVL(TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)), dbid)
             GROUP  BY dbid) h
  ON   h.dbid = d.dbid
WHERE  TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1)) IS NULL
   OR  d.dbid = TO_NUMBER(REGEXP_SUBSTR(SYS_CONTEXT('USERENV', 'CLIENT_INFO'), '^AWRCAP dbid=(-?[0-9]+)$', 1, 1, NULL, 1));
