--
-- grafana/ords/awrcap_module.sql -- publish the suite's CAPR_* views as the
-- ORDS REST module `awrcap` (contract: grafana/API.md).
--
--   As the schema owner:      SQL> @grafana/ords/awrcap_module.sql
--   As a DBA (e.g. SYSDBA):   SQL> ALTER SESSION SET CONTAINER = PDB1;
--                             SQL> @grafana/ords/awrcap_module.sql CAPDEMO
-- &2 = URL alias (default: lower-case schema name), so the base URL is
-- http://<ords>/ords/<alias>/awrcap/. &3 = access: PROTECTED (default) or
-- PUBLIC. `-` skips an argument.
--
-- PROTECTED: the ORDS privilege `awrcap.read` covers the module and needs
-- the ORDS role `awrcap_reader`, so every handler answers 401 without a
-- bearer token. grafana/ords/awrcap_client.sql creates the OAuth2 client
-- (client credentials) that holds the role. PUBLIC removes the privilege:
-- anyone who reaches the ORDS port reads every handler. Use it only on a
-- closed network.
--
-- The owner calls ORDS.*; anyone else calls ORDS_ADMIN.* with p_schema (needs
-- ORDS_ADMINISTRATOR_ROLE or EXECUTE ANY PROCEDURE). Idempotent: ENABLE_SCHEMA
-- re-maps the alias, DEFINE_MODULE replaces the module with its templates and
-- DEFINE_PRIVILEGE replaces the privilege. An existing role and its clients
-- are kept. Writes only ORDS metadata (ORDS_METADATA), never suite or AWR data.
--
-- Every handler is a json/collection query except `metrics`, a PL/SQL block
-- that prints the Prometheus text exposition format (text/plain;
-- version=0.0.4) over CAPR_ALERTS, CAPR_FIT and CAPR_FRESHNESS through HTP.
-- To try its body without ORDS, initialise the OWA environment, run the
-- block between plsql('metrics', q'~ and ~'); and print the page with
-- OWA_UTIL.SHOWPAGE (grafana/API.md shows how).
--
SET APPINFO OFF
SET APPINFO "AWRCAP/grafana/ords/awrcap_module.sql"
SET DEFINE ON
SET VERIFY OFF
SET FEEDBACK OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE

COLUMN 1 NEW_VALUE 1 NOPRINT
COLUMN 2 NEW_VALUE 2 NOPRINT
COLUMN 3 NEW_VALUE 3 NOPRINT
SELECT NULL AS "1", NULL AS "2", NULL AS "3" FROM dual WHERE 1 = 0;

DECLARE
    c_module CONSTANT VARCHAR2(30) := 'awrcap';
    c_priv   CONSTANT VARCHAR2(30) := 'awrcap.read';
    c_role   CONSTANT VARCHAR2(30) := 'awrcap_reader';
    v_schema VARCHAR2(128) := UPPER(NVL(NULLIF('&1', '-'), SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')));
    v_alias  VARCHAR2(128) := NVL(NULLIF('&2', '-'), LOWER(v_schema));
    v_access VARCHAR2(30)  := UPPER(NVL(NULLIF('&3', '-'), 'PROTECTED'));
    v_pkg    VARCHAR2(30);
    v_sch    VARCHAR2(200);

    -- The target of a row: one target per dbid (CAPR_CONTAINER.target_name).
    -- Every handler that has a dbid drives from alias t and ends its FROM
    -- with this join, so a new handler gets target_name the same way.
    c_tgt CONSTANT VARCHAR2(400) :=
        q'[LEFT   JOIN (SELECT dbid AS tg_dbid, MAX(target_name) AS target_name
             FROM   capr_container GROUP BY dbid) tg
  ON   tg.tg_dbid = t.dbid]';
    c_tgt_filter CONSTANT VARCHAR2(100) := q'[(:target IS NULL OR tg.target_name = :target)]';

    -- from/to: ISO-8601 (Grafana's ${__from:date:iso} sends milliseconds and
    -- Z; the mask also accepts no fraction). A daily point belongs to the
    -- range when its day overlaps it, hence TRUNC on the lower bound.
    c_range CONSTANT VARCHAR2(400) :=
        q'[ts >= NVL(TRUNC(CAST(SYS_EXTRACT_UTC(TO_TIMESTAMP_TZ(:p_from, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZR')) AS DATE)), TRUNC(SYSDATE) - 120)
  AND  ts <= NVL(CAST(SYS_EXTRACT_UTC(TO_TIMESTAMP_TZ(:p_to, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZR')) AS DATE), SYSDATE)]';
    -- Hour points take the range as given (no TRUNC), default the last 14 days.
    c_hour_range CONSTANT VARCHAR2(400) :=
        q'[ts >= NVL(CAST(SYS_EXTRACT_UTC(TO_TIMESTAMP_TZ(:p_from, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZR')) AS DATE), SYSDATE - 14)
  AND  ts <= NVL(CAST(SYS_EXTRACT_UTC(TO_TIMESTAMP_TZ(:p_to, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZR')) AS DATE), SYSDATE)]';

    PROCEDURE run(p_call VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'BEGIN ' || v_pkg || '.' || p_call || '; END;';
    END;

    -- p_items_per_page => 0 turns pagination off: the contract is every
    -- matching row in one response. p_mapped lists the URL parameters that
    -- are not legal bind names (from, to, mode); each binds as :p_<name>.
    PROCEDURE get(p_pattern VARCHAR2, p_source VARCHAR2, p_mapped VARCHAR2 := NULL) IS
    BEGIN
        run('define_template(' || v_sch || 'p_module_name => ''' || c_module
            || ''', p_pattern => ''' || p_pattern || ''')');
        run('define_handler(' || v_sch || 'p_module_name => ''' || c_module
            || ''', p_pattern => ''' || p_pattern || ''', p_method => ''GET'''
            || ', p_source_type => ''json/collection'', p_items_per_page => 0'
            || ', p_source => ' || DBMS_ASSERT.ENQUOTE_LITERAL(REPLACE(p_source, '''', '''''')) || ')');
        IF p_mapped IS NOT NULL THEN
            FOR b IN (SELECT REGEXP_SUBSTR(p_mapped, '[^,]+', 1, LEVEL) AS name FROM dual
                      CONNECT BY LEVEL <= REGEXP_COUNT(p_mapped, ',') + 1) LOOP
                run('define_parameter(' || v_sch || 'p_module_name => ''' || c_module
                    || ''', p_pattern => ''' || p_pattern || ''', p_method => ''GET'''
                    || ', p_name => ''' || b.name || ''', p_bind_variable_name => ''p_' || b.name
                    || ''', p_source_type => ''URI'', p_param_type => ''STRING'', p_access_method => ''IN'')');
            END LOOP;
        END IF;
    END;
    -- A PL/SQL handler: the block writes the response itself through HTP.
    PROCEDURE plsql(p_pattern VARCHAR2, p_source VARCHAR2) IS
    BEGIN
        run('define_template(' || v_sch || 'p_module_name => ''' || c_module
            || ''', p_pattern => ''' || p_pattern || ''')');
        run('define_handler(' || v_sch || 'p_module_name => ''' || c_module
            || ''', p_pattern => ''' || p_pattern || ''', p_method => ''GET'''
            || ', p_source_type => ''plsql/block'''
            || ', p_source => ' || DBMS_ASSERT.ENQUOTE_LITERAL(REPLACE(p_source, '''', '''''')) || ')');
    END;
    -- Rows named p_name in an ORDS dictionary view of this schema:
    -- USER_ORDS_* for the owner, DBA_ORDS_* (keyed by schema_id) otherwise.
    FUNCTION n_ords(p_view VARCHAR2, p_name VARCHAR2) RETURN PLS_INTEGER IS
        n PLS_INTEGER;
    BEGIN
        IF v_sch IS NULL THEN
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM user_ords_' || p_view || ' WHERE name = :n'
                INTO n USING p_name;
        ELSE
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM dba_ords_' || p_view || ' v JOIN dba_ords_schemas s'
                || ' ON s.id = v.schema_id WHERE s.parsing_schema = :s AND v.name = :n'
                INTO n USING v_schema, p_name;
        END IF;
        RETURN n;
    END;
BEGIN
    IF v_access NOT IN ('PROTECTED', 'PUBLIC') THEN
        RAISE_APPLICATION_ERROR(-20000, 'access (argument 3) must be PROTECTED or PUBLIC, not ' || v_access);
    END IF;
    IF SYS_CONTEXT('USERENV', 'SESSION_USER') = v_schema THEN
        v_pkg := 'ords';
    ELSE
        v_pkg := 'ords_admin';
        v_sch := 'p_schema => ' || DBMS_ASSERT.ENQUOTE_LITERAL(v_schema) || ', ';
    END IF;

    run('enable_schema(' || CASE WHEN v_sch IS NULL THEN 'p_enabled => TRUE, ' ELSE v_sch || 'p_enabled => TRUE, ' END
        || 'p_url_mapping_type => ''BASE_PATH'', p_url_mapping_pattern => '
        || DBMS_ASSERT.ENQUOTE_LITERAL(v_alias) || ', p_auto_rest_auth => FALSE)');

    run('define_module(' || v_sch || 'p_module_name => ''' || c_module
        || ''', p_base_path => ''/awrcap/'', p_items_per_page => 0, p_status => ''PUBLISHED'''
        || ', p_comments => ''Capacity suite CAPR_* views for Grafana; contract grafana/API.md'')');

    get('containers', q'[
SELECT dbid, con_dbid, db_name, con_name, db_pdb AS db, target_name
FROM   capr_container
WHERE  (:target IS NULL OR target_name = :target)
ORDER  BY db_pdb]');

    get('targets', q'[
SELECT target_name, dbid, db_name, feed, host_name, enabled, n_containers,
       newest_snap, age_hours, is_stale, collected_snap_id, last_ok_at,
       last_error_at, last_error, n_gaps, collect_state
FROM   capr_targets
ORDER  BY target_name, dbid]');

    get('series', q'[
SELECT ts, kind, series, db, con_dbid, value, limit_value, pct, unit,
       anomaly, anomaly_flag, z, expected, threshold, gap,
       used_bytes, size_bytes, limit_bytes, delta_bytes, rate_bpd,
       busy_pct, busy_p95, busy_peak_pct, anomaly_modes, how_hours_flagged,
       target_name
FROM   capr_series_points t
]' || c_tgt || q'[
WHERE  kind = UPPER(:kind)
  AND  (:db IS NULL OR db = :db)
  AND  (:series IS NULL OR series = :series)
  AND  ]' || c_tgt_filter || q'[
  AND  ]' || c_range || q'[
ORDER  BY db, series, ts]', 'from,to');

    get('hourly', q'[
SELECT ts, kind, series, db, con_dbid, day_dt, dow, hour_of_day, unit, value,
       gap, ivl_hours, n_intervals, anomaly, how_expected, how_threshold, how_z,
       how_flag, how_n_hist, target_name
FROM   capr_hourly_points t
]' || c_tgt || q'[
WHERE  (:db IS NULL OR db = :db)
  AND  (:series IS NULL OR series = :series)
  AND  ]' || c_tgt_filter || q'[
  AND  ]' || c_hour_range || q'[
ORDER  BY db, series, ts]', 'from,to');

    get('forecast', q'[
SELECT ts, kind, series, db, con_dbid, method, horizon_days, value, lo, hi,
       limit_value, pct, quality, target_name
FROM   capr_forecast_points t
]' || c_tgt || q'[
WHERE  kind = UPPER(:kind)
  AND  (:db IS NULL OR db = :db)
  AND  (:series IS NULL OR series = :series)
  AND  ]' || c_tgt_filter || q'[
ORDER  BY db, series, method DESC, horizon_days]');

    get('fit', q'[
SELECT kind, series, db, con_dbid, unit, method, value, limit_value, pct,
       slope_per_day, r2, quality, days_to_full, days_to_full_lo, days_to_full_hi,
       accel, train_n, sev, sev_rank, limit_source, last_day, target_name
FROM   capr_fit t
]' || c_tgt || q'[
WHERE  (:kind IS NULL OR kind = UPPER(:kind))
  AND  (:db IS NULL OR db = :db)
  AND  ]' || c_tgt_filter || q'[
ORDER  BY sev_rank, days_to_full NULLS LAST, db, kind, series]');

    get('anomalies', q'[
SELECT ts, kind, series, db, con_dbid, anomaly_kind, anomaly_flag, value,
       expected, threshold, z, shift_pct, unit, sev, sev_rank, message, obs_day,
       baseline_mode, grain, n_hist, alerting, raw_value, target_name
FROM   capr_anomalies t
]' || c_tgt || q'[
WHERE  (:kind IS NULL OR kind = UPPER(:kind))
  AND  (:db IS NULL OR db = :db)
  AND  (:p_mode IS NULL OR baseline_mode = UPPER(:p_mode))
  AND  ]' || c_tgt_filter || q'[
  AND  ]' || c_range || q'[
ORDER  BY ts DESC, sev_rank, db, series]', 'from,to,mode');

    get('alerts', q'[
SELECT TRIM(severity) AS sev, sev_rank, kind AS alert_kind,
       CASE WHEN kind LIKE 'TBSPC%'  THEN 'TBSPC'
            WHEN kind LIKE 'SERIES%' THEN 'SERIES'
            ELSE 'CPU' END AS kind,
       series_key AS series, db_pdb AS db, con_dbid, day_dt AS obs_day,
       value, threshold, LOWER(unit) AS unit, message, baseline_mode, alert_key,
       target_name
FROM   capr_alerts t
]' || c_tgt || q'[
WHERE  (:db IS NULL OR db_pdb = :db)
  AND  ]' || c_tgt_filter || q'[
ORDER  BY sev_rank, db_pdb, kind, series_key]');

    -- Memory sizing (M26.4 report views): instance level, so db is the
    -- root container's label. Report content, never an alert.
    get('mem_verdicts', q'[
SELECT target_name, db_pdb AS db, dbid, con_dbid, instance_number, area,
       area_label, area_rank, mem_mode, grade, reason, reason_text, actionable,
       current_bytes, suggested_bytes, current_size, suggested_size, change_pct,
       suggested_param, exceeds_host_ram, exceeds_sga, n_evidence, n_pressure,
       n_days, window_start, window_end, headline
FROM   capr_mem_verdict t
]' || c_tgt || q'[
WHERE  (:db IS NULL OR db_pdb = :db)
  AND  ]' || c_tgt_filter || q'[
ORDER  BY db_pdb, instance_number, area_rank]');

    get('mem_evidence', q'[
SELECT target_name, db_pdb AS db, dbid, con_dbid, instance_number, area,
       area_label, area_rank, kind AS evidence_kind, signal, direction, value,
       unit, threshold, observed_at, evidence_text
FROM   capr_mem_evidence t
]' || c_tgt || q'[
WHERE  (:db IS NULL OR db_pdb = :db)
  AND  (:area IS NULL OR area = UPPER(:area))
  AND  ]' || c_tgt_filter || q'[
ORDER  BY db_pdb, rank_ev]');

    get('mem_components', q'[
SELECT target_name, db_pdb AS db, dbid, con_dbid, instance_number, component,
       is_pool, current_bytes, min_bytes, max_bytes, pct_of_total, n_ops,
       n_grows, n_shrinks, n_forced_grows, last_resize_at
FROM   capr_mem_components t
]' || c_tgt || q'[
WHERE  (:db IS NULL OR db_pdb = :db)
  AND  ]' || c_tgt_filter || q'[
ORDER  BY db_pdb, rank_comp]');

    get('mem_points', q'[
SELECT ts, target_name, db, dbid, con_dbid, instance_number, component, bytes,
       min_bytes, max_bytes, ops
FROM  (SELECT p.*, NVL(c.db_pdb, TO_CHAR(p.dbid)) AS db
       FROM   capr_mem_comp_points p
       LEFT   JOIN capr_container c
         ON   c.dbid = p.dbid AND c.con_dbid = p.con_dbid) t
]' || c_tgt || q'[
WHERE  (:db IS NULL OR db = :db)
  AND  ]' || c_tgt_filter || q'[
  AND  ]' || c_range || q'[
ORDER  BY db, instance_number, component, ts]', 'from,to');

    plsql('metrics', q'~
DECLARE
    -- Prometheus text exposition 0.0.4. Label values escape backslash,
    -- double quote and newline; numbers print with a leading zero and a '.'
    -- decimal, at most six decimals.
    PROCEDURE ln(p_text VARCHAR2) IS
    BEGIN
        HTP.PRN(p_text || CHR(10));
    END;
    FUNCTION lv(p_val VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN REPLACE(REPLACE(REPLACE(p_val, CHR(92), CHR(92) || CHR(92)),
                               '"', CHR(92) || '"'),
                       CHR(10), CHR(92) || 'n');
    END;
    FUNCTION num(p_n NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN RTRIM(TO_CHAR(p_n, 'FM99999999999999990.999999', 'NLS_NUMERIC_CHARACTERS = ''.,'''), '.');
    END;
    PROCEDURE up(p_val PLS_INTEGER) IS
    BEGIN
        ln('# HELP awrcap_up 1 when the handler read every view, 0 when one raised.');
        ln('# TYPE awrcap_up gauge');
        ln('awrcap_up ' || p_val);
    END;
BEGIN
    OWA_UTIL.MIME_HEADER('text/plain; version=0.0.4', TRUE);
    ln('# HELP awrcap_alert Current CAPR_ALERTS rows per kind, severity, container, series and baseline mode (normally 1).');
    ln('# TYPE awrcap_alert gauge');
    FOR r IN (SELECT kind, TRIM(severity) AS severity, db_pdb, con_dbid, series_key,
                     NVL(baseline_mode, '-') AS b_mode, COUNT(*) AS n
              FROM   capr_alerts
              GROUP  BY kind, TRIM(severity), db_pdb, con_dbid, series_key, NVL(baseline_mode, '-')
              ORDER  BY kind, db_pdb, series_key, b_mode) LOOP
        ln('awrcap_alert{kind="' || lv(r.kind) || '",severity="' || lv(r.severity)
           || '",db="' || lv(r.db_pdb) || '",con_dbid="' || r.con_dbid
           || '",series="' || lv(r.series_key) || '",mode="' || lv(r.b_mode) || '"} ' || r.n);
    END LOOP;
    ln('# HELP awrcap_days_to_full Days until the series reaches its ceiling (tablespace full, CPU saturation, series limit) from CAPR_FIT; series with no projected crossing are omitted.');
    ln('# TYPE awrcap_days_to_full gauge');
    FOR r IN (SELECT kind, db, con_dbid, series, quality, days_to_full
              FROM   capr_fit
              WHERE  days_to_full IS NOT NULL
              ORDER  BY kind, db, series) LOOP
        ln('awrcap_days_to_full{kind="' || lv(r.kind) || '",db="' || lv(r.db)
           || '",con_dbid="' || r.con_dbid || '",series="' || lv(r.series)
           || '",quality="' || lv(r.quality) || '"} ' || num(r.days_to_full));
    END LOOP;
    ln('# HELP awrcap_pct_used Current value as a percent of its ceiling from CAPR_FIT (CPU: of the saturation line cpu_sat_pct).');
    ln('# TYPE awrcap_pct_used gauge');
    FOR r IN (SELECT kind, db, con_dbid, series, pct
              FROM   capr_fit
              WHERE  pct IS NOT NULL
              ORDER  BY kind, db, series) LOOP
        ln('awrcap_pct_used{kind="' || lv(r.kind) || '",db="' || lv(r.db)
           || '",con_dbid="' || r.con_dbid || '",series="' || lv(r.series) || '"} ' || num(r.pct));
    END LOOP;
    ln('# HELP awrcap_data_through_days Days since the newest AWR snapshot day of each database (CAPR_FRESHNESS), labelled with its target; 0 = data through today.');
    ln('# TYPE awrcap_data_through_days gauge');
    FOR r IN (SELECT f.db_name, f.dbid, tg.target_name, TRUNC(SYSDATE) - f.newest_day AS age_days
              FROM   capr_freshness f
              LEFT   JOIN (SELECT dbid, MAX(target_name) AS target_name
                           FROM   capr_container GROUP BY dbid) tg
                ON   tg.dbid = f.dbid
              ORDER  BY f.db_name, f.dbid) LOOP
        ln('awrcap_data_through_days{db="' || lv(r.db_name) || '",dbid="' || r.dbid
           || '",target="' || lv(r.target_name) || '"} ' || num(r.age_days));
    END LOOP;
    up(1);
EXCEPTION
    WHEN OTHERS THEN
        ln('# awrcap metrics failed: ' || REPLACE(REPLACE(SQLERRM, CHR(10), ' '), CHR(13), ' '));
        up(0);
END;
~');

    -- Access. The privilege names the module, so it is (re)defined after
    -- the module. The role is created once and kept: deleting it would take
    -- it from the clients that hold it.
    IF v_access = 'PROTECTED' THEN
        IF n_ords('roles', c_role) = 0 THEN
            run('create_role(' || v_sch || 'p_role_name => ''' || c_role || ''')');
        END IF;
        EXECUTE IMMEDIATE 'DECLARE r owa.vc_arr; p owa.vc_arr; m owa.vc_arr; BEGIN r(1) := ''' || c_role
            || '''; m(1) := ''' || c_module || '''; ' || v_pkg || '.define_privilege(' || v_sch
            || 'p_privilege_name => ''' || c_priv || ''', p_roles => r, p_patterns => p, p_modules => m'
            || ', p_label => ''AWR capacity read'''
            || ', p_description => ''Read the awrcap module (capacity suite CAPR_* views)''); END;';
    ELSIF n_ords('privileges', c_priv) > 0 THEN
        run('delete_privilege(' || v_sch || 'p_name => ''' || c_priv || ''')');
    END IF;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('awrcap module published for ' || v_schema || ' at /ords/' || v_alias || '/awrcap/ (via ' || v_pkg || ')');
    IF v_access = 'PROTECTED' THEN
        DBMS_OUTPUT.PUT_LINE('Access: PROTECTED. Every handler needs a bearer token of a client that holds the ORDS role ' || c_role || '.');
        DBMS_OUTPUT.PUT_LINE('Create the client with grafana/ords/awrcap_client.sql ' || v_schema || ' (it prints the id and the secret once).');
        DBMS_OUTPUT.PUT_LINE('Token URL: /ords/' || v_alias || '/oauth/token, grant_type=client_credentials.');
    ELSE
        DBMS_OUTPUT.PUT_LINE('Access: PUBLIC. Anyone who reaches the ORDS port reads every handler.');
    END IF;
END;
/

UNDEFINE 1 2 3
