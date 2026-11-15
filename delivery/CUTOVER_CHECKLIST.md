# Cutover checklist — 2026Q3 fee billing

Fee billing sits in the revenue path, so it gets a parallel run rather than a
straight cutover. The gate at each stage is a result, not a date.

## Before the parallel run

- [ ] All seven open decisions in `analysis/GAP_LOG.md` signed off by Billing
      Operations, with Compliance on GAP-01
- [ ] Restatement position agreed in writing. If marginal tiering is correct,
      prior periods are wrong and that is a disclosure question
- [ ] The downstream Operations household-tiering spreadsheet obtained and
      reconciled against the target's household calculation
- [ ] Target ported from the SQLite proof to the agreed platform
      (`target/PORTING.md`) and the full test suite re-run there
- [ ] Custodian extract control totals agreed, so an incomplete file is
      detectable on arrival rather than after invoicing
- [ ] Named owner and on-call contact for the new pipeline
- [ ] Rollback defined: the legacy workflow stays runnable and its inputs
      retained for the whole parallel period

## Parallel run — one full quarter

- [ ] Both runs execute on the same extracts, same valuation date
- [ ] `v_parity` reconciliation produced and reviewed each run
- [ ] **Gate: zero unexplained variances.** Every difference traced to a
      signed-off gap. Any row in `v_defects` stops the cutover
- [ ] Exception log reviewed by Operations each run, not just produced.
      29 exceptions this quarter, 10 of them blocking
- [ ] All BLOCKING exceptions cleared or formally accepted before invoices are
      released
- [ ] Billing Operations confirms the target output loads into the invoicing
      system unchanged
- [ ] UAT sign-off from Billing Operations on the output file itself, not on a
      sample

## Cutover

- [ ] Legacy workflow disabled, not deleted, and the disabling recorded
- [ ] Scheduled run configured with the period as a parameter. The legacy date
      was hand-edited each quarter and that is the single most likely way a
      run fails silently
- [ ] Alert on: run failure, zero rows output, any BLOCKING exception, total
      fees moving more than an agreed tolerance against the prior quarter
- [ ] Exception report delivered to Operations automatically each run
- [ ] Runbook published: how to run it, what each exception code means, who
      decides what
- [ ] First live run reconciled against the final parallel run

## After the first live quarter

- [ ] Review which exception codes actually fired and retire the noise
- [ ] Confirm the tolerance alert threshold against two quarters of real
      movement
- [ ] Hand the pattern library to whoever takes workflow 2

## Standing rule

No invoice is released while a BLOCKING exception is open on the account it
covers. The legacy workflow had no way to express that, which is how an account
holding nothing was invoiced $250 and an account holding $2.45M was invoiced
nothing.
