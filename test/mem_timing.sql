-- =====================================================================
-- test/mem_timing.sql -- elapsed time of the memory verdict views.
-- =====================================================================
-- Read-only. Run in the suite's schema (SYSDBA + CURRENT_SCHEMA, or the
-- owner): test/dbmint_harness.sh <SCHEMA> --sql test/mem_timing.sql
-- Each view is read once, in a fixed order, COUNT(*) only. The first read
-- of a view pays its hard parse, so compare two runs of the whole script,
-- each in a new session, not one line with another.
SET APPINFO OFF
SET APPINFO "AWRCAP/test/mem_timing.sql"
SET FEEDBACK OFF
SET TIMING ON
PROMPT ==== mem_timing: capm_delta ====
SELECT COUNT(*) AS capm_delta_rows FROM capm_delta;
PROMPT ==== mem_timing: capm_comp ====
SELECT COUNT(*) AS capm_comp_rows FROM capm_comp;
PROMPT ==== mem_timing: capm_advice ====
SELECT COUNT(*) AS capm_advice_rows FROM capm_advice;
PROMPT ==== mem_timing: capm_area ====
SELECT COUNT(*) AS capm_area_rows FROM capm_area;
PROMPT ==== mem_timing: capm_verdict ====
SELECT COUNT(*) AS capm_verdict_rows FROM capm_verdict;
PROMPT ==== mem_timing: capr_mem_verdict ====
SELECT COUNT(*) AS capr_mem_verdict_rows FROM capr_mem_verdict;
PROMPT ==== mem_timing: capr_mem_evidence ====
SELECT COUNT(*) AS capr_mem_evidence_rows FROM capr_mem_evidence;
SET TIMING OFF
SET FEEDBACK ON
