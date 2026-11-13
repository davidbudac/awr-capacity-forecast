--
-- grafana/ords/awrcap_client.sql -- create the OAuth2 client that may read
-- the protected `awrcap` ORDS module (grant type client_credentials, ORDS
-- role awrcap_reader), and print its id and secret.
--
--   As the schema owner:  SQL> @grafana/ords/awrcap_client.sql
--   As a DBA:             SQL> @grafana/ords/awrcap_client.sql CAPDEMO
-- &2 = client name (default awrcap_grafana), &3 = the support e-mail ORDS
-- stores with a client (default awrcap@example.com). `-` skips an argument.
-- Run grafana/ords/awrcap_module.sql first: it creates the role.
--
-- Output: two lines, ORDS_CLIENT_ID=... and ORDS_CLIENT_SECRET=..., the form
-- grafana/.env takes. ORDS shows the secret only now. Send the output to a
-- file only you can read, never to a shared log:
--   (umask 077; sqlplus -S -L / @grafana/ords/awrcap_client.sql | grep '^ORDS_CLIENT_' >> grafana/.env)
-- Running it again replaces the client: a new id and a new secret, and the
-- old pair stops working. One client per consumer (Grafana, Prometheus):
-- pass a second name.
--
-- Uses ORDS_SECURITY where the package exists (verified on ORDS 26.3), else
-- the older OAUTH package. Writes only ORDS metadata.
--
SET APPINFO OFF
SET APPINFO "AWRCAP/grafana/ords/awrcap_client.sql"
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
    c_priv   CONSTANT VARCHAR2(30) := 'awrcap.read';
    c_role   CONSTANT VARCHAR2(30) := 'awrcap_reader';
    c_desc   CONSTANT VARCHAR2(100) := 'Reads the awrcap module (AWR capacity suite)';
    v_schema VARCHAR2(128) := UPPER(NVL(NULLIF('&1', '-'), SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')));
    v_name   VARCHAR2(128) := NVL(NULLIF('&2', '-'), 'awrcap_grafana');
    v_email  VARCHAR2(200) := NVL(NULLIF('&3', '-'), 'awrcap@example.com');
    v_owner  BOOLEAN := SYS_CONTEXT('USERENV', 'SESSION_USER') = v_schema;
    v_adm    VARCHAR2(10);
    v_sch    VARCHAR2(30);
    v_new    PLS_INTEGER;
    v_id     VARCHAR2(400);
    v_secret VARCHAR2(400);

    -- Rows named p_name in an ORDS dictionary view of this schema.
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
    -- p_call with its leading p_schema argument when a DBA runs it.
    PROCEDURE run(p_pkg VARCHAR2, p_call VARCHAR2, p_arg VARCHAR2 := NULL) IS
        v_sql VARCHAR2(400) := 'BEGIN ' || p_pkg || v_adm || '.' || p_call || '(' || v_sch || ':n'
                               || CASE WHEN p_arg IS NOT NULL THEN ', :a' END || '); END;';
    BEGIN
        IF v_owner AND p_arg IS NULL THEN
            EXECUTE IMMEDIATE v_sql USING v_name;
        ELSIF v_owner THEN
            EXECUTE IMMEDIATE v_sql USING v_name, p_arg;
        ELSIF p_arg IS NULL THEN
            EXECUTE IMMEDIATE v_sql USING v_schema, v_name;
        ELSE
            EXECUTE IMMEDIATE v_sql USING v_schema, v_name, p_arg;
        END IF;
    END;
BEGIN
    IF NOT v_owner THEN
        v_adm := '_admin';
        v_sch := ':s, ';
    END IF;
    IF n_ords('roles', c_role) = 0 THEN
        RAISE_APPLICATION_ERROR(-20000, 'ORDS role ' || c_role || ' not found in ' || v_schema
            || ': run grafana/ords/awrcap_module.sql first (access PROTECTED).');
    END IF;
    SELECT COUNT(*) INTO v_new
    FROM   all_objects
    WHERE  owner = 'ORDS_METADATA' AND object_name = 'ORDS_SECURITY' AND object_type = 'PACKAGE';

    IF n_ords('clients', v_name) > 0 THEN
        run(CASE WHEN v_new > 0 THEN 'ords_security' ELSE 'oauth' END, 'delete_client');
    END IF;

    IF v_new > 0 THEN
        -- REGISTER_CLIENT registers no secret unless asked: an empty
        -- oauth_client_secret() has ORDS generate one, return it here and
        -- keep only its hash.
        IF v_owner THEN
            EXECUTE IMMEDIATE q'[DECLARE c ords_types.t_client_credentials;
BEGIN
    c := ords_security.register_client(p_name => :n, p_grant_type => 'client_credentials',
             p_support_email => :e, p_description => :d, p_privilege_names => :p,
             p_client_secret => ords_types.oauth_client_secret());
    :id := c.client_key.client_id;
    :sec := c.client_secret.secret;
END;]' USING v_name, v_email, c_desc, c_priv, OUT v_id, OUT v_secret;
        ELSE
            EXECUTE IMMEDIATE q'[DECLARE c ords_types.t_client_credentials;
BEGIN
    c := ords_security_admin.register_client(p_schema => :s, p_name => :n,
             p_grant_type => 'client_credentials',
             p_support_email => :e, p_description => :d, p_privilege_names => :p,
             p_client_secret => ords_types.oauth_client_secret());
    :id := c.client_key.client_id;
    :sec := c.client_secret.secret;
END;]' USING v_schema, v_name, v_email, c_desc, c_priv, OUT v_id, OUT v_secret;
        END IF;
        run('ords_security', 'grant_client_role', c_role);
    ELSE
        IF v_owner THEN
            EXECUTE IMMEDIATE q'[BEGIN oauth.create_client(p_name => :n, p_grant_type => 'client_credentials',
    p_support_email => :e, p_description => :d, p_privilege_names => :p); END;]'
                USING v_name, v_email, c_desc, c_priv;
            EXECUTE IMMEDIATE 'SELECT client_id, client_secret FROM user_ords_clients WHERE name = :n'
                INTO v_id, v_secret USING v_name;
        ELSE
            EXECUTE IMMEDIATE q'[BEGIN oauth_admin.create_client(p_schema => :s, p_name => :n,
    p_grant_type => 'client_credentials',
    p_support_email => :e, p_description => :d, p_privilege_names => :p); END;]'
                USING v_schema, v_name, v_email, c_desc, c_priv;
            EXECUTE IMMEDIATE 'SELECT v.client_id, v.client_secret FROM dba_ords_clients v JOIN dba_ords_schemas s'
                || ' ON s.id = v.schema_id WHERE s.parsing_schema = :s AND v.name = :n'
                INTO v_id, v_secret USING v_schema, v_name;
        END IF;
        run('oauth', 'grant_client_role', c_role);
    END IF;
    COMMIT;

    IF v_id IS NULL OR v_secret IS NULL THEN
        RAISE_APPLICATION_ERROR(-20000, 'ORDS returned no client id or secret for ' || v_name || '.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('ORDS_CLIENT_ID=' || v_id);
    DBMS_OUTPUT.PUT_LINE('ORDS_CLIENT_SECRET=' || v_secret);
END;
/

UNDEFINE 1 2 3
