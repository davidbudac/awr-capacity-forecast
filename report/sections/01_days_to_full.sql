--
-- 01_days_to_full.sql -- tablespaces ranked by days-to-full + near-full-now.
-- FORMAT ONLY (M8.2): every number, label and severity marker comes from
-- CAPR_TBSPC_DAYS_TO_FULL, the same view the HTML report reads, so the two
-- drivers cannot drift. sev_dtf / sev_nearfull are CAPR_SEVERITY's, the
-- severities CAPR_ALERTS raises (CAP_CONFIG thresholds or a tablespace's
-- CAP_TBSPC_OVERRIDE ones); the &dtf_*/&nf_* substitutions below are only
-- echoed in the PROMPT headers.
--
-- Scope: the view's rank_dtf / rank_nearfull count per database; a container
-- scope re-numbers them with ROW_NUMBER() OVER (PARTITION BY dbid ORDER BY
-- rank_*), so top_n counts inside the scope. Unscoped, s_rank = rank_* and a
-- fleet report lists the top_n of each database, grouped by database.
--
-- M7.1: the ranking no longer hides non-OK fits -- every computable
-- days_to_full appears WITH its quality marker (a LOW_CONFIDENCE estimate is
-- still a signal; the marker tells you how hard to trust it), and a second
-- "near-full now" ranking by PCT_USED is independent of fit quality entirely,
-- so a 97%-full tablespace with INSUFFICIENT_HISTORY can never vanish.
--
PROMPT
PROMPT == 1a. TABLESPACES BY DAYS-TO-FULL (any quality; top &top_n) ==
PROMPT     SEV: CRIT<=&dtf_crit days, WARN<=&dtf_warn days (or the tablespace's own override),
PROMPT     the severity CAPR_ALERTS raises. GATE says why a row in that window does not page:
PROMPT     low-q / short = the fit is not OK, cyclic = a purge cycle judged on its peak line,
PROMPT     stale = no longer reported (is_current N), lim<used = the limit is already under
PROMPT     the usage (1b pages it). ACCEL>1.5 = growth accelerating. Trust the estimate per
PROMPT     QUALITY (only OK is reliable).
PROMPT     WORST/BEST: days-to-full range from the 95% CI on the growth slope
PROMPT     (WORST = plausibly fastest fill; BEST empty = might never fill).
PROMPT     CYCLIC = a recurring purge cycle (CYC_D days apart), ranked after the rows with a
PROMPT     DAYS_FULL when it has none, and judged on its peaks: PEAK% = highest fill in the
PROMPT     window, DAYS_FULL = when the peak line reaches the limit (empty when the peaks
PROMPT     do not grow).
PROMPT     NEED_90_GIB = space to add so the worst case (upper 95% band) stays under the
PROMPT     limit for 90 days. ADD_BY = the worst-case fill date (last day + WORST).
PROMPT     RESTART = why the fit uses less than the whole window: PURGE (since a purge
PROMPT     cliff), START (since growth began). Section 2 lists the stopped ones (STOP).

COLUMN db_pdb          FORMAT A20           HEADING 'DB/PDB'
COLUMN tablespace_name FORMAT A18           HEADING 'TABLESPACE'
COLUMN pct_used        FORMAT 990.0         HEADING 'PCT_USED'
COLUMN cur_gb          FORMAT 99990.00      HEADING 'CUR_GIB'
COLUMN limit_gb        FORMAT 99990.00      HEADING 'LIMIT_GIB'
COLUMN slope_mb        FORMAT 999990.000    HEADING 'MIB/DAY'
COLUMN days_to_full    FORMAT 99999990      HEADING 'DAYS_FULL'
COLUMN dtf_worst       FORMAT 99999990      HEADING 'WORST'
COLUMN dtf_best        FORMAT 99999990      HEADING 'BEST'
COLUMN sev             FORMAT A4            HEADING 'SEV'
COLUMN gate            FORMAT A8            HEADING 'GATE'
COLUMN quality         FORMAT A20           HEADING 'QUALITY'
COLUMN accel           FORMAT 990.00        HEADING 'ACCEL'
COLUMN cycle_days      FORMAT 9990          HEADING 'CYC_D'
COLUMN cycle_peak_pct  FORMAT 990.0         HEADING 'PEAK%'
COLUMN need_gib_90     FORMAT 9999990.00    HEADING 'NEED_90_GIB'
COLUMN add_by          FORMAT A10           HEADING 'ADD_BY'
COLUMN restart_reason  FORMAT A7            HEADING 'RESTART'

SELECT db_pdb,
       tablespace_name,
       pct_used,
       cur_gb,
       limit_gb,
       slope_mb,
       days_to_full,
       dtf_worst,
       dtf_best,
       sev_dtf AS sev,
       gate,
       quality,
       accel,
       cycle_days,
       cycle_peak_pct,
       need_gib_90,
       TO_CHAR(add_by_day, 'YYYY-MM-DD') AS add_by,
       restart_reason
FROM  (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.dbid ORDER BY t.rank_dtf) AS s_rank
       FROM   capr_tbspc_days_to_full&cap_s t
       WHERE  (&cap_sdbid IS NULL OR t.dbid = &cap_sdbid)
         AND  (&cap_scon  IS NULL OR t.con_dbid = &cap_scon))
WHERE  (days_to_full IS NOT NULL OR quality = 'CYCLIC')
  AND  s_rank <= &top_n
ORDER  BY dbid, s_rank;

PROMPT
PROMPT == 1b. NEAR-FULL NOW (by PCT_USED, independent of fit quality; top &top_n) ==
PROMPT     SEV: CRIT>=&nf_crit%, WARN>=&nf_warn% used. A tablespace can be nearly full
PROMPT     today even when its growth is too flat/erratic to forecast.

SELECT db_pdb,
       tablespace_name,
       pct_used,
       cur_gb,
       limit_gb,
       days_to_full,
       sev_nearfull AS sev,
       quality
FROM  (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.dbid ORDER BY t.rank_nearfull) AS s_rank
       FROM   capr_tbspc_days_to_full&cap_s t
       WHERE  (&cap_sdbid IS NULL OR t.dbid = &cap_sdbid)
         AND  (&cap_scon  IS NULL OR t.con_dbid = &cap_scon))
WHERE  pct_used IS NOT NULL
  AND  s_rank <= &top_n
ORDER  BY dbid, s_rank;

-- 1c (U09): the disk the datafiles share, one row per database, then the
-- growing tablespaces on it. FORMAT ONLY: CAPR_DISK owns the disk's numbers
-- and the DISK_FULL severity, CAPR_TBSPC_SHARED the tablespaces'. A disk row
-- is filed under the database (con_dbid = dbid), so a PDB scope lists none.
PROMPT
PROMPT == 1c. SHARED DISK (all tablespaces of a database on one disk) ==
PROMPT     FREE_GIB = free space on the disk now. SOURCE: OVERRIDE = CAP_DISK_OVERRIDE,
PROMPT     LIVE = derived from the live tablespace ceilings at AS_OF, NONE = not known.
PROMPT     DAYS_FULL = days until the growing tablespaces have used it (WORST = all at
PROMPT     their worst-case rate at once). Empty = it does not fill, or FREE_GIB is not known.
PROMPT     SEV: CRIT<=&dtf_crit days, WARN<=&dtf_warn days, the DISK_FULL alert. GATE no-ok = no
PROMPT     growing tablespace has an OK fit. FASTEST = the three fastest growing, MiB/day.

COLUMN db              FORMAT A20           HEADING 'DB'
COLUMN disk_name       FORMAT A16           HEADING 'DISK'
COLUMN disk_source     FORMAT A8            HEADING 'SOURCE'
COLUMN as_of           FORMAT A16           HEADING 'AS_OF'
COLUMN disk_free_gb    FORMAT 9999990.00    HEADING 'FREE_GIB'
COLUMN alloc_gb        FORMAT 9999990.00    HEADING 'ALLOC_GIB'
COLUMN grow_mb         FORMAT 999990.000    HEADING 'MIB/DAY'
COLUMN disk_dtf        FORMAT 99999990      HEADING 'DAYS_FULL'
COLUMN disk_dtf_worst  FORMAT 99999990      HEADING 'WORST'
COLUMN full_on         FORMAT A10           HEADING 'FULL_ON'
COLUMN disk_gate       FORMAT A5            HEADING 'GATE'
COLUMN n_growing       FORMAT 99990         HEADING 'GROW'
COLUMN top_growers     FORMAT A60           HEADING 'FASTEST'

SELECT db,
       disk_name,
       disk_source,
       TO_CHAR(disk_as_of, 'YYYY-MM-DD HH24:MI') AS as_of,
       disk_free_gb,
       alloc_gb,
       grow_mb,
       disk_dtf,
       disk_dtf_worst,
       TO_CHAR(disk_full_day, 'YYYY-MM-DD')      AS full_on,
       sev,
       CASE WHEN gated_by IS NOT NULL THEN 'no-ok' END AS disk_gate,
       n_growing,
       top_growers
FROM   capr_disk&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, disk_name;

PROMPT
PROMPT     Growing tablespaces on the shared disk (top &top_n). SHARED = days until the
PROMPT     tablespace is stuck: its own limit, or the first day it has to extend after the
PROMPT     disk is full (BY = DISK). WORST = the same with every tablespace at its worst-case
PROMPT     rate. SHARED_GIB = its size on that day. OWN_GIB = its own limit, LV = Y when that
PROMPT     is the live ceiling. IN_FILES = days the free space inside its files lasts.

COLUMN db_pdb           FORMAT A20           HEADING 'DB/PDB'
COLUMN tablespace_name  FORMAT A18           HEADING 'TABLESPACE'
COLUMN grow_mb          FORMAT 999990.000    HEADING 'MIB/DAY'
COLUMN ext_days         FORMAT 9999990.0     HEADING 'IN_FILES'
COLUMN own_gb           FORMAT 99990.00      HEADING 'OWN_GIB'
COLUMN limit_live       FORMAT A2            HEADING 'LV'
COLUMN dtf_own          FORMAT 99999990      HEADING 'OWN_DAYS'
COLUMN dtf_shared       FORMAT 99999990      HEADING 'SHARED'
COLUMN dtf_shared_worst FORMAT 99999990      HEADING 'WORST'
COLUMN stopped_by       FORMAT A5            HEADING 'BY'
COLUMN limit_shared_gb  FORMAT 99990.00      HEADING 'SHARED_GIB'

SELECT db_pdb,
       tablespace_name,
       grow_mb,
       ext_days,
       limit_own_gb AS own_gb,
       limit_live,
       dtf_own,
       dtf_shared,
       dtf_shared_worst,
       stopped_by,
       limit_shared_gb,
       quality
FROM  (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.dbid ORDER BY t.rank_shared) AS s_rank
       FROM   capr_tbspc_shared&cap_s t
       WHERE  (&cap_sdbid IS NULL OR t.dbid = &cap_sdbid)
         AND  (&cap_scon  IS NULL OR t.con_dbid = &cap_scon)
         AND  t.grow_mb IS NOT NULL)
WHERE  s_rank <= &top_n
ORDER  BY dbid, s_rank;
