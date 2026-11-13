# LAB.md — how to bring the lab back up

A note to future me (and Claude). This is the workstation-specific state
behind the two optional visual paths (`elk/`, `grafana/`); none of it is
derivable from the repo. Everything user-facing is published on the
Tailscale address of this workstation, **100.108.246.57**, not on localhost.

## URLs

| What | URL | Login |
|---|---|---|
| Grafana (route B) | http://100.108.246.57:3001 | admin / (see grafana/.env: GF_ADMIN_PASSWORD); anonymous = viewer |
| Grafana boards | /d/awrcap-tablespaces, /d/awrcap-cpu-series, /d/awrcap-fleet-anomalies, /d/awrcap-memory | |
| ORDS module (route B) | http://100.108.246.57:8181/ords/capdemo/awrcap/{containers,targets,series,hourly,forecast,fit,anomalies,alerts,mem_verdicts,mem_evidence,mem_components,mem_points,metrics} | bearer token of the OAuth2 client in grafana/.env (ORDS_CLIENT_ID / ORDS_CLIENT_SECRET); 401 without |
| ORDS token | http://100.108.246.57:8181/ords/capdemo/oauth/token (`grant_type=client_credentials`, HTTP Basic) | the same client |
| APEX app (route C) | http://100.108.246.57:8023/ords/r/awrcap/awrcap/overview | AWRCAP_VIEWER (password: ask the maintainer; not in the repo); App Builder: ADMIN |
| APEX workspace sign-in | http://100.108.246.57:8023/ords/r/apex/workspace-sign-in/ (workspace AWRCAP) | ADMIN |
| Kibana (ELK path) | http://100.108.246.57:5601 | elastic / (docker-elk .env: ELASTIC_PASSWORD) |
| Kibana boards | /app/dashboards#/view/awrcap-dashboard-tablespaces, …-cpu-series, …-fleet-anomalies, …-memory | |
| Elasticsearch | http://100.108.246.57:9200 (index `awrcap-capacity`) | elastic / (docker-elk .env: ELASTIC_PASSWORD) |
| Logstash Beats input | 192.168.56.1:5044 (host-only adapter; what the VM's Filebeat targets) | mTLS |
| Docs site (local render) | `python3 -m http.server 8765 --bind 100.108.246.57 -d docs` then http://100.108.246.57:8765/usage.html | |

Kibana, Elasticsearch and Logstash belong to the docker-elk project at
`/home/db/github/docker-elk` (published on 0.0.0.0, so the Tailscale address
works). Grafana and ORDS belong to this repo and are pinned to the Tailscale
address by the gitignored `grafana/.env` (`BIND_ADDR=100.108.246.57`), which
also holds `GF_ADMIN_PASSWORD` and the ORDS client (`ORDS_CLIENT_ID`,
`ORDS_CLIENT_SECRET`). The compose file stops without the admin password.
Grafana reads it only when it initialises an empty data volume. On an
existing volume set it from the file:
`docker exec awrcap-grafana sh -c 'printf %s "$GF_SECURITY_ADMIN_PASSWORD" | grafana cli admin reset-admin-password --password-from-stdin'`.
The containers bind-mount `grafana/provisioning`, `grafana/dashboards` and
`grafana/ords/config` of the checkout they were started from: start them
from the checkout that stays.

## Where the data comes from

The dbmint VM (`ssh -p 2200 oracle@dbmint`, VirtualBox, host-only IP
192.168.56.111, cdb1 19.27, PDB1). Two schemas hold the suite with fixture
data: **CAPDEMO** (demo_fixture, "ECOMPRD", re-anchored to 2026-11-13) and
**CAPTEST** (fixture_install, "FIXCDB", anchored to 2026-10-17). Both feed
ELK; only CAPDEMO has the ORDS module. The CAPTEST documents in the index
predate `cap.target_name` and the memory records. Every sqlplus call needs the oraenv preamble:
`export ORACLE_SID=cdb1; export ORAENV_ASK=NO; . oraenv >/dev/null 2>&1; sqlplus -S -L / as sysdba`
then `ALTER SESSION SET CONTAINER = PDB1; ALTER SESSION SET CURRENT_SCHEMA = CAPDEMO;`.
To re-anchor the fixtures to today: from `~/awr-capacity-forecast` on the
VM run `@test/demo_fixture.sql` (CAPDEMO) or `@test/fixture_install.sql`
(CAPTEST), then `DEFINE deploy_mode = fixture`, `@install.sql`,
`EXEC cap_forecast_ml.train_all`, then `@grafana/ords/awrcap_module.sql CAPDEMO`
if the schema was recreated (the module is protected; the role and the
client survive a re-run). A new client, or a first one, goes straight into
`grafana/.env` with step 6b of `grafana/ords/README.md`, then
`docker compose -f grafana/docker-compose.yml up -d` so Grafana reads it.
One harness at a time.

Sync the repo to the VM before running anything there:
`rsync -az --delete -e 'ssh -p 2200' --exclude .git --exclude reports --exclude grafana/.ords.env --exclude grafana/ords/config --exclude grafana/.env ./ oracle@dbmint:~/awr-capacity-forecast/`
(the excludes keep the ORDS passwords and wallet off the VM).

## Start order

1. **VM.** Start the `ol9-19-dg1` VirtualBox VM (port 2200). Check
   `v$instance.status`; after a boot the DB may be MOUNTED:
   `alter database open; alter pluggable database all open;`.
2. **docker-elk.** `cd /home/db/github/docker-elk && docker compose up -d`.
   Logstash loads `logstash/pipeline/oracle.conf` and our
   `oracle_capacity.conf` (copied from `elk/logstash/`; recopy + `docker
   compose restart logstash` after editing it).
3. **Grafana + ORDS.** `docker compose -f grafana/docker-compose.yml up -d`
   from the repo root. ORDS needs its config dir `grafana/ords/config/`
   (gitignored; holds pool.xml + wallet). If it is gone, redo the one-time
   install in `grafana/ords/README.md` using the passwords in
   `grafana/.ords.env`. Grafana needs `ORDS_CLIENT_ID` and
   `ORDS_CLIENT_SECRET` in `grafana/.env`, or every panel reads 401.
4. **Filebeat on the VM** (hand-started, dies with the VM):
   `ssh -p 2200 oracle@dbmint 'cd /u01/app/oracle/filebeat && pgrep -x filebeat || (nohup ./filebeat -c /u01/app/oracle/filebeat/filebeat.yml >> logs/nohup.out 2>&1 & echo $! > filebeat.pid)'`
   Check with `pgrep -x filebeat` (never `pgrep -f`, it matches its own shell).
   The input `inputs.d/awrcap.yml` is already in place (copy from
   `elk/filebeat/` if not).
5. **Export for ELK** (daily, or whenever the fixtures were re-anchored):
   `ssh -p 2200 oracle@dbmint 'cd ~/awr-capacity-forecast && for s in CAPDEMO CAPTEST; do elk/export.sh --sid cdb1 --container PDB1 --schema $s; done'`
   Filebeat ships within seconds; re-exports overwrite (deterministic ids).
6. **Kibana objects** only after a builder change:
   `ES_PASSWORD=... KIBANA_PASSWORD=... elk/setup.sh`
   (the two passwords have no default; `ES_URL`/`KIBANA_URL` default to
   localhost; set them to the Tailscale address or run it on the host, where
   localhost works for docker-elk).

## Health checks

`export ES_PASSWORD` first (the `elastic` user's password).

```
curl -s -o /dev/null -w '%{http_code}\n' http://100.108.246.57:8181/ords/capdemo/awrcap/containers   # 401: protected
B=http://100.108.246.57:8181/ords/capdemo
TOK=$( . grafana/.env; printf 'user = "%s:%s"\n' "$ORDS_CLIENT_ID" "$ORDS_CLIENT_SECRET" |
       curl -s -K - -d grant_type=client_credentials $B/oauth/token |
       python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' )
curl -s -H "Authorization: Bearer $TOK" $B/awrcap/containers | head -c 200
curl -s http://100.108.246.57:3001/api/health
curl -s -u "elastic:$ES_PASSWORD" 'http://100.108.246.57:9200/awrcap-capacity/_count'
docker logs --since 10m docker-elk-logstash-1 2>&1 | grep -ci error
ssh -p 2200 oracle@dbmint 'pgrep -x filebeat; ls -t /u01/app/oracle/filebeat/generated | head -3'
```

## APEX app (route C)

Lives in the docker container `23cfree` on this workstation (Oracle 23ai Free
+ APEX 26.2 + ORDS, built per Matt Mulvaney's single-step 23c/APEX container;
host port 8023, PDB `FREEPDB1`). It shares the instance with the
`orastats_gather_dashboard` project (workspace MONITORING, apps 100/101): do
not touch those. Ours: workspace **AWRCAP**, parsing schema **AWRCAP**, app
**110**, alias `awrcap`, users ADMIN (developer) and AWRCAP_VIEWER (end user).

The data is the demo story installed INTO FREEPDB1 (schema AWRCAP, fixture
mode, `test/demo_fixture.sql`, ESM models trained), not the dbmint VM, so the
app works with the VM down. Re-anchor it to today with the same four steps
as on the VM (fixture, `DEFINE deploy_mode = fixture`, `@install.sql`,
`EXEC cap_forecast_ml.train_all`) connected as AWRCAP, then press **Refresh
data** in the app.

Start order: `docker start 23cfree`, wait for
`curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8023/ords/` to answer
302, then open the URL above. Re-publish the app after a builder change with
`apex/publish.sh` (it reads the SYS password from the container's `ORACLE_PWD`
and never prints it). The AWRCAP schema password is not in the repo either;
reset it as SYSTEM if needed (`alter user awrcap identified by ...`).

## Gotchas collected while building this

- Host port 8080 is taken by `lab-orders-app`; ORDS is on 8181.
- Port 3000 is Langfuse; Grafana is on 3001.
- The ORDS container runs as uid 54321; `grafana/ords/config` must be
  writable by it during `ords install` only.
- ORDS throttles beyond ~10 concurrent requests (429/555); the forecast and
  anomalies endpoints take 5-7 s each on the fixture. `mem_verdicts` took
  130 s and `mem_evidence` 75 s on the demo fixture while two harnesses ran
  on the VM (2026-11-13); the data source waits 300 s.
- `elk/setup.sh` on Kibana 9.4 needs the internal-origin header on its
  settings call (it sends it).
- Kibana "latest export" memory tables read the last two days, like the fit
  tiles.
- Kibana/Lens "latest export" panels read fit/alert docs from the last 2
  days: run the export daily or those tiles go blank.
- The SYS password of cdb1 is unknown by design; everything DB-side goes
  through OS authentication over ssh, and ORDS was installed with the
  `ORDS_INSTALLER` user instead.
