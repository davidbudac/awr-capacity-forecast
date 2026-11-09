--
-- repository/self.sql -- register this database as the repository's own target.
-- =====================================================================
-- The repository half of the standalone path (install.sh ROLE=standalone,
-- quickstart.sql); target/self.sql is the target half and must have run in
-- this session (its bind :cap_self_pw and its DEFINEs). Run as SYSDBA under
-- ALTER SESSION SET CURRENT_SCHEMA = <suite owner>, after install.sql:
--
--   SQL> @target/self.sql
--   ... create_owner.sql, CURRENT_SCHEMA, install.sql ...
--   SQL> @repository/self.sql
--
-- A target not registered yet: cap_repo.add_target over the loopback link
-- (named after the global name where GLOBAL_NAMES = TRUE). One registered
-- by an earlier run with the same reader and address: cap_repo.set_link_password,
-- because target/self.sql gave the reader a new password. Then cap_repo.collect.
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
    v_name   cap_target.target_name%TYPE := '&cap_self_name';
    v_conn   cap_target.connect_string%TYPE := '&cap_self_connect';
    v_reader cap_target.link_user%TYPE := '&reader';
    t        cap_target%ROWTYPE;
BEGIN
    BEGIN
        SELECT * INTO t FROM cap_target WHERE target_name = v_name;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN NULL;
    END;
    IF t.target_name IS NULL THEN
        cap_repo.add_target(v_name, v_conn, v_reader, :cap_self_pw,
                            p_global_name => '&cap_self_gname');
    ELSIF t.link_owned = 'Y' AND t.link_user = v_reader AND t.connect_string = v_conn THEN
        cap_repo.set_link_password(v_name, :cap_self_pw);
    ELSE
        RAISE_APPLICATION_ERROR(-20001, 'Target ' || v_name || ' is registered with reader '
            || t.link_user || ' at ' || NVL(t.connect_string, 'link ' || t.db_link)
            || CASE WHEN t.link_owned = 'N' THEN ' (a link the DBA made)' END
            || '. Run again with that reader and address (install.sh: READER, SELF_CONNECT),'
            || ' or cap_repo.remove_target(''' || v_name || ''') first, which deletes its copies.');
    END IF;
END;
/

EXEC cap_repo.collect('&cap_self_name')

WHENEVER SQLERROR CONTINUE
