--
-- 09_track.sql -- the forecast track record: how the earlier forecasts of
-- each series fared, and the band factor that record implies.
-- FORMAT ONLY: every number, grade and sentence comes from CAPR_FIT_TRACK
-- (ddl/60), which reads the stored refresh runs (CAP_FIT_HIST, CAP_RUN) and
-- nothing else. It is a table-backed view, so LIVE and SNAPSHOT read it the
-- same way and both describe the newest OK refresh run. Without a month of
-- nightly runs there is nothing to check and 9a is empty.
--
-- Scope: rank_track counts per database; a container scope re-numbers it,
-- as section 1 does.
--
PROMPT
PROMPT == 9a. FORECAST TRACK RECORD (checked forecasts, least reliable first; top &top_n) ==
PROMPT     Each stored forecast is checked against the value stored accuracy_horizon_days
PROMPT     later (AGE_D). N = forecasts checked. ERR% = median error as a percent of the
PROMPT     actual value, sign dropped. BIAS% = the same with its sign (+ = it grew faster
PROMPT     than forecast). IN_BAND = actual values inside the 95% band issued then.
PROMPT     FACTOR = what that band's half-width had to be multiplied by to hold
PROMPT     calib_quantile_pct percent of the errors (never below 1, empty below
PROMPT     calib_min_forecasts). RELIABILITY: BIASED (bias beyond calib_bias_pct), WIDE
PROMPT     (FACTOR above calib_wide_factor), GOOD, UNKNOWN (too few checked forecasts).
PROMPT     P30 = today's +30 projection, CAL_LO / CAL_HI = its band times FACTOR.

COLUMN db          FORMAT A20          HEADING 'DB/PDB'
COLUMN kind        FORMAT A6           HEADING 'KIND'
COLUMN series      FORMAT A22          HEADING 'SERIES'
COLUMN horizon     FORMAT 990          HEADING 'AGE_D'
COLUMN n_forecasts FORMAT 9990         HEADING 'N'
COLUMN abs_err_pct FORMAT 99990.00     HEADING 'ERR%'
COLUMN bias_pct    FORMAT S99990.00    HEADING 'BIAS%'
COLUMN in_band     FORMAT A9           HEADING 'IN_BAND'
COLUMN band_factor FORMAT 990.00       HEADING 'FACTOR'
COLUMN reliability FORMAT A11          HEADING 'RELIABILITY'
COLUMN p30         FORMAT 9999990.00   HEADING 'P30'
COLUMN cal_lo      FORMAT 9999990.00   HEADING 'CAL_LO'
COLUMN cal_hi      FORMAT 9999990.00   HEADING 'CAL_HI'
COLUMN disp_unit   FORMAT A8           HEADING 'UNIT'

SELECT db,
       kind,
       series,
       horizon_days AS horizon,
       n_forecasts,
       abs_err_pct,
       bias_pct,
       CASE WHEN n_banded > 0 THEN band_hits || '/' || n_banded END AS in_band,
       band_factor,
       reliability,
       proj_30        / CASE unit WHEN 'bytes' THEN 1073741824 ELSE 1 END AS p30,
       proj_30_lo_cal / CASE unit WHEN 'bytes' THEN 1073741824 ELSE 1 END AS cal_lo,
       proj_30_hi_cal / CASE unit WHEN 'bytes' THEN 1073741824 ELSE 1 END AS cal_hi,
       CASE unit WHEN 'bytes' THEN 'GiB' ELSE unit END                    AS disp_unit
FROM  (SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.dbid ORDER BY t.rank_track) AS s_rank
       FROM   capr_fit_track t
       WHERE  t.n_forecasts > 0
         AND  (&cap_sdbid IS NULL OR t.dbid = &cap_sdbid)
         AND  (&cap_scon  IS NULL OR t.con_dbid = &cap_scon))
WHERE  s_rank <= &top_n
ORDER  BY dbid, s_rank;

PROMPT
PROMPT == 9b. TRACK RECORD BY DATABASE (every series of the newest refresh run) ==
PROMPT     NOTHING_YET = series with no forecast old enough to check, counted in UNKNOWN.

COLUMN db_name     FORMAT A20          HEADING 'DATABASE'
COLUMN as_of       FORMAT A10          HEADING 'RUN_AS_OF'
COLUMN n_series    FORMAT 99990        HEADING 'SERIES'
COLUMN n_biased    FORMAT 99990        HEADING 'BIASED'
COLUMN n_wide      FORMAT 99990        HEADING 'WIDE'
COLUMN n_good      FORMAT 99990        HEADING 'GOOD'
COLUMN n_unknown   FORMAT 99990        HEADING 'UNKNOWN'
COLUMN n_nothing   FORMAT 99990        HEADING 'NOTHING_YET'

SELECT MIN(REGEXP_SUBSTR(db, '^[^/]+'))                       AS db_name,
       TO_CHAR(MAX(as_of_day), 'YYYY-MM-DD')                  AS as_of,
       COUNT(*)                                               AS n_series,
       COUNT(CASE WHEN reliability = 'BIASED'  THEN 1 END)    AS n_biased,
       COUNT(CASE WHEN reliability = 'WIDE'    THEN 1 END)    AS n_wide,
       COUNT(CASE WHEN reliability = 'GOOD'    THEN 1 END)    AS n_good,
       COUNT(CASE WHEN reliability = 'UNKNOWN' THEN 1 END)    AS n_unknown,
       COUNT(CASE WHEN n_forecasts = 0         THEN 1 END)    AS n_nothing
FROM   capr_fit_track
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
GROUP  BY dbid
ORDER  BY dbid;
