--
-- 09_tbspc_family.sql -- tablespace families (ddl/32).
-- FORMAT ONLY (M8.2 convention): every number, label and state comes from
-- CAPR_TBSPC_FAMILY (9) and CAPR_TBSPC_FAMILY_MEMBERS (9b). report.sql
-- includes this file only when the scope holds a family (09_family_skip.sql
-- otherwise, which prints nothing).
--
PROMPT
PROMPT == 9. TABLESPACE FAMILIES (one tablespace per period, judged as a group) ==
PROMPT    A family is the tablespaces of one container whose names differ only in a period token
PROMPT    (SALES_202601, SALES_202602 .. = SALES_#), or the members CAP_TBSPC_FAMILY names.
PROMPT    MEMBERS = D done / F filling / E empty. NEXT GIB: the size the next member needs, from the
PROMPT    final sizes of the newest DONE members (CAUTIOUS: their largest). T = Y: the finals rise or
PROMPT    fall from member to member and both sizes follow that trend.
PROMPT    FILLING: the member that grows now. EXPECTED: its size at the end of its period (PERIOD END),
PROMPT    on its own rate and never slower than the DONE members filled on average. AT MOST: the same
PROMPT    with the CAUTIOUS size. SEV = WARN when AT MOST is above the member's CEILING (alert
PROMPT    TBSPC_FAMILY). GIB/PERIOD: growth of the whole family per period, a straight line.

COLUMN db_pdb          FORMAT A20      HEADING 'DB/PDB'
COLUMN family_name     FORMAT A22      HEADING 'FAMILY'
COLUMN period          FORMAT A7       HEADING 'PERIOD'
COLUMN members         FORMAT A12      HEADING 'MEMBERS'
COLUMN used_gb         FORMAT 99990.00 HEADING 'USED GIB'
COLUMN growth_gb       FORMAT 9990.00  HEADING 'GIB/PERIOD'
COLUMN next_gb         FORMAT 99990.00 HEADING 'NEXT GIB'
COLUMN next_hi_gb      FORMAT 99990.00 HEADING 'CAUTIOUS'
COLUMN trend_sig       FORMAT A1       HEADING 'T'
COLUMN filling_member  FORMAT A22      HEADING 'FILLING'
COLUMN exp_gb          FORMAT 99990.00 HEADING 'EXPECTED'
COLUMN exp_hi_gb       FORMAT 99990.00 HEADING 'AT MOST'
COLUMN ceiling_gb      FORMAT 99990.00 HEADING 'CEILING'
COLUMN period_end      FORMAT A10      HEADING 'PERIOD END'
COLUMN sev             FORMAT A4       HEADING 'SEV'

SELECT db_pdb,
       family_name,
       period,
       n_done || ' D / ' || n_filling || ' F / ' || n_empty || ' E' AS members,
       used_gb,
       growth_per_period_gb                    AS growth_gb,
       next_member_gb                          AS next_gb,
       next_member_hi_gb                       AS next_hi_gb,
       trend_sig,
       filling_member,
       expected_final_gb                       AS exp_gb,
       expected_final_hi_gb                    AS exp_hi_gb,
       filling_limit_gb                        AS ceiling_gb,
       TO_CHAR(period_end_day, 'YYYY-MM-DD')   AS period_end,
       sev
FROM   capr_tbspc_family&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, rank_family;

PROMPT
PROMPT == 9b. FAMILY MEMBERS (oldest period first) ==
PROMPT     STATE: FILLING = the newest member that grows. DONE = an older one, or growth stopped.
PROMPT     EMPTY = created ahead, no growth yet. FINAL GIB: a DONE member's largest size in the fit
PROMPT     window. FILL DAYS / FROM / TO: its growth days, where the window shows the beginning.
PROMPT     GIB/DAY: the FILLING member's rate.

COLUMN tablespace_name FORMAT A24      HEADING 'TABLESPACE'
COLUMN state           FORMAT A7       HEADING 'STATE'
COLUMN limit_gb        FORMAT 99990.00 HEADING 'CEILING'
COLUMN pct_used        FORMAT 990.0    HEADING 'PCT'
COLUMN final_gb        FORMAT 99990.00 HEADING 'FINAL GIB'
COLUMN fill_from       FORMAT A10      HEADING 'FROM'
COLUMN fill_to         FORMAT A10      HEADING 'TO'
COLUMN fill_days       FORMAT 9990     HEADING 'FILL DAYS'
COLUMN rate_gb         FORMAT 990.000  HEADING 'GIB/DAY'
COLUMN source          FORMAT A8       HEADING 'SOURCE'

BREAK ON db_pdb ON family_name SKIP 1

SELECT db_pdb,
       family_name,
       tablespace_name,
       state,
       used_gb,
       limit_gb,
       pct_used,
       final_gb,
       TO_CHAR(fill_from, 'YYYY-MM-DD')        AS fill_from,
       TO_CHAR(fill_to, 'YYYY-MM-DD')          AS fill_to,
       fill_days,
       fill_rate_gb_day                        AS rate_gb,
       source
FROM   capr_tbspc_family_members&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, con_dbid, family_name, member_seq;

CLEAR BREAKS
