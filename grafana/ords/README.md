# ORDS module for Grafana

`awrcap_module.sql` publishes the suite's `CAPR_*` views as the ORDS REST
module `awrcap`. The endpoints and their columns are defined in
[`../API.md`](../API.md). Every handler is a `GET` that returns all matching
rows in one response (`p_items_per_page => 0`, verified on ORDS 26.3: a
1251-row response came back with `"hasMore":false`).

The module writes only ORDS metadata (in `ORDS_METADATA`). The handlers run
read-only `SELECT`s against the suite views. The module is protected by the
ORDS privilege `awrcap.read`, which requires the ORDS role `awrcap_reader`:
every handler answers 401 without a bearer token (verified on ORDS 26.3).

## Scripts

| Script | What it does |
|---|---|
| `awrcap_module.sql [schema] [alias] [PROTECTED\|PUBLIC]` | REST-enables the schema (URL alias defaults to the lower-case schema name, `p_auto_rest_auth => FALSE`), defines the `awrcap` module (base path `/awrcap/`) with thirteen GET handlers, creates the role `awrcap_reader` when it is missing and defines the privilege `awrcap.read` over the module. Running it again replaces the module and the privilege and keeps the role and its clients. `PUBLIC` deletes the privilege instead: the handlers are then open to anyone who reaches ORDS. |
| `awrcap_client.sql [schema] [client] [e-mail]` | Creates the OAuth2 client (`client_credentials`, default name `awrcap_grafana`), grants it `awrcap_reader` and prints `ORDS_CLIENT_ID=` and `ORDS_CLIENT_SECRET=`. Running it again replaces the client: a new id and secret. It uses `ORDS_SECURITY` where that package exists (verified on ORDS 26.3) and the older `OAUTH` package otherwise (that branch is written from the documented API and was not run). |
| `awrcap_module_drop.sql [schema] [client]` | Deletes the client, the privilege, the module and the role. The schema stays REST-enabled. Whatever is already gone is skipped. |

An argument given as `-` is skipped (never as the last word of the line:
SQL*Plus reads a trailing `-` as line continuation). The scripts take the
schema from `&1`, or from `CURRENT_SCHEMA` when `&1` is not given. When the session user is the schema owner, the scripts call
`ORDS.*`. Any other user calls `ORDS_ADMIN.*` with `p_schema`. That user needs
`ORDS_ADMINISTRATOR_ROLE` or `EXECUTE ANY PROCEDURE`. SYSDBA has the second.

```
-- as the owner
SQL> @grafana/ords/awrcap_module.sql
-- as SYSDBA, in the PDB that holds the suite
SQL> ALTER SESSION SET CONTAINER = PDB1;
SQL> @grafana/ords/awrcap_module.sql CAPDEMO
SQL> @grafana/ords/awrcap_client.sql CAPDEMO
```

`awrcap_client.sql` prints the secret once and ORDS keeps only its hash.
Send the output to a file only you can read, for Grafana the gitignored
`grafana/.env`:

```
(umask 077; sqlplus -S -L / @grafana/ords/awrcap_client.sql | grep '^ORDS_CLIENT_' >> grafana/.env)
```

A client exchanges its id and secret for a bearer token at
`/ords/<alias>/oauth/token` (HTTP Basic, `grant_type=client_credentials`,
valid 3600 s by default). `REGISTER_CLIENT` registers no secret unless it is
given `ords_types.oauth_client_secret()`, which has ORDS generate one and
return it (verified 26.3).

ORDS caches a module's metadata for a few seconds. After a change of access
(`PUBLIC` to `PROTECTED` or back) a request can still get the old answer for
that long: one read 200 six seconds after the module was protected again,
and 401 from then on (26.3).

The `from` and `to` query parameters are mapped to the bind variables
`:p_from` and `:p_to` with `DEFINE_PARAMETER`, because `:from` and `:to` are
not legal bind names. `kind`, `db` and `series` bind implicitly.

`from` and `to` are parsed with
`TO_TIMESTAMP_TZ(…, 'YYYY-MM-DD"T"HH24:MI:SS.FF3TZR')`. This mask accepts both
`2026-10-01T00:00:00Z` and the `2026-10-01T00:00:00.000Z` that Grafana's
`${__from:date:iso}` sends. A daily point is in range when
`TRUNC(from) <= ts <= to`. When `from` is missing, it defaults to
`TRUNC(SYSDATE) - 120`. When `to` is missing, it defaults to `SYSDATE`. A
request without `kind` on `series` or `forecast` returns an empty `items`
array.

`target_name` comes from one join (`c_tgt` in the script: the dbid's target
from `CAPR_CONTAINER`). A handler that drives from alias `t` and ends its
`FROM` with it gets the column and the `target=` filter.

## Lab deployment (dbmint, done 2026-10-17)

The suite runs in schema `CAPDEMO` in `PDB1` of `cdb1`, in the dbmint VM.
The listener is `192.168.56.111:1521`, and the service is `pdb1.world`. The
VM has no Java, and the SYS password is not known. So ORDS runs in Docker on
the host and is installed with a dedicated admin user instead of SYS.
Image: `container-registry.oracle.com/database/ords:latest` (ORDS
26.3.0.r2721811). Database: 19.27. ORDS 26.3 installed against 19c without
complaint.

1. Extract the installer-privileges script from the image and copy it to the
   VM.

   ```
   docker run --rm --entrypoint cat container-registry.oracle.com/database/ords:latest \
       /opt/oracle/ords/scripts/installer/ords_installer_privileges.sql > /tmp/ordsx/ords_installer_privileges.sql
   scp -P 2200 /tmp/ordsx/ords_installer_privileges.sql oracle@dbmint:/tmp/
   ```

2. Generate the passwords into `grafana/.ords.env` (gitignored, mode 600). The
   file holds `ORDS_INSTALLER_PASSWORD` and `ORDS_PUBLIC_USER_PASSWORD`.

3. As SYSDBA in `PDB1`, create the installer user and grant it the
   privileges:

   ```
   ALTER SESSION SET CONTAINER = PDB1;
   CREATE USER ords_installer IDENTIFIED BY "<ORDS_INSTALLER_PASSWORD>";
   GRANT CREATE SESSION TO ords_installer;
   @/tmp/ords_installer_privileges.sql ORDS_INSTALLER
   ```

   The script granted 37 system privileges and 46 object privileges.

4. Install ORDS into `PDB1`. This creates `ORDS_METADATA` and
   `ORDS_PUBLIC_USER`. The container's own entrypoint needs the SYS password,
   so call the `ords` CLI directly. `--password-stdin` reads two lines: the
   admin password, then the password for the new `ORDS_PUBLIC_USER`. The
   container runs as uid 54321 and must be able to write to the config
   directory during the install. The directory was opened to mode 777 for
   the install and set back to 755 after it.

   ```
   . grafana/.ords.env
   printf '%s\n%s\n' "$ORDS_INSTALLER_PASSWORD" "$ORDS_PUBLIC_USER_PASSWORD" |
   docker run --rm -i -v $PWD/grafana/ords/config:/etc/ords/config --entrypoint ords \
       container-registry.oracle.com/database/ords:latest --config /etc/ords/config install \
       --admin-user ORDS_INSTALLER --db-hostname 192.168.56.111 --db-port 1521 \
       --db-servicename pdb1.world --feature-sdw false --feature-db-api false \
       --feature-rest-enabled-sql false --log-folder /tmp --password-stdin
   ```

   `grafana/ords/config/` now holds `pool.xml`, `settings.xml` and the wallet
   with the `ORDS_PUBLIC_USER` password. Everything in it except `.gitkeep`
   is gitignored. Keep it, and `.ords.env`, off the VM: rsync with
   `--exclude grafana/.ords.env --exclude grafana/ords/config`.

5. Start ORDS. Host port 8080 is already taken on the lab host, by
   `lab-orders-app` on 127.0.0.1:8080, so ORDS is published on 8181.

   ```
   docker run -d --name awrcap-ords -p 8181:8080 -v $PWD/grafana/ords/config:/etc/ords/config \
       --entrypoint ords container-registry.oracle.com/database/ords:latest --config /etc/ords/config serve
   ```

6. Sync the repo to the VM. Install the two view files in `CAPDEMO`, then
   publish the module and create the client (step 6b):

   ```
   rsync -az --delete -e 'ssh -p 2200' --exclude .git --exclude reports \
       --exclude grafana/.ords.env --exclude grafana/ords/config ./ oracle@dbmint:~/awr-capacity-forecast/
   # on the VM, from ~/awr-capacity-forecast, sqlplus / as sysdba:
   ALTER SESSION SET CONTAINER = PDB1;
   ALTER SESSION SET CURRENT_SCHEMA = CAPDEMO;
   @ddl/45_report_views.sql
   @ddl/55_report_views_ml.sql
   SELECT object_name FROM all_objects
   WHERE  owner = SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AND status <> 'VALID';   -- no rows
   @grafana/ords/awrcap_module.sql CAPDEMO
   ```

   6b. The client, from the workstation, straight into `grafana/.env` (the
   secret is never shown):

   ```
   sed -i '/^ORDS_CLIENT_/d' grafana/.env
   (umask 077; ssh -p 2200 oracle@dbmint 'export ORACLE_SID=cdb1 ORAENV_ASK=NO; . oraenv >/dev/null 2>&1
       cd ~/awr-capacity-forecast && printf "%s\n" "ALTER SESSION SET CONTAINER = PDB1;" \
           "@grafana/ords/awrcap_client.sql CAPDEMO" | sqlplus -S -L / as sysdba' |
       grep '^ORDS_CLIENT_' >> grafana/.env)
   docker compose -f grafana/docker-compose.yml up -d    # Grafana re-reads the client
   ```

7. Check the endpoints: 401 without a token, 200 with one.

   ```
   B=http://100.108.246.57:8181/ords/capdemo
   curl -s -o /dev/null -w '%{http_code}\n' $B/awrcap/containers            # 401
   TOK=$( . grafana/.env; printf 'user = "%s:%s"\n' "$ORDS_CLIENT_ID" "$ORDS_CLIENT_SECRET" |
          curl -s -K - -d grant_type=client_credentials $B/oauth/token |
          python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' )
   curl -s -H "Authorization: Bearer $TOK" $B/awrcap/containers
   curl -s -H "Authorization: Bearer $TOK" "$B/awrcap/series?kind=TBSPC&from=2026-06-01T00:00:00.000Z&to=2026-10-17T00:00:00.000Z"
   ```

Base URL: `http://100.108.246.57:8181/ords/capdemo/awrcap/` (the Tailscale address; `grafana/.env` pins `BIND_ADDR`, see `LAB.md`).

To remove everything, run `@grafana/ords/awrcap_module_drop.sql CAPDEMO`
(module, privilege, client and role) and `docker rm -f awrcap-ords`. To remove ORDS from the PDB, run `ords uninstall`
with the same admin user.
