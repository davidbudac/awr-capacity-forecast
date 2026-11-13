--
-- ddl/32_tbspc_family.sql -- tablespace families: one tablespace per period.
-- =====================================================================
-- A database that keeps one tablespace per month (quarter, year) fills each
-- during its period and then leaves it alone. A straight line per tablespace
-- says little there: the member that fills now is judged against a full date
-- past the end of its period, and nothing says how big the next one must be.
-- These views group such tablespaces into a FAMILY and answer both.
--
--   CAPD_TBSPC_FAMILY        membership: one row per member tablespace
--   CAPD_TBSPC_FAMILY_DAILY  the family's total used size per day
--   CAPF_TBSPC_FAMILY_MEMBER per member: state, final size, fill window
--   CAPF_TBSPC_FAMILY        per family: growth, next member size, the
--                            filling member's expected final size
--
-- Knobs: family_auto 1, family_min_members 3, family_recent_members 6, and
-- the fit's train_days, growth_floor, stale_days. Operator rows:
-- CAP_TBSPC_FAMILY (ddl/05). The fit file ddl/30 is read, not changed.
--
-- ---------------------------------------------------------------------
-- Membership (CAPD_TBSPC_FAMILY)
-- ---------------------------------------------------------------------
-- Only a CURRENT tablespace is a member: its last day is within stale_days
-- of the newest tablespace day of its dbid (the CAPF is_current rule). A
-- dropped member leaves the family, its history is not kept.
--
-- Automatic (family_auto = 1). The first period token in the name, read as
-- upper case, by the rules of `pat` in this order:
--
--     1  YYYYMM  YYYY_MM                      MONTH
--     2  YYYYQn  YYYY_Qn                      QUARTER
--     3  MONYY   MONYYYY  MON_YY  MON_YYYY    MONTH   (JAN .. DEC, YY = 20YY)
--     4  YYYYMON YYYY_MON                     MONTH
--     5  YYYY                                 YEAR
--
-- YYYY is 1900 .. 2099. A numeric token must not touch another digit and a
-- month name must not touch another letter, so DATA_20260115 (a day) and
-- CODEC10 carry no token. YYMM and MMYYYY are not read: four or six digits
-- that do not start with 19 or 20 are ambiguous. The family name is the
-- tablespace name with the token replaced by '#': SALES_202601 and
-- SALES_202602 are members of SALES_#. Tablespaces of one container with the
-- same family name form a family when at least family_min_members of them
-- exist. Members need not share the period kind: a family that changed from
-- yearly to monthly tablespaces stays one family.
--
-- Operator (CAP_TBSPC_FAMILY). A row whose name_regex matches the name
-- decides alone, automatic rule or not: exclude_flag = Y takes the
-- tablespace out of every family, N puts it into family_name. The most
-- specific row wins (dbid, then con_dbid, then the name_regex that sorts
-- first). A family with at least one operator member needs no minimum. The
-- period token is still read from the name for the order.
--
-- ---------------------------------------------------------------------
-- Member order and state (CAPF_TBSPC_FAMILY_MEMBER)
-- ---------------------------------------------------------------------
-- member_seq orders a family: by period start (from the token), a name
-- without a token first, then by the first growth day (no growth first),
-- then by name.
--
-- Growth is the fit's notion (ddl/30, "STOP / START"), over the member's last
-- train_days days: a GROWTH DAY is a new high of used_bytes above every
-- earlier day of that window by more than growth_floor x the window's rise.
-- Purges are not treated here: a member that is purged in the window keeps
-- its earlier highs.
--
--   FILLING  the newest member (highest member_seq) with a growth day in
--            the window, unless the fit says its growth stopped
--            (CAPF_TBSPC_FORECAST.restart_reason = STOP)
--   DONE     every member before that one, the newest grown member once its
--            growth stopped, and every member of a family without a growth
--            day in the window
--   EMPTY    a member after the newest grown one: created ahead, no growth
--
-- So at most one member is FILLING, and a member is DONE as soon as its
-- successor grows, before quiet_days have passed. A name without a token
-- that never grew sorts first and reads DONE: an operator family whose names
-- carry no period cannot show EMPTY members.
--
--   final_bytes   DONE: the largest used size in the window (the size the
--                 member needed, also when it was compressed afterwards)
--   fill_from     the first growth day, when the window shows the day before
--                 it and one more (the member did not grow into the window)
--   fill_to       DONE: the last growth day
--   fill_days     DONE with fill_from: fill_to - fill_from + 1
--   fill_rate_bpd FILLING: with fill_from, the average growth per day since
--                 the day before it, (cur_used - used that day) / days.
--                 Without it (growth began before the window) the fit's
--                 slope_bpd, at least 0.
--
-- ---------------------------------------------------------------------
-- The family (CAPF_TBSPC_FAMILY)
-- ---------------------------------------------------------------------
-- Total: used_bytes = the members' current sizes. slope_bpd = REGR_SLOPE of
-- the daily total (CAPD_TBSPC_FAMILY_DAILY) over the family's last
-- train_days days, growth_per_period_bytes = slope_bpd x period_days.
--
-- Next member. The final sizes of the newest family_recent_members DONE
-- members, numbered i = 1 .. k oldest first:
--
--     b      = REGR_SLOPE(final, i)                     growth per member
--     ci     = (1.96 + 2.4 / (k - 2)) x resid_se / SQRT(SXX)   (the M9.1 t)
--     step   = b when k >= 3 and |b| > ci, else 0       (trend_sig Y / N)
--     adj_i  = final_i + step x (k + 1 - i)             carried to member k + 1
--     next_member_bytes    = MEDIAN(adj_i)
--     next_member_hi_bytes = MAX(final_i + GREATEST(step, 0) x (k + 1 - i))
--
-- With no significant trend that is the median and the maximum of the
-- finals. A falling trend lowers the estimate and never the cautious value.
--
-- Filling member. Its period is period_days long: the calendar length of
-- its token's period, without a token the median fill_days of the DONE
-- members. It ends on
--
--     period_end_day = fill_from + period_days - 1      with fill_from
--                    = the calendar end of its period   without (it grew
--                                                       into the window)
--     days_left      = GREATEST(period_end_day - last_day, 0)
--
-- Counting from the first growth day keeps a family right whose members fill
-- a month late. The expected final size extends the member's own line, and
-- for the days left it never grows slower than the DONE members did on
-- average over a period:
--
--     expected_final_bytes    = cur_used + GREATEST(fill_rate_bpd,
--                                   next_member_bytes / period_days) x days_left
--     expected_final_hi_bytes = the same with next_member_hi_bytes
--
-- fits = N when expected_final_hi_bytes is above the member's limit_bytes
-- (the TBSPC_FAMILY alert, ddl/55), Y when not, NULL without a filling
-- member or a period end. next_over_limit = Y when next_member_bytes is
-- above the largest ceiling any member has now.
-- (No comment line here may end in a semicolon, see ddl/30.)
--
SET DEFINE OFF

-- --------------------------------------------------------------------
-- CAPD_TBSPC_FAMILY -- one row per member tablespace.
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capd_tbspc_family AS
WITH ts AS (
        SELECT dbid, con_dbid, tablespace_name, MAX(day_dt) AS last_day
        FROM   capd_tbspc_daily
        GROUP  BY dbid, con_dbid, tablespace_name
     ),
     cur AS (
        SELECT t.dbid, t.con_dbid, t.tablespace_name, t.last_day
        FROM  (SELECT ts.*, MAX(ts.last_day) OVER (PARTITION BY ts.dbid) AS newest_day
               FROM   ts) t
        CROSS  JOIN cap_cfg cfg
        WHERE  t.last_day >= t.newest_day - cfg.stale_days
     ),
     -- The period tokens (header, "Membership"). rx brackets the token with
     -- its two boundaries, repl keeps them. y_sub / p_sub = the
     -- subexpressions that hold the year and the month or quarter.
     pat AS (
        SELECT 1 AS n, 'MONTH' AS period,
               '(^|[^0-9])((19|20)[0-9][0-9])_?(0[1-9]|1[0-2])([^0-9]|$)' AS rx,
               2 AS y_sub, 4 AS p_sub, '\1#\5' AS repl FROM dual
        UNION ALL
        SELECT 2, 'QUARTER',
               '(^|[^0-9])((19|20)[0-9][0-9])_?Q([1-4])([^0-9]|$)',
               2, 4, '\1#\5' FROM dual
        UNION ALL
        SELECT 3, 'MONTH',
               '(^|[^A-Z])(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)_?((19|20)?[0-9][0-9])([^0-9]|$)',
               3, 2, '\1#\5' FROM dual
        UNION ALL
        SELECT 4, 'MONTH',
               '(^|[^0-9])((19|20)[0-9][0-9])_?(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)([^A-Z]|$)',
               2, 4, '\1#\5' FROM dual
        UNION ALL
        SELECT 5, 'YEAR',
               '(^|[^0-9])((19|20)[0-9][0-9])([^0-9]|$)',
               2, 2, '\1#\4' FROM dual
     ),
     tok AS (
        SELECT c.dbid, c.con_dbid, c.tablespace_name, p.period,
               REGEXP_REPLACE(UPPER(c.tablespace_name), p.rx, p.repl, 1, 1)          AS auto_name,
               REGEXP_SUBSTR(UPPER(c.tablespace_name), p.rx, 1, 1, NULL, p.y_sub)    AS y_txt,
               REGEXP_SUBSTR(UPPER(c.tablespace_name), p.rx, 1, 1, NULL, p.p_sub)    AS p_txt,
               ROW_NUMBER() OVER (PARTITION BY c.dbid, c.con_dbid, c.tablespace_name
                                  ORDER BY p.n)                                      AS rn
        FROM   cur c
        JOIN   pat p ON REGEXP_LIKE(UPPER(c.tablespace_name), p.rx)
     ),
     -- First month of the period. The patterns admit only digits or a month
     -- name in p_txt, and only 19xx / 20xx or two digits in y_txt.
     per AS (
        SELECT t.dbid, t.con_dbid, t.tablespace_name, t.period, t.auto_name,
               DECODE(t.period, 'YEAR', 12, 'QUARTER', 3, 1)                         AS n_months,
               ADD_MONTHS(TO_DATE(CASE WHEN LENGTH(t.y_txt) = 2 THEN '20' END || t.y_txt || '0101',
                                  'YYYYMMDD'),
                          CASE WHEN t.period = 'YEAR'    THEN 0
                               WHEN t.period = 'QUARTER' THEN 3 * TO_NUMBER(t.p_txt) - 3
                               WHEN t.p_txt BETWEEN '01' AND '12' THEN TO_NUMBER(t.p_txt) - 1
                               ELSE (INSTR('JANFEBMARAPRMAYJUNJULAUGSEPOCTNOVDEC', t.p_txt) - 1) / 3
                          END)                                                       AS period_start
        FROM   tok t
        WHERE  t.rn = 1
     ),
     -- At most one CAP_TBSPC_FAMILY row per tablespace: the most specific.
     opr AS (
        SELECT c.dbid, c.con_dbid, c.tablespace_name, o.family_name, o.exclude_flag,
               ROW_NUMBER() OVER (PARTITION BY c.dbid, c.con_dbid, c.tablespace_name
                                  ORDER BY CASE WHEN o.dbid     <> 0 THEN 0 ELSE 1 END,
                                           CASE WHEN o.con_dbid <> 0 THEN 0 ELSE 1 END,
                                           o.name_regex)                             AS rn
        FROM   cur c
        JOIN   cap_tbspc_family o
          ON   (o.dbid     = c.dbid     OR o.dbid     = 0)
         AND   (o.con_dbid = c.con_dbid OR o.con_dbid = 0)
         AND   REGEXP_LIKE(c.tablespace_name, o.name_regex)
     ),
     m AS (
        SELECT c.dbid, c.con_dbid, c.tablespace_name, c.last_day,
               CAST(CASE WHEN o.exclude_flag = 'Y' THEN NULL
                         WHEN o.exclude_flag = 'N' THEN o.family_name
                         WHEN cfg.family_auto = 1  THEN p.auto_name
                    END AS VARCHAR2(128))                                            AS family_name,
               CASE WHEN o.rn IS NOT NULL THEN 'OPERATOR' ELSE 'AUTO' END            AS source,
               p.period, p.period_start,
               ADD_MONTHS(p.period_start, p.n_months) - 1                            AS period_end
        FROM   cur c
        LEFT   JOIN per p ON p.dbid = c.dbid AND p.con_dbid = c.con_dbid
                         AND p.tablespace_name = c.tablespace_name
        LEFT   JOIN opr o ON o.dbid = c.dbid AND o.con_dbid = c.con_dbid
                         AND o.tablespace_name = c.tablespace_name AND o.rn = 1
        CROSS  JOIN cap_cfg cfg
     )
SELECT f.dbid,
       f.con_dbid,
       f.family_name,
       f.tablespace_name,
       f.source,
       f.period,
       f.period_start,
       f.period_end,
       f.period_end - f.period_start + 1 AS period_days,
       f.last_day,
       f.n_members
FROM  (SELECT m.*,
              COUNT(*) OVER (PARTITION BY m.dbid, m.con_dbid, m.family_name)         AS n_members,
              MAX(CASE WHEN m.source = 'OPERATOR' THEN 1 ELSE 0 END)
                       OVER (PARTITION BY m.dbid, m.con_dbid, m.family_name)         AS has_operator
       FROM   m
       WHERE  m.family_name IS NOT NULL) f
CROSS  JOIN cap_cfg cfg
WHERE  f.n_members >= cfg.family_min_members
   OR  f.has_operator = 1;

COMMENT ON TABLE capd_tbspc_family IS 'Tablespace families, membership: one row per current tablespace that belongs to a family (period token in its name, or a CAP_TBSPC_FAMILY row). period_start / period_end = the calendar period of the token, NULL without one.';

-- --------------------------------------------------------------------
-- CAPD_TBSPC_FAMILY_DAILY -- the family's total used size per day: the sum
-- over the members that have a row that day (n_members says how many).
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capd_tbspc_family_daily AS
SELECT d.dbid,
       d.con_dbid,
       f.family_name,
       d.day_dt,
       SUM(d.used_bytes) AS used_bytes,
       COUNT(*)          AS n_members
FROM   capd_tbspc_daily d
JOIN   capd_tbspc_family f
  ON   f.dbid = d.dbid AND f.con_dbid = d.con_dbid AND f.tablespace_name = d.tablespace_name
GROUP  BY d.dbid, d.con_dbid, f.family_name, d.day_dt;

COMMENT ON TABLE capd_tbspc_family_daily IS 'Tablespace families: total used bytes of a family''s current members per day (n_members = members with a row that day).';

-- --------------------------------------------------------------------
-- CAPF_TBSPC_FAMILY_MEMBER -- one row per member: order, state, sizes and
-- the fill window (header, "Member order and state").
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_tbspc_family_member AS
WITH fam AS (
        SELECT * FROM capd_tbspc_family
     ),
     -- The member's last train_days days, with the growth days marked by
     -- ddl/30's rule.
     g AS (
        SELECT d.dbid, d.con_dbid, d.tablespace_name, d.day_dt, d.used_bytes,
               ROW_NUMBER() OVER (PARTITION BY d.dbid, d.con_dbid, d.tablespace_name
                                  ORDER BY d.day_dt)                                 AS rn,
               LAG(d.day_dt)     OVER (PARTITION BY d.dbid, d.con_dbid, d.tablespace_name
                                       ORDER BY d.day_dt)                            AS prev_day,
               LAG(d.used_bytes) OVER (PARTITION BY d.dbid, d.con_dbid, d.tablespace_name
                                       ORDER BY d.day_dt)                            AS prev_used,
               CASE WHEN d.used_bytes - MAX(d.used_bytes) OVER (PARTITION BY d.dbid, d.con_dbid, d.tablespace_name
                                                                ORDER BY d.day_dt
                                                                ROWS BETWEEN UNBOUNDED PRECEDING
                                                                         AND 1 PRECEDING)
                         > cfg.growth_floor
                           * (MAX(d.used_bytes) OVER (PARTITION BY d.dbid, d.con_dbid, d.tablespace_name)
                            - MIN(d.used_bytes) OVER (PARTITION BY d.dbid, d.con_dbid, d.tablespace_name))
                    THEN 1 ELSE 0 END                                                AS is_grow
        FROM   capd_tbspc_daily d
        JOIN   fam f ON f.dbid = d.dbid AND f.con_dbid = d.con_dbid
                    AND f.tablespace_name = d.tablespace_name
        CROSS  JOIN cap_cfg cfg
        WHERE  d.day_dt > f.last_day - cfg.train_days
     ),
     -- base_day / base_used = the day before the first growth day.
     act AS (
        SELECT dbid, con_dbid, tablespace_name,
               MAX(used_bytes)                                 AS peak_bytes,
               SUM(is_grow)                                    AS grow_days,
               MIN(CASE WHEN is_grow = 1 THEN day_dt END)      AS grow_first,
               MAX(CASE WHEN is_grow = 1 THEN day_dt END)      AS grow_last,
               MIN(CASE WHEN is_grow = 1 THEN rn END)          AS rn_first,
               MIN(prev_day)  KEEP (DENSE_RANK FIRST ORDER BY CASE WHEN is_grow = 1 THEN rn END NULLS LAST) AS base_day,
               MIN(prev_used) KEEP (DENSE_RANK FIRST ORDER BY CASE WHEN is_grow = 1 THEN rn END NULLS LAST) AS base_used
        FROM   g
        GROUP  BY dbid, con_dbid, tablespace_name
     ),
     j AS (
        SELECT m.dbid, m.con_dbid, m.family_name, m.tablespace_name, m.source,
               m.period, m.period_start, m.period_end, m.period_days, m.last_day,
               a.peak_bytes, a.grow_days, a.grow_first, a.grow_last, a.base_day, a.base_used,
               CASE WHEN a.rn_first >= 3 THEN 1 ELSE 0 END                           AS begin_shown,
               t.cur_used, t.limit_bytes, t.limit_source, t.pct_used,
               t.slope_bpd, t.quality, t.restart_reason,
               ROW_NUMBER() OVER (PARTITION BY m.dbid, m.con_dbid, m.family_name
                                  ORDER BY m.period_start NULLS FIRST,
                                           a.grow_first   NULLS FIRST,
                                           m.tablespace_name)                        AS member_seq
        FROM   fam m
        JOIN   act a ON a.dbid = m.dbid AND a.con_dbid = m.con_dbid
                    AND a.tablespace_name = m.tablespace_name
        JOIN   capf_tbspc_forecast t
          ON   t.dbid = m.dbid AND t.con_dbid = m.con_dbid
         AND   t.tablespace_name = m.tablespace_name
     ),
     st AS (
        SELECT s.*,
               CASE WHEN s.seq_grown IS NULL       THEN 'DONE'
                    WHEN s.member_seq > s.seq_grown THEN 'EMPTY'
                    WHEN s.member_seq < s.seq_grown THEN 'DONE'
                    WHEN s.restart_reason = 'STOP'  THEN 'DONE'
                    ELSE 'FILLING' END                                               AS state
        FROM  (SELECT j.*,
                      MAX(CASE WHEN j.grow_days > 0 THEN j.member_seq END)
                          OVER (PARTITION BY j.dbid, j.con_dbid, j.family_name)      AS seq_grown
               FROM   j) s
     )
SELECT s.dbid,
       s.con_dbid,
       s.family_name,
       s.tablespace_name,
       s.member_seq,
       s.source,
       s.period,
       s.period_start,
       s.period_end,
       s.period_days,
       s.state,
       s.last_day,
       s.cur_used,
       s.limit_bytes,
       s.limit_source,
       s.pct_used,
       CASE WHEN s.state = 'DONE' THEN s.peak_bytes END                              AS final_bytes,
       s.grow_days,
       CASE WHEN s.begin_shown = 1 THEN s.grow_first END                             AS fill_from,
       CASE WHEN s.state = 'DONE' THEN s.grow_last END                               AS fill_to,
       CASE WHEN s.state = 'DONE' AND s.begin_shown = 1
            THEN s.grow_last - s.grow_first + 1 END                                  AS fill_days,
       CASE WHEN s.state <> 'FILLING' THEN NULL
            WHEN s.begin_shown = 1
            THEN (s.cur_used - s.base_used) / (s.last_day - s.base_day)
            ELSE GREATEST(NVL(s.slope_bpd, 0), 0) END                                AS fill_rate_bpd,
       s.quality,
       s.restart_reason
FROM   st s;

COMMENT ON TABLE capf_tbspc_family_member IS 'Tablespace families: one row per member. member_seq orders the family, state FILLING / DONE / EMPTY, final_bytes (DONE) = its largest used size in the train_days window, fill_from / fill_to / fill_days = its growth in that window, fill_rate_bpd (FILLING).';

-- --------------------------------------------------------------------
-- CAPF_TBSPC_FAMILY -- one row per family (header, "The family").
-- --------------------------------------------------------------------
CREATE OR REPLACE VIEW capf_tbspc_family AS
WITH m AS (
        SELECT * FROM capf_tbspc_family_member
     ),
     -- The newest family_recent_members DONE members, numbered oldest first.
     rc AS (
        SELECT d.dbid, d.con_dbid, d.family_name, d.final_bytes,
               ROW_NUMBER() OVER (PARTITION BY d.dbid, d.con_dbid, d.family_name
                                  ORDER BY d.member_seq)                             AS i,
               COUNT(*)     OVER (PARTITION BY d.dbid, d.con_dbid, d.family_name)    AS k
        FROM  (SELECT m.*,
                      ROW_NUMBER() OVER (PARTITION BY m.dbid, m.con_dbid, m.family_name
                                         ORDER BY m.member_seq DESC)                 AS rk
               FROM   m
               WHERE  m.state = 'DONE') d
        CROSS  JOIN cap_cfg cfg
        WHERE  d.rk <= cfg.family_recent_members
     ),
     -- The trend across them and whether it counts (header, "Next member").
     tr AS (
        SELECT t.dbid, t.con_dbid, t.family_name, t.b,
               CASE WHEN t.k >= 3 AND t.sxx > 0
                     AND ABS(t.b) > (1.96 + 2.4 / (t.k - 2))
                                    * SQRT(GREATEST(0, t.syy - t.sxy * t.sxy / t.sxx) / (t.k - 2))
                                    / SQRT(t.sxx)
                    THEN t.b ELSE 0 END                                              AS step
        FROM  (SELECT dbid, con_dbid, family_name,
                      COUNT(*)                  AS k,
                      REGR_SLOPE(final_bytes, i) AS b,
                      REGR_SXX(final_bytes, i)   AS sxx,
                      REGR_SYY(final_bytes, i)   AS syy,
                      REGR_SXY(final_bytes, i)   AS sxy
               FROM   rc
               GROUP  BY dbid, con_dbid, family_name) t
     ),
     nx AS (
        SELECT r.dbid, r.con_dbid, r.family_name,
               MAX(r.k)                                                              AS recent_n,
               MEDIAN(r.final_bytes + t.step * (r.k + 1 - r.i))                      AS next_member_bytes,
               MAX(r.final_bytes + GREATEST(t.step, 0) * (r.k + 1 - r.i))            AS next_member_hi_bytes,
               MAX(t.b)                                                              AS trend_bpm,
               MAX(t.step)                                                           AS step
        FROM   rc r
        JOIN   tr t ON t.dbid = r.dbid AND t.con_dbid = r.con_dbid
                   AND t.family_name = r.family_name
        GROUP  BY r.dbid, r.con_dbid, r.family_name
     ),
     agg AS (
        SELECT dbid, con_dbid, family_name,
               COUNT(*)                                        AS n_members,
               COUNT(CASE WHEN state = 'DONE'    THEN 1 END)   AS n_done,
               COUNT(CASE WHEN state = 'FILLING' THEN 1 END)   AS n_filling,
               COUNT(CASE WHEN state = 'EMPTY'   THEN 1 END)   AS n_empty,
               MAX(last_day)                                   AS last_day,
               SUM(cur_used)                                   AS used_bytes,
               MAX(limit_bytes)                                AS max_limit_bytes,
               MEDIAN(fill_days)                               AS fill_days_med,
               MAX(period)      KEEP (DENSE_RANK LAST ORDER BY member_seq) AS period,
               MAX(period_days) KEEP (DENSE_RANK LAST ORDER BY member_seq) AS newest_period_days,
               CASE WHEN MAX(CASE WHEN source = 'OPERATOR' THEN 1 ELSE 0 END) = 1
                    THEN 'OPERATOR' ELSE 'AUTO' END            AS source
        FROM   m
        GROUP  BY dbid, con_dbid, family_name
     ),
     fl AS (
        SELECT * FROM m WHERE state = 'FILLING'
     ),
     fit AS (
        SELECT d.dbid, d.con_dbid, d.family_name,
               REGR_SLOPE(d.used_bytes, d.day_dt - DATE '2020-01-01') AS slope,
               REGR_R2(d.used_bytes, d.day_dt - DATE '2020-01-01')    AS r2,
               REGR_COUNT(d.used_bytes, d.day_dt - DATE '2020-01-01') AS n
        FROM   capd_tbspc_family_daily d
        JOIN   agg a ON a.dbid = d.dbid AND a.con_dbid = d.con_dbid
                    AND a.family_name = d.family_name
        CROSS  JOIN cap_cfg cfg
        WHERE  d.day_dt > a.last_day - cfg.train_days
        GROUP  BY d.dbid, d.con_dbid, d.family_name
     ),
     -- period_days / period_end_day of the filling member.
     pe AS (
        SELECT a.dbid, a.con_dbid, a.family_name,
               NVL(f.period_days, a.fill_days_med)                                   AS fill_period_days,
               CASE WHEN f.fill_from IS NOT NULL AND NVL(f.period_days, a.fill_days_med) IS NOT NULL
                    THEN f.fill_from + NVL(f.period_days, a.fill_days_med) - 1
                    ELSE f.period_end END                                            AS period_end_day
        FROM   agg a
        JOIN   fl  f ON f.dbid = a.dbid AND f.con_dbid = a.con_dbid
                    AND f.family_name = a.family_name
     )
SELECT a.dbid,
       a.con_dbid,
       a.family_name,
       a.source,
       a.period,
       a.n_members,
       a.n_done,
       a.n_filling,
       a.n_empty,
       a.last_day,
       a.used_bytes,
       a.max_limit_bytes,
       t.slope                                                         AS slope_bpd,
       t.r2,
       t.n                                                             AS train_n,
       COALESCE(p.fill_period_days, a.newest_period_days, a.fill_days_med) AS period_days,
       t.slope * COALESCE(p.fill_period_days, a.newest_period_days, a.fill_days_med)
                                                                       AS growth_per_period_bytes,
       x.recent_n,
       x.trend_bpm,
       CASE WHEN x.recent_n IS NULL THEN NULL
            WHEN x.step <> 0 THEN 'Y' ELSE 'N' END                     AS trend_sig,
       x.next_member_bytes,
       x.next_member_hi_bytes,
       CASE WHEN x.next_member_bytes > a.max_limit_bytes THEN 'Y' ELSE 'N' END AS next_over_limit,
       f.tablespace_name                                               AS filling_member,
       f.cur_used                                                      AS filling_used_bytes,
       f.limit_bytes                                                   AS filling_limit_bytes,
       f.pct_used                                                      AS filling_pct_used,
       f.fill_from                                                     AS filling_from,
       f.fill_rate_bpd,
       p.period_end_day,
       GREATEST(p.period_end_day - f.last_day, 0)                      AS days_left,
       f.cur_used + GREATEST(f.fill_rate_bpd, NVL(x.next_member_bytes / p.fill_period_days, 0))
                    * GREATEST(p.period_end_day - f.last_day, 0)       AS expected_final_bytes,
       f.cur_used + GREATEST(f.fill_rate_bpd, NVL(x.next_member_hi_bytes / p.fill_period_days, 0))
                    * GREATEST(p.period_end_day - f.last_day, 0)       AS expected_final_hi_bytes,
       CASE WHEN p.period_end_day IS NULL THEN NULL
            WHEN f.cur_used + GREATEST(f.fill_rate_bpd, NVL(x.next_member_hi_bytes / p.fill_period_days, 0))
                              * GREATEST(p.period_end_day - f.last_day, 0) > f.limit_bytes
            THEN 'N' ELSE 'Y' END                                      AS fits
FROM   agg a
LEFT   JOIN fit t ON t.dbid = a.dbid AND t.con_dbid = a.con_dbid AND t.family_name = a.family_name
LEFT   JOIN nx  x ON x.dbid = a.dbid AND x.con_dbid = a.con_dbid AND x.family_name = a.family_name
LEFT   JOIN fl  f ON f.dbid = a.dbid AND f.con_dbid = a.con_dbid AND f.family_name = a.family_name
LEFT   JOIN pe  p ON p.dbid = a.dbid AND p.con_dbid = a.con_dbid AND p.family_name = a.family_name;

COMMENT ON TABLE capf_tbspc_family IS 'Tablespace families: one row per family. Members by state, total used size and its slope, next_member_bytes / _hi_bytes (from the newest DONE members), and the FILLING member''s expected_final_bytes / _hi_bytes against its ceiling (fits Y / N).';
