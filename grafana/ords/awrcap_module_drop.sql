--
-- grafana/ords/awrcap_module_drop.sql -- remove what awrcap_module.sql and
-- awrcap_client.sql created: the `awrcap` ORDS module, the privilege
-- `awrcap.read`, the OAuth2 client and the role `awrcap_reader`.
--
--   As the schema owner:  SQL> @grafana/ords/awrcap_module_drop.sql
--   As a DBA:             SQL> @grafana/ords/awrcap_module_drop.sql CAPDEMO
-- &2 = the client to delete (default awrcap_grafana). A client created under
-- another name loses the role with it but stays: run the script again with
-- its name. `-` skips an argument.
--
-- Leaves the schema REST-enabled (other modules may live there); disable it
-- with ORDS.ENABLE_SCHEMA(p_enabled => FALSE) if awrcap was the only one.
-- Whatever is already gone is skipped.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/grafana/ords/awrcap_module_drop.sql"
SET DEFINE ON
SET VERIFY OFF
SET FEEDBACK OFF
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE

COLUMN 1 NEW_VALUE 1 NOPRINT
COLUMN 2 NEW_VALUE 2 NOPRINT
SELECT NULL AS "1", NULL AS "2" FROM dual WHERE 1 = 0;

DECLARE
    v_schema VARCHAR2(128) := UPPER(NVL(NULLIF('&1', '-'), SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')));
    v_client VARCHAR2(128) := NVL(NULLIF('&2', '-'), 'awrcap_grafana');
    v_owner  BOOLEAN := SYS_CONTEXT('USERENV', 'SESSION_USER') = v_schema;
    v_new    PLS_INTEGER;
    v_done   VARCHAR2(200);

    FUNCTION n_ords(p_view VARCHAR2, p_name VARCHAR2) RETURN PLS_INTEGER IS
        n PLS_INTEGER;
    BEGIN
        IF v_owner THEN
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM user_ords_' || p_view || ' WHERE name = :n'
                INTO n USING p_name;
        ELSE
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM dba_ords_' || p_view || ' v JOIN dba_ords_schemas s'
                || ' ON s.id = v.schema_id WHERE s.parsing_schema = :s AND v.name = :n'
                INTO n USING v_schema, p_name;
        END IF;
        RETURN n;
    END;
    -- <p_pkg>[_admin].<p_proc>([p_schema,] <p_param> => p_name), when the
    -- dictionary view p_view still lists p_name.
    PROCEDURE drop_it(p_view VARCHAR2, p_name VARCHAR2, p_pkg VARCHAR2, p_proc VARCHAR2, p_param VARCHAR2) IS
    BEGIN
        IF n_ords(p_view, p_name) = 0 THEN
            RETURN;
        END IF;
        IF v_owner THEN
            EXECUTE IMMEDIATE 'BEGIN ' || p_pkg || '.' || p_proc || '(' || p_param || ' => :n); END;'
                USING p_name;
        ELSE
            EXECUTE IMMEDIATE 'BEGIN ' || p_pkg || '_admin.' || p_proc || '(p_schema => :s, ' || p_param
                || ' => :n); END;' USING v_schema, p_name;
        END IF;
        v_done := v_done || ' ' || p_view || ':' || p_name;
    END;
BEGIN
    SELECT COUNT(*) INTO v_new
    FROM   all_objects
    WHERE  owner = 'ORDS_METADATA' AND object_name = 'ORDS_SECURITY' AND object_type = 'PACKAGE';

    drop_it('clients', v_client, CASE WHEN v_new > 0 THEN 'ords_security' ELSE 'oauth' END,
            'delete_client', 'p_name');
    drop_it('privileges', 'awrcap.read', 'ords', 'delete_privilege', 'p_name');
    drop_it('modules', 'awrcap', 'ords', 'delete_module', 'p_module_name');
    drop_it('roles', 'awrcap_reader', 'ords', 'delete_role', 'p_role_name');
    COMMIT;
    DBMS_OUTPUT.PUT_LINE('awrcap removed from ' || v_schema || ':' || NVL(v_done, ' nothing to remove'));
END;
/

UNDEFINE 1 2
