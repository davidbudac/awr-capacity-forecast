--
-- report/scope.sql -- scope and identity of a report run (M24.6).
-- =====================================================================
-- Included by report/report.sql, report_html.sql, report_brief.sql and
-- report_csv.sql once each has DEFINEd cap_arg_db and cap_arg_con from its
-- own positional arguments. It defines:
--   cap_sdbid, cap_scon  a number or the literal NULL, so a section filters
--                        with (&cap_sdbid IS NULL OR dbid = &cap_sdbid) and
--                        an unscoped run reads (NULL IS NULL OR ...). The
--                        dbid argument is digits, or a target name
--                        (CAPV_TARGET, any case) that resolves to the
--                        target's dbid with the newest snapshot. An unknown
--                        name gives -1, which matches nothing, and raises
--                        ORA-20003 so the error is in the session output.
--                        '-', empty or anything else: every database.
--   cap_starget          the target name the argument named (as registered,
--                        or upper-cased when unknown), else empty
--   cap_db, cap_host     the targets in scope, i.e. the CAPV_TARGET rows of
--                        the dbids in scope, and their hosts. Not the
--                        session's database: in repository mode that is the
--                        repository, not what is reported on.
--   cap_user             CURRENT_SCHEMA on CDB_NAME (else DB_NAME)[/CON_NAME]
--   cap_gen              the generation time
--   cap_stem             a file-name stem: the target, 'fleet' for several,
--                        the session's DB_NAME for none
-- And it scopes the session (M24.11): CLIENT_INFO 'AWRCAP dbid=<cap_sdbid>',
-- which CAP_SCOPE reads, so the seam returns only that database's rows and
-- every view above it costs one target, not the fleet. Cleared first, so a
-- scope left by an aborted run cannot hide a target from the lookups here,
-- and NULL for every database. The including driver clears it at its end
-- (DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL)). A con_dbid alone does not
-- scope the session: the sections filter it.
-- Runs and leaves TERMOUT OFF (the drivers' setting here); only the ORA-20003
-- check runs with it ON, so the error reaches the terminal. Leaves DEFINE '&'.
-- Every alias below is cleared at the end: COLUMN settings last the session.
--
SET DEFINE '&'
SET TERMOUT OFF
EXEC DBMS_APPLICATION_INFO.SET_CLIENT_INFO(NULL)

-- cap_starget is the one result that may be empty: UNDEFINE + a zero-row
-- NEW_VALUE query defines it empty, so a name left by an earlier run in the
-- same session cannot leak in. The query below sets it only for a name.
UNDEFINE cap_starget
COLUMN sc_starget NEW_VALUE cap_starget NOPRINT
SELECT NULL AS sc_starget FROM dual WHERE 1 = 0;

-- Defaults, from dual only so they always land: a lookup below that fails
-- (suite not installed) then leaves these instead of undefined variables.
-- A name defaults to "unknown": a failing lookup reports nothing and errors.
COLUMN sc_sdbid NEW_VALUE cap_sdbid NOPRINT
COLUMN sc_scon  NEW_VALUE cap_scon  NOPRINT
COLUMN sc_sbad  NEW_VALUE cap_sbad  NOPRINT
COLUMN sc_db    NEW_VALUE cap_db    NOPRINT
COLUMN sc_host  NEW_VALUE cap_host  NOPRINT
COLUMN sc_user  NEW_VALUE cap_user  NOPRINT
COLUMN sc_gen   NEW_VALUE cap_gen   NOPRINT
COLUMN sc_stem  NEW_VALUE cap_stem  NOPRINT
SELECT CASE WHEN REGEXP_LIKE(TRIM('&cap_arg_db'), '^[0-9]+$') THEN TRIM('&cap_arg_db')
            WHEN REGEXP_LIKE(TRIM('&cap_arg_db'), '^[A-Za-z][A-Za-z0-9_]*$') THEN '-1'
            ELSE 'NULL' END                                                AS sc_sdbid,
       NVL(REGEXP_SUBSTR(TRIM('&cap_arg_con'), '^[0-9]+$'), 'NULL')        AS sc_scon,
       CASE WHEN REGEXP_LIKE(TRIM('&cap_arg_db'), '^[A-Za-z][A-Za-z0-9_]*$')
            THEN 'Y' ELSE 'N' END                                          AS sc_sbad,
       'no database in scope'                                             AS sc_db,
       'unknown'                                                          AS sc_host,
       SYS_CONTEXT('USERENV','CURRENT_SCHEMA') || ' on '
         || NVL(SYS_CONTEXT('USERENV','CDB_NAME'), SYS_CONTEXT('USERENV','DB_NAME'))
         || CASE WHEN TO_NUMBER(SYS_CONTEXT('USERENV','CON_ID')) NOT IN (0, 1)
                 THEN '/' || SYS_CONTEXT('USERENV','CON_NAME') END           AS sc_user,
       TO_CHAR(SYSTIMESTAMP,'YYYY-MM-DD HH24:MI:SS TZR')                     AS sc_gen,
       REGEXP_REPLACE(SYS_CONTEXT('USERENV','DB_NAME'),'[^A-Za-z0-9]+','_')  AS sc_stem
FROM   dual;

-- A target name: returns its row only when the argument is one.
SELECT NVL((SELECT TO_CHAR(dbid)
            FROM  (SELECT t.dbid
                   FROM   capv_target t
                   LEFT   JOIN capr_freshness f
                     ON   f.dbid = t.dbid
                   WHERE  UPPER(t.target_name) = UPPER(TRIM('&cap_arg_db'))
                     AND  t.dbid IS NOT NULL
                   ORDER  BY f.newest_snap DESC NULLS LAST, t.dbid DESC)
            WHERE  ROWNUM = 1), '-1')                                     AS sc_sdbid,
       NVL((SELECT MAX(target_name) FROM capv_target
            WHERE  UPPER(target_name) = UPPER(TRIM('&cap_arg_db'))),
           UPPER(TRIM('&cap_arg_db')))                                    AS sc_starget,
       NVL((SELECT 'N' FROM capv_target
            WHERE  UPPER(target_name) = UPPER(TRIM('&cap_arg_db'))
              AND  ROWNUM = 1), 'Y')                                       AS sc_sbad
FROM   dual
WHERE  REGEXP_LIKE(TRIM('&cap_arg_db'), '^[A-Za-z][A-Za-z0-9_]*$');

-- What is reported on: the targets whose dbid is in scope. A con_dbid scope
-- keeps the dbids that have that container.
WITH t AS (
        SELECT target_name, host_name
        FROM   capv_target
        WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
          AND  (&cap_scon IS NULL
                OR dbid IN (SELECT dbid FROM capv_container WHERE con_dbid = &cap_scon))
     ),
     names AS (
        SELECT COUNT(target_name) AS n,
               MAX(target_name) AS one,
               LISTAGG(target_name, ', ' ON OVERFLOW TRUNCATE) WITHIN GROUP (ORDER BY target_name) AS list
        FROM  (SELECT DISTINCT target_name FROM t)
     ),
     hosts AS (
        SELECT COUNT(*) AS n,
               LISTAGG(host_name, ', ' ON OVERFLOW TRUNCATE) WITHIN GROUP (ORDER BY host_name) AS list
        FROM  (SELECT DISTINCT host_name FROM t WHERE host_name IS NOT NULL)
     ),
     con AS (
        SELECT MAX(NVL(con_name, db_pdb)) AS lbl
        FROM   capr_container
        WHERE  con_dbid = &cap_scon
          AND  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
     )
SELECT CASE WHEN n.n = 0 THEN 'no database in scope'
            WHEN n.n = 1 THEN n.one || CASE WHEN &cap_scon IS NOT NULL
                                            THEN ' / ' || NVL(c.lbl, '&cap_scon') END
            ELSE n.n || ' targets: '
                 || CASE WHEN LENGTH(n.list) > 150 THEN SUBSTR(n.list, 1, 147) || '...'
                         ELSE n.list END
       END                                                                AS sc_db,
       CASE WHEN h.n = 0 THEN 'unknown'
            WHEN h.n = 1 THEN h.list
            ELSE h.n || ' hosts: '
                 || CASE WHEN LENGTH(h.list) > 150 THEN SUBSTR(h.list, 1, 147) || '...'
                         ELSE h.list END
       END                                                                AS sc_host,
       CASE WHEN n.n = 0 THEN REGEXP_REPLACE(SYS_CONTEXT('USERENV','DB_NAME'),'[^A-Za-z0-9]+','_')
            WHEN n.n = 1 THEN REGEXP_REPLACE(n.one,'[^A-Za-z0-9]+','_')
            ELSE 'fleet'
       END                                                                AS sc_stem
FROM   names n
CROSS  JOIN hosts h
CROSS  JOIN con c;

SET TERMOUT ON
BEGIN
    IF '&cap_sbad' = 'Y' THEN
        RAISE_APPLICATION_ERROR(-20003, 'no target named '
            || NVL('&cap_starget', UPPER(TRIM('&cap_arg_db'))) || ' (see CAPR_TARGETS)');
    END IF;
END;
/
SET TERMOUT OFF

-- An unknown name (-1) scopes to no database: the run reads nothing.
BEGIN
    DBMS_APPLICATION_INFO.SET_CLIENT_INFO(CASE WHEN &cap_sdbid IS NOT NULL
                                               THEN 'AWRCAP dbid=' || &cap_sdbid END);
END;
/

COLUMN sc_starget CLEAR
COLUMN sc_sdbid   CLEAR
COLUMN sc_scon    CLEAR
COLUMN sc_sbad    CLEAR
COLUMN sc_db      CLEAR
COLUMN sc_host    CLEAR
COLUMN sc_user    CLEAR
COLUMN sc_gen     CLEAR
COLUMN sc_stem    CLEAR
UNDEFINE cap_sbad
