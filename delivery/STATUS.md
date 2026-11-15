# Fee Billing Migration — status

**As of 15 Nov 2026 · Period in scope: 2026Q3 · Workflow 1 of ~30**

One page, four questions. If you only read one thing, read "Decisions needed from you."

---

## Where we are

The target build runs end to end and reconciles against the legacy invoice run.
All 14 arithmetic and control tests pass. Every one of the 118 accounts where
the two runs disagree is attributed to a specific decision; nothing is
unexplained.

| | Legacy | Target |
|---|---|---|
| Accounts invoiced | 116 | 115 |
| Fees invoiced | $622,914.34 | $717,153.72 |
| Exceptions reported | 0 | 33 |
| Unexplained variances | n/a | 0 |

The target invoices **$94,239.38 more**, up 15.1%. That is almost entirely the
tier correction: the legacy workflow applied one rate to a client's whole
balance instead of the marginal bands the published schedule describes. The firm
has been **underbilling**, not overbilling, on 38 accounts.

## What's left

| Work | State |
|---|---|
| As-is analysis and gap log | Drafted, needs business sign-off on 7 open decisions |
| Target build (staging → dimensions → AUM → fees) | Complete |
| Exception framework | Complete, 25 reason codes |
| Parity harness and defect log | Complete, 0 defects outstanding |
| Power BI exception and recon report | Not started, 1 day |
| Port from SQLite proof to Azure SQL / Fabric | Not started, 2 days — see `target/PORTING.md` |
| UAT with Billing Operations | Blocked on the decisions below |
| Cutover and parallel run | Planned, see `delivery/CUTOVER_CHECKLIST.md` |

## Top 3 risks

1. **The tier correction is retroactive.** If marginal tiering is the correct
   reading of the published schedule, every invoice above $1M has been wrong
   for as long as the workflow has run. The restatement question is legal and
   client-facing, not technical, and it needs Compliance before go-live rather
   than after. **Owner: Head of Billing Ops + Compliance.**
2. **Household tiering has never run in this system.** The 2019 canvas note
   says Operations applies it downstream in a spreadsheet. That spreadsheet is
   unreviewed, sits in the revenue path, and we have not seen it. Until we
   reconcile against it we cannot say whether 16 households are currently
   billed correctly. **Owner: BA, needs the file from Ops.**
3. **$29.86M of assets cannot be priced at all.** Four households contracted
   for household tiering hold accounts on mixed fee schedules, and two accounts
   carry schedule codes that are not in the published schedule. These are
   contract questions with no answer in the data. **Owner: Relationship
   Management.**

## Decisions needed from you

Seven open items, ranked by what they cost if we guess. Full detail and options
in `analysis/GAP_LOG.md`.

| # | Decision | Why it cannot wait |
|---|---|---|
| 1 | Marginal or cliff tiering | Sets the restatement question. $91,877 on this quarter alone |
| 2 | Household aggregation: confirm the 16, and resolve the 4 mixed-schedule households | $27.4M unpriceable until resolved |
| 3 | Mid-period opens: prorate or bill the full period | One client held assets for 2 days and was invoiced $27,295 |
| 4 | Closed accounts: raise a final prorated fee | $28,247 on one account this quarter, never invoiced |
| 5 | Margin debits: net against billable AUM, or bill gross of borrowing | 5 accounts, $357,283 |
| 6 | Is cash fee-billable | 1 account, $1,190,520 |
| 7 | Unknown or missing schedule codes: reject or default | 2 accounts held out of this run |

Items 1 to 4 are worth more than $140,000 in this quarter's run. Items 5 to 7
are smaller but each one blocks a specific client's invoice.

---

### What I am not asking for

Priorities, resourcing, or a view on the roadmap. Those are settled. This page
exists so the seven decisions above get made, and the rest is reporting.
