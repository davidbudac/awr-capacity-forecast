--
-- target/self.sql -- make this database a target of a repository inside it.
-- =====================================================================
-- The standalone path (install.sh ROLE=standalone, quickstart.sql). The suite
-- reads this database's AWR the way a repository reads any target's: over a
-- DB link, here a loopback one. This script is the target half. Run as
-- SYSDBA in CDB$ROOT (or a non-CDB), from the repo root:
--
--   SQL> DEFINE container    = PDB1          -- optional, see below
--   SQL> DEFINE reader       = C##AWRRDR     -- optional, as target/prepare.sql
--   SQL> DEFINE self_connect = //host:1521/svc  -- optional, see below
--   SQL> @target/self.sql
--
-- It picks the container the suite lives in: the one open user PDB, or the
-- one container names (with more than one open PDB, container is required).
-- A non-CDB stays where it is. The link's address is
-- //localhost:<local listener port>/<the root's default service>
-- unless self_connect gives one. The reader gets a new random password,
-- held only in this session (bind :cap_self_pw), then target/prepare.sql
-- and target/check.sql run, and the session ends in the suite's container.
-- repository/self.sql, run there after install.sql, registers the target
-- with that password, or updates the link of one registered before.
--
-- Leaves defined: cap_container, cap_self_name (the target name, from
-- DB_UNIQUE_NAME), cap_self_connect, cap_self_gname (the global name, for a
-- repository with GLOBAL_NAMES = TRUE) and reader (the effective name).
--
SET APPINFO OFF
SET APPINFO "AWRCAP/target/self.sql"
SET DEFINE '&'
SET VERIFY   OFF
SET FEEDBACK OFF
SET TAB      OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR EXIT FAILURE

SET TERMOUT OFF
COLUMN cap_c_in NEW_VALUE container    NOPRINT
COLUMN cap_r_in NEW_VALUE reader       NOPRINT
COLUMN cap_s_in NEW_VALUE self_connect NOPRINT
SELECT NULL AS cap_c_in, NULL AS cap_r_in, NULL AS cap_s_in FROM dual WHERE 1 = 0;
COLUMN cap_c_in CLEAR
COLUMN cap_r_in CLEAR
COLUMN cap_s_in CLEAR
SET TERMOUT ON

PROMPT
PROMPT ============================================================
PROMPT  AWR Capacity Forecast -- this database as its own target
PROMPT ============================================================

DECLARE
    v_con  VARCHAR2(10)  := SYS_CONTEXT('USERENV', 'CON_ID');
    v_want VARCHAR2(128) := UPPER(TRIM('&container'));
    v_n    NUMBER;
    v_list VARCHAR2(4000);
BEGIN
    IF SYS_CONTEXT('USERENV', 'ISDBA') <> 'TRUE' THEN
        RAISE_APPLICATION_ERROR(-20001, 'Connect AS SYSDBA: this creates the reader and the'
            || ' suite owner and installs into that owner through CURRENT_SCHEMA.');
    END IF;
    IF v_con NOT IN ('0', '1') THEN
        RAISE_APPLICATION_ERROR(-20001, 'Run this in CDB$ROOT, not in '
            || SYS_CONTEXT('USERENV', 'CON_NAME') || ': AWR lives at the CDB level. Name the'
            || ' PDB for the suite with DEFINE container (install.sh: CONTAINER).');
    END IF;
    IF v_con = '0' THEN
        IF v_want IS NOT NULL THEN
            RAISE_APPLICATION_ERROR(-20001, 'This is a non-CDB: leave container empty, not '
                                            || v_want || '.');
        END IF;
    ELSIF v_want IS NOT NULL THEN
        SELECT COUNT(*) INTO v_n FROM v$pdbs
        WHERE  name = v_want AND con_id > 2 AND open_mode = 'READ WRITE';
        IF v_n = 0 THEN
            RAISE_APPLICATION_ERROR(-20001, 'Container ' || v_want
                                            || ' is not a PDB open READ WRITE here.');
        END IF;
    ELSE
        SELECT COUNT(*), LISTAGG(name, ', ') WITHIN GROUP (ORDER BY name)
        INTO   v_n, v_list
        FROM   v$pdbs WHERE con_id > 2 AND open_mode = 'READ WRITE';
        IF v_n <> 1 THEN
            RAISE_APPLICATION_ERROR(-20001, 'This CDB has ' || v_n || ' PDBs open READ WRITE ('
                || NVL(v_list, 'none') || '): name the one for the suite with DEFINE container'
                || ' (install.sh: CONTAINER). Nothing was changed.');
        END IF;
    END IF;
END;
/

VARIABLE cap_self_pw VARCHAR2(64)
EXEC :cap_self_pw := 'Rd' || DBMS_RANDOM.STRING('X', 22) || 'q7_'

SET TERMOUT OFF
COLUMN cap_c   NEW_VALUE cap_container    NOPRINT
COLUMN cap_n   NEW_VALUE cap_self_name    NOPRINT
COLUMN cap_s   NEW_VALUE cap_self_connect NOPRINT
COLUMN cap_g   NEW_VALUE cap_self_gname   NOPRINT
COLUMN cap_r   NEW_VALUE reader           NOPRINT
COLUMN cap_pw  NEW_VALUE reader_pw        NOPRINT
SELECT CASE WHEN SYS_CONTEXT('USERENV', 'CON_ID') = '1'
            THEN NVL(UPPER(TRIM('&container')),
                     (SELECT MIN(name) FROM v$pdbs WHERE con_id > 2 AND open_mode = 'READ WRITE'))
       END AS cap_c,
       SUBSTR(REGEXP_REPLACE(UPPER(SYS_CONTEXT('USERENV', 'DB_UNIQUE_NAME')), '[^A-Z0-9_]', '_'),
              1, 26) AS cap_n,
       NVL(TRIM('&self_connect'),
           '//localhost:'
           || NVL((SELECT MIN(REGEXP_SUBSTR(value, '\(PORT=([0-9]+)\)', 1, 1, 'i', 1))
                   FROM   v$listener_network WHERE type = 'LOCAL LISTENER'), '1521')
           || '/'
           || NVL((SELECT MIN(network_name) FROM v$services
                   WHERE  con_id = SYS_CONTEXT('USERENV', 'CON_ID')
                     AND  LOWER(name) = LOWER(SYS_CONTEXT('USERENV', 'DB_UNIQUE_NAME')
                                              || NVL2(SYS_CONTEXT('USERENV', 'DB_DOMAIN'),
                                                      '.' || SYS_CONTEXT('USERENV', 'DB_DOMAIN'), NULL))),
                  LOWER(SYS_CONTEXT('USERENV', 'DB_UNIQUE_NAME'))
                  || NVL2(SYS_CONTEXT('USERENV', 'DB_DOMAIN'),
                          '.' || SYS_CONTEXT('USERENV', 'DB_DOMAIN'), NULL))) AS cap_s,
       (SELECT global_name FROM global_name) AS cap_g,
       UPPER(NVL(TRIM('&reader'), CASE WHEN SYS_CONTEXT('USERENV', 'CON_ID') = '1'
                                       THEN 'C##AWRRDR' ELSE 'AWRRDR' END)) AS cap_r,
       :cap_self_pw AS cap_pw
FROM   dual;
COLUMN cap_c  CLEAR
COLUMN cap_n  CLEAR
COLUMN cap_s  CLEAR
COLUMN cap_g  CLEAR
COLUMN cap_r  CLEAR
COLUMN cap_pw CLEAR
SET TERMOUT ON

PROMPT   target name     = &cap_self_name
PROMPT   loopback link   = &cap_self_connect  (reader &reader)
PROMPT   suite container = &cap_container
PROMPT   (empty container: a non-CDB, the suite stays here)

@@target/prepare.sql
SET DEFINE '&'
WHENEVER SQLERROR EXIT FAILURE
@@target/check.sql
SET DEFINE '&'
SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE

BEGIN
    IF '&cap_container' IS NOT NULL THEN
        EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = '
                          || DBMS_ASSERT.SIMPLE_SQL_NAME('&cap_container');
    END IF;
END;
/
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

WHENEVER SQLERROR CONTINUE
