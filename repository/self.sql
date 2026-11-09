--
-- repository/self.sql -- register this database as the repository's own target.
-- =====================================================================
-- The repository half of the standalone path (install.sh ROLE=standalone,
-- quickstart.sql); target/self.sql is the target half and must have run in
-- this session (its bind :cap_self_pw and its DEFINEs). Run as SYSDBA under
-- ALTER SESSION SET CURRENT_SCHEMA = <suite owner>, once before doctor.sql
-- and once after install.sql:
--
--   SQL> @target/self.sql
--   ... create_owner.sql, CURRENT_SCHEMA ...
--   SQL> @repository/self.sql
--   SQL> @doctor.sql
--   SQL> @install.sql
--   SQL> @repository/self.sql
--
-- Before the first install there is no CAP_REPO yet and it does nothing.
-- A target not registered yet: cap_repo.add_target over the loopback link
-- (named after the global name where GLOBAL_NAMES = TRUE). One registered
-- by an earlier run with the same reader and address: its link is rebuilt
-- with cap_repo.set_link_password when it no longer answers. Then
-- cap_repo.collect.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/repository/self.sql"
SET DEFINE '&'
SET VERIFY   OFF
SET FEEDBACK OFF
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR EXIT FAILURE

PROMPT
PROMPT ==== repository/self.sql: target &cap_self_name over &cap_self_connect ====
DECLARE
    v_name   VARCHAR2(26)   := '&cap_self_name';
    v_conn   VARCHAR2(4000) := '&cap_self_connect';
    v_reader VARCHAR2(128)  := '&reader';
    v_n      NUMBER;
    v_user   VARCHAR2(128);
    v_at     VARCHAR2(4000);
    v_link   VARCHAR2(128);
    v_owned  VARCHAR2(1);
    v_ping   VARCHAR2(4000);
BEGIN
    SELECT COUNT(*) INTO v_n
    FROM   all_objects
    WHERE  owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
      AND  object_name = 'CAP_REPO' AND object_type = 'PACKAGE BODY' AND status = 'VALID';
    IF v_n = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  suite not installed here yet: the target is registered after install.sql');
        RETURN;
    END IF;

    BEGIN
        EXECUTE IMMEDIATE 'SELECT link_user, connect_string, db_link, link_owned'
                          || ' FROM cap_target WHERE target_name = :1'
            INTO v_user, v_at, v_link, v_owned USING v_name;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN v_user := NULL;
    END;

    IF v_user IS NULL THEN
        EXECUTE IMMEDIATE 'BEGIN cap_repo.add_target(:n, :c, :u, :p, p_global_name => :g); END;'
            USING v_name, v_conn, v_reader, :cap_self_pw, '&cap_self_gname';
    ELSIF v_owned = 'Y' AND v_user = v_reader AND v_at = v_conn THEN
        EXECUTE IMMEDIATE 'BEGIN :r := cap_repo.ping(:n); END;' USING OUT v_ping, v_name;
        IF v_ping IS NULL THEN
            DBMS_OUTPUT.PUT_LINE('  target ' || v_name || ' registered, link answers');
        ELSE
            EXECUTE IMMEDIATE 'BEGIN cap_repo.set_link_password(:n, :p); END;'
                USING v_name, :cap_self_pw;
        END IF;
    ELSE
        RAISE_APPLICATION_ERROR(-20001, 'Target ' || v_name || ' is registered with reader '
            || v_user || ' at ' || NVL(v_at, 'link ' || v_link)
            || CASE WHEN v_owned = 'N' THEN ' (a link the DBA made)' END
            || '. Run again with that reader and address (install.sh: READER, SELF_CONNECT),'
            || ' or cap_repo.remove_target(''' || v_name || ''') first, which deletes its copies.');
    END IF;

    EXECUTE IMMEDIATE 'BEGIN cap_repo.collect(:n); END;' USING v_name;
END;
/

WHENEVER SQLERROR CONTINUE
