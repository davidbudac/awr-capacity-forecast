--
-- 08_memory.sql -- instance memory sizing verdicts (M26).
-- FORMAT ONLY (M8.2 convention): every number, label and sentence comes
-- from CAPR_MEM_VERDICT (8), CAPR_MEM_EVIDENCE (8b) and CAPR_MEM_COMPONENTS
-- (8c). The knobs quoted below are resolved by report.sql before the spool.
--
-- The rows are instance level, filed under the root (con_dbid = dbid), so a
-- report scoped to a PDB prints the headings and no rows.
--
PROMPT
PROMPT == 8. INSTANCE MEMORY (SGA / PGA sizing verdicts) ==
PROMPT    One row per instance and memory area, judged on the last &mem_win days of AWR up to the
PROMPT    database's newest snapshot (WINDOW; DAYS = days sampled in it). An uptime shorter than
PROMPT    &mem_upt hours adds no advisor evidence (a cold cache distorts the estimates); its symptoms count.
PROMPT    UNDERSIZED: the advisor estimates a material gain at a larger size AND a pressure symptom
PROMPT    was observed. Either one alone grades OK, and the reason names it. The PGA limit has no
PROMPT    advisor: it is UNDERSIZED when a window peak reached &mem_plim% of pga_aggregate_limit.
PROMPT    OVERSIZED: the advisor estimates almost no cost at a smaller size, no pressure was observed,
PROMPT    and at least &mem_shrd days were sampled. OK: no change advised. INSUFFICIENT_EVIDENCE: the
PROMPT    reason says what is missing (advisor history, AMM, memory history, &mem_mind sampled days).
PROMPT    SGA balance: THRASHING = ASMM keeps moving memory between the buffer cache and the shared
PROMPT    pool, DRIFTING = it squeezed one pool in favour of the other. MODE: ASMM, AMM or MANUAL.
PROMPT    SUGGESTED: a size the advisor evaluated (PGA limit: the size that puts the peak at &mem_plim%),
PROMPT    at most &mem_step times and at least 1/&mem_step of the current size. It is one step: re-evaluate
PROMPT    after the change. Empty: no change advised. Under ASMM a buffer cache or shared pool
PROMPT    suggestion is a floor (the least ASMM may give the pool), not a fixed size, and so is the
PROMPT    floor of a THRASHING balance.
PROMPT    HOST = Y: the suggestion plus the rest of the instance passes &mem_host% of the host's physical
PROMPT    memory (empty: unknown, or nothing suggested). Other instances on the same host are not seen.
PROMPT    SGA = Y: the buffer cache or shared pool floor is more than the two pools hold together now,
PROMPT    so it cannot fit in sga_target: raise sga_target first.
PROMPT    Advice only: the suite never changes a parameter, and memory verdicts raise no alert.

COLUMN db_pdb          FORMAT A20      HEADING 'DB/PDB'
COLUMN instance_number FORMAT 9990     HEADING 'INST'
COLUMN area_label      FORMAT A12      HEADING 'AREA'
COLUMN mem_mode        FORMAT A6       HEADING 'MODE'
COLUMN grade           FORMAT A21      HEADING 'GRADE'
COLUMN current_size    FORMAT A9       HEADING 'CURRENT'
COLUMN suggested_size  FORMAT A9       HEADING 'SUGGESTED'
COLUMN change_pct      FORMAT S9990.0  HEADING 'CHANGE%'
COLUMN suggested_param FORMAT A20      HEADING 'PARAMETER'
COLUMN exceeds_host_ram FORMAT A4      HEADING 'HOST'
COLUMN exceeds_sga     FORMAT A3       HEADING 'SGA'
COLUMN n_days          FORMAT 9990     HEADING 'DAYS'
COLUMN mem_window      FORMAT A22      HEADING 'WINDOW'

SELECT db_pdb,
       instance_number,
       area_label,
       mem_mode,
       grade,
       current_size,
       suggested_size,
       change_pct,
       suggested_param,
       exceeds_host_ram,
       exceeds_sga,
       n_days,
       TO_CHAR(window_start, 'YYYY-MM-DD') || '..' || TO_CHAR(window_end, 'YYYY-MM-DD') AS mem_window
FROM   capr_mem_verdict&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, rank_mem;

PROMPT
PROMPT    What each verdict says, and why.

COLUMN headline        FORMAT A85      HEADING 'VERDICT' WORD_WRAPPED
COLUMN reason_text     FORMAT A70      HEADING 'WHY'     WORD_WRAPPED

SELECT db_pdb,
       instance_number,
       area_label,
       headline,
       reason_text
FROM   capr_mem_verdict&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, rank_mem;

PROMPT
PROMPT == 8b. MEMORY EVIDENCE (every signal behind the verdicts) ==
PROMPT    KIND: USAGE (PGA allocation against the limit), ADVISOR (an advisor estimate at another
PROMPT    size), SYMPTOM (pressure observed in the window), CONTEXT (shown, never decides).
PROMPT    DIRECTION: PRESSURE (argues for more memory), SLACK (for less), NEUTRAL (neither).
PROMPT    A verdict is derived from these lines only. Each sentence carries its value and threshold.

COLUMN kind            FORMAT A7       HEADING 'KIND'
COLUMN direction       FORMAT A9       HEADING 'DIRECTION'
COLUMN evidence_text   FORMAT A140     HEADING 'EVIDENCE' WORD_WRAPPED

SELECT db_pdb,
       instance_number,
       area_label,
       kind,
       direction,
       evidence_text
FROM   capr_mem_evidence&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, rank_ev;

PROMPT
PROMPT == 8c. SGA COMPONENTS (where the SGA goes, over the window) ==
PROMPT    Sizes in MiB: CURRENT at the latest snapshot, MIN / MAX over the window. PCT = share of the
PROMPT    listed components. OPS = resize operations; GROWS / SHRINKS = snapshot intervals in which the
PROMPT    component rose / fell; FORCED = rises whose last operation was IMMEDIATE (to avoid an
PROMPT    allocation failure). The minor pools and the In-Memory area are listed with no grade.

COLUMN component       FORMAT A28      HEADING 'COMPONENT'
COLUMN cur_mb          FORMAT 9999990  HEADING 'CURRENT'
COLUMN min_mb          FORMAT 9999990  HEADING 'MIN'
COLUMN max_mb          FORMAT 9999990  HEADING 'MAX'
COLUMN pct_of_total    FORMAT 990.0    HEADING 'PCT'
COLUMN n_ops           FORMAT 999990   HEADING 'OPS'
COLUMN n_grows         FORMAT 99990    HEADING 'GROWS'
COLUMN n_shrinks       FORMAT 9999990  HEADING 'SHRINKS'
COLUMN n_forced_grows  FORMAT 999990   HEADING 'FORCED'
COLUMN last_resize     FORMAT A16      HEADING 'LAST_RESIZE'

SELECT db_pdb,
       instance_number,
       component,
       ROUND(current_bytes / 1048576)                 AS cur_mb,
       ROUND(min_bytes / 1048576)                     AS min_mb,
       ROUND(max_bytes / 1048576)                     AS max_mb,
       pct_of_total,
       n_ops,
       n_grows,
       n_shrinks,
       n_forced_grows,
       TO_CHAR(last_resize_at, 'YYYY-MM-DD HH24:MI')  AS last_resize
FROM   capr_mem_components&cap_s
WHERE  (&cap_sdbid IS NULL OR dbid = &cap_sdbid)
  AND  (&cap_scon  IS NULL OR con_dbid = &cap_scon)
ORDER  BY dbid, rank_comp;
