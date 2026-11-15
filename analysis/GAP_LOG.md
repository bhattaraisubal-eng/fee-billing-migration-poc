# Gap and ambiguity log — 2026Q3 fee billing migration

Every row is something the legacy workflow decided implicitly, or did not decide
at all. The evidence column is measured from the source data, not estimated.

**How to read a row.** A gap is not a bug report. It is a question the business
has to answer, presented so that answering it takes a minute rather than a
meeting. That means the options are laid out, a default is recommended, and the
consequence of getting it wrong is stated in money or in client impact.

> **Note for the author of this file.** Findings, evidence and options below are
> derived from the code and the data. The three columns that matter —
> **Recommendation**, **Rationale**, **Impact if wrong** — are deliberately left
> blank except for the two worked examples. Fill them in your own words before
> publishing. You will be asked to defend these in the interview, and a
> recommendation you cannot argue is worse than no recommendation. Delete this
> note when the log is complete.

---

## A. Pricing logic

### GAP-01 — Tier application: marginal or cliff

**Finding.** Tool 7 applies a single rate to the client's entire balance, chosen
by which band the total falls in. The published schedule in `fee_schedule.csv`
is expressed as bands with a floor and a ceiling, which reads as marginal.

**Evidence.** ACC-1009 holds $1,012,000.01. Cliff pricing charges 75bps on the
whole balance, $1,897.50 for the quarter. Marginal charges 100bps on the first
$1M and 75bps on the $12,000 above it, $2,543.23. Across the book the difference
is **$91,877.23 on 38 accounts in one quarter**. Cliff pricing is also not
monotonic: at $999,999 the quarterly fee is $2,520, and at $1,000,001 it falls
to $1,890. A client who gains a dollar pays $630 less.

**Options.**
- (a) Marginal tiers — each band charges only the assets inside it
- (b) Cliff tiers — preserve the legacy behaviour exactly
- (c) Marginal going forward, no restatement of prior periods

**Recommendation.** *(a) Marginal tiers.*

**Rationale.** *The schedule is published as bands with floors and ceilings,
which is the standard marginal form in advisory agreements. Cliff pricing
produces a fee that falls as a client's assets grow, which cannot be defended
to a client or to an examiner. Option (c) is the pragmatic middle, but it makes
the restatement decision by avoiding it.*

**Confirms.** *Head of Billing Operations, with Compliance sign-off on the
restatement question.*

**Impact if wrong.** *If marginal is correct, every invoice above $1M has been
understated for as long as the workflow has run, and the firm owes its clients
nothing but owes itself a restatement decision. If cliff is somehow the
contracted term, switching would overbill 38 clients by $91,877 a quarter and
the error would surface as client complaints rather than in reconciliation.*

---

### GAP-02 — Rates hard-coded; the published schedule is never read

**Finding.** The four rates and three thresholds are literals in Tool 7.
`fee_schedule.csv` sits in the input folder and no tool reads it. A 2019 comment
on the canvas records this as ticket BIL-412, which was never done.

**Evidence.** 5 institutional and 3 grandfathered accounts are priced on
Standard tiers. Institutional tops out at 40bps; these accounts are billed up to
100. Correcting it reduces fees by **$7,864.20** on 8 accounts.

**Options.** (a) Reference table keyed by schedule code · (b) keep literals and
add the missing schedules as more branches · (c) reference table plus effective
dating, so a schedule change is a dated row rather than an edit

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

### GAP-03 — Household aggregation never happens

**Finding.** `households.csv` carries a `billing_method` of `ACCOUNT` or
`HOUSEHOLD` for every household. No tool in the workflow reads the file. The
canvas note says Operations applies household tiering downstream in a
spreadsheet we have not seen.

**Evidence.** 20 of 60 households are contracted `HOUSEHOLD`. Aggregating their
AUM before applying tiers changes fees on **27 accounts across 16 households by
$19,259.31**. The remaining 4 contracted households hold accounts on mixed fee
schedules and cannot be aggregated without a contract decision; they carry
**$27.41M**.

**Options.** (a) Aggregate in the platform, retire the spreadsheet · (b) keep
the spreadsheet as the system of record and reconcile to it · (c) aggregate only
the 16 unambiguous households now, hold the 4 pending a decision

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

### GAP-04 — Minimum fee applied before the zero check

**Finding.** Tool 8 sets `billable_fee = IIF(gross_fee < 250, 250, gross_fee)`.
Tool 10 then filters `billable_fee > 0`. Because the minimum forces every row to
at least 250, the filter can never exclude anything.

**Evidence.** The exceptions report has **zero rows**, and structurally always
will. It has presumably been empty for every run since 2019, and nobody noticed
because an empty exceptions report looks like a clean run.

**Options.** (a) Apply the minimum after the zero and negative check · (b) apply
the minimum only where billable AUM is positive · (c) keep the order and change
the filter

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

### GAP-05 — Minimum fee charged on zero and negative balances

**Finding.** A consequence of GAP-04. Accounts holding nothing are invoiced the
quarterly minimum.

**Evidence.** ACC-1063 (balance $0.00) and ACC-1049 (balance −$109,764.75) were
each invoiced $250.

**Options.** (a) No fee where billable AUM is not positive · (b) minimum applies
to any open account regardless of balance · (c) minimum applies, waivable by
Operations case by case

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

### GAP-06 — Fixed quarter divisor

**Finding.** Tool 8 divides the annual fee by 4. Q3 2026 is 92 days of 365,
which is 25.21%.

**Evidence.** On a $1M account the quarterly fee is $2,500 under the legacy
divisor against $2,520.55 on actual days. Across the book the effect is
**$373.95**, immaterial in isolation. It matters because it means the formula
does not match whatever convention the advisory agreement states.

**Options.** (a) Actual days over 365 · (b) actual over actual, 366 in a leap
year · (c) keep the fixed quarter, matching the agreement if that is what it says

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

## B. Scope and lifecycle

### GAP-07 — No proration for mid-period opens

**Finding.** There is no proration logic anywhere in the workflow. An account
open for part of the period is billed as though it were open throughout.

**Evidence.** ACC-1024 opened 29 September, held assets for **2 days of 92**,
and was invoiced **$27,295.44**. Prorated it owes $762.64. Two accounts are
affected this quarter, worth **−$28,707.85**.

**Options.** (a) Prorate by days held · (b) bill the full period if open on the
valuation date · (c) bill the full period if open for more than half the period

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

### GAP-16 — Closed accounts raise no final fee

**Finding.** The `status = "ACTIVE"` filter in Tool 5 drops closed accounts
entirely, so an account closed mid-period is never billed for the time it held
assets.

**Evidence.** ACC-1012 closed 24 August after holding **$45.27M for 55 days of
the quarter**. No fee was raised. A prorated final fee is **$28,247.14**, the
largest single variance in the run.

**Options.** (a) Final prorated fee to the closure date · (b) no fee in the
period of closure · (c) final fee only if the account was open past a threshold

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

### GAP-17 — A status value the filter does not know about

**Finding.** The filter tests equality against `ACTIVE`. Any other value drops
the account. Nobody decided that; the filter simply does not know the value
exists.

**Evidence.** ACC-1054 carries `PENDING_CLOSE` and was silently unbilled,
**$1,077.60**. The broader risk is that a new status value in the source system
stops revenue with no error.

**Options.** (a) Explicit allow-list, anything unrecognised raised as an
exception · (b) bill unless explicitly excluded · (c) agree the full status set
with the source system owner and validate on load

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

## C. Record loss

### GAP-10 — Join discards unmatched records with no trace

**Finding.** Tool 6 connects only the J anchor. The L and R anchors are
unconnected, so unmatched records from both sides are discarded. Both Filter
tools likewise leave their False anchors unconnected.

**Evidence.** In this run the Join dropped 2 records from the left and 4 from the
right, and the filters dropped 4 more. Nothing anywhere records that it
happened.

**Options.** (a) Every exclusion writes a row to an exception table with a
reason code · (b) log counts only · (c) fail the run if any record is dropped

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

### GAP-11 — Holdings with no matching account

**Finding.** A position file can reference an account the account extract does
not contain. The inner join drops it and no fee is raised.

**Evidence.** ACC-9901 holds **$2,450,000** across 4 positions and has no
account record. At Standard tiers that is roughly **$6,100 a quarter** never
invoiced, and it has been invisible for as long as the account has existed.

**Options.** (a) Raise as blocking, hold the run until resolved · (b) raise and
bill on a default schedule · (c) raise and continue, invoice next period

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

### GAP-12 — Join fails on an untrimmed key

**Finding.** Alteryx does not trim join keys. One account key carries a trailing
space in the account extract and not in the holdings extract.

**Evidence.** ACC-1030 is a real client with real assets and was **never
billed**, **$1,287.24** this quarter. The account appears in both the left and
right drop counts, which is why the record counts looked internally consistent.

**Options.** (a) Normalise keys on load, trim and upper-case · (b) reject rows
whose key needs normalising · (c) fix the source system and leave the pipeline
strict

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

### GAP-13 — Billable account absent from the holdings extract

**Finding.** An open account with no positions in the extract is dropped by the
join, so an incomplete custodian file looks the same as an unfunded account.

**Evidence.** ACC-1120 opened 15 September and does not appear in the holdings
file at all. Either it is unfunded or the extract is incomplete, and the
pipeline cannot tell the difference.

**Options.** (a) Raise as blocking and reconcile extract counts to the custodian
control total · (b) treat as zero AUM · (c) raise as review and continue

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

### GAP-15 — Positions priced before the valuation date are dropped

**Finding.** The hard-coded date filter keeps only rows dated exactly
2026-09-30. A position the custodian priced a day earlier disappears.

**Evidence.** ACC-1013 holds an **$842,150** municipal ladder dated 29
September. The account was billed on roughly half its true assets.

**Options.** (a) Take the most recent price on or before the valuation date,
within the period · (b) require an exact valuation-date price and reject the
extract otherwise · (c) take the exact date where present, fall back otherwise,
and raise the fallback

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

## D. Data quality

### GAP-18 — Duplicate account row double-bills the client

**Finding.** A duplicated row in the account extract makes the join fan out, so
the account is invoiced once per duplicate.

**Evidence.** ACC-1010 appears twice and was **billed twice**: two invoices of
$2,829.87, $5,659.74 in total, against a correct fee of $3,483.26. This is the defect most likely to generate a client call.

**Options.** (a) Deduplicate on load, keep the first occurrence, raise an
exception · (b) fail the run on any duplicate key · (c) deduplicate silently

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

### GAP-19 — Duplicate position inflates AUM

**Finding.** An exact duplicate position row is counted twice by the Summarize.

**Evidence.** One account's AUM was inflated by **$579,644.51**, overbilling it
by $406.12 this quarter.

**Options.** (a) Deduplicate identical rows and raise · (b) fail on duplicates ·
(c) accept the custodian file as authoritative

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

### GAP-20 — Null market value contributes zero silently

**Finding.** The holdings input is configured `IgnoreErrors = True`, and Alteryx
`Sum` skips nulls. A position with no price reduces AUM with no error raised.

**Evidence.** One account holds a private fund position with an empty market
value. It is billed as though the asset does not exist.

**Options.** (a) Exclude the position from AUM and raise as blocking · (b) treat
as zero and raise as review · (c) hold the account out of the run until priced

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

### GAP-28 — Several lots of one ticker on the same date

**Finding.** A custodian file can carry more than one position in the same
ticker for the same account and date, with different values. The legacy
Summarize added them all. The first version of the target SQL kept one per
ticker and dropped the rest, which was a regression introduced by the migration.
An independent rebuild in T-SQL found it.

**Evidence.** Four ticker groups across the book hold $4,124,513.14. ACC-1010
alone holds three, and dropping them understated its AUM by $738,058.

**Options.** (a) Sum them as separate lots and raise for review · (b) treat the
later-loaded row as a restatement and keep only it · (c) reject the extract
until the custodian confirms

**Recommendation.**

**Rationale.**

**Confirms.**

**Impact if wrong.**

---

## E. Policy questions with no answer in the data

These are not defects. Nobody has recorded a decision, and the recommendation
has to come from analysis rather than from the source system.

| ID | Question | Evidence | Recommendation | Rationale | Confirms | Impact if wrong |
|---|---|---|---|---|---|---|
| GAP-21 | Does a margin debit reduce billable AUM, or is AUM billed gross of borrowing? | 5 accounts, $357,282.87 in debits | | | | |
| GAP-22 | Is cash fee-billable? Many advisory agreements exclude it | 1 account entirely in government money market, $1,190,520.38 | | | | |
| GAP-23 | Unknown schedule code: reject or default? | ACC-1019 carries `PREMIER`, absent from the schedule. Billed $8,236.83 on Standard tiers | | | | |
| GAP-24 | Missing schedule code: reject or default? | ACC-1063 has no code at all | | | | |
| GAP-25 | Where does the fee round — account or household? | 3 households show one cent of allocation drift | | | | |
| GAP-26 | Is the minimum fee per account or per household? | A $250 account minimum inside a tiered household can exceed the household's contracted rate | | | | |
| GAP-27 | What happened to ticket BIL-412? | Referenced on the canvas in 2019, not in the tracker. Someone knew about GAP-02 and it was never done | | | | |

---

## Ranking

By money in this quarter's run:

| Gap | Net effect | Direction |
|---|---|---|
| GAP-01 marginal tiers | $91,877.23 | Firm has been underbilling |
| GAP-07 proration | −$28,707.85 | Clients have been overbilled |
| GAP-16 closed accounts | $28,247.14 | Revenue never invoiced |
| GAP-03 household tiering | $19,259.31 | Mixed |
| GAP-23 unknown schedule | −$8,236.83 | Client overbilled |
| GAP-02 wrong schedule applied | −$7,864.20 | Clients overbilled |
| GAP-18 duplicate billing | −$2,176.48 | Client billed twice |

By client impact rather than money: GAP-18 (billed twice), GAP-07 (invoiced
$27,295 for two days), and GAP-05 (invoiced on an empty account) are the three
that generate a phone call.

By systemic risk: GAP-04. An exceptions report that cannot populate means every
run for seven years has looked clean.
