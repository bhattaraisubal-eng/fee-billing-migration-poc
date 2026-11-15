# Case study — write this in your own words

**This is a scaffold, not a draft.** The structure, the facts and the figures
are here. The argument is yours to make, and it has to be, for two reasons: it
is the part a hiring manager is actually evaluating, and you will be asked to
defend every claim in it. A sentence you cannot argue in an interview is worse
than a sentence you never wrote.

Budget 2.5 hours. Aim for 4–5 pages. Delete this box when you are done.

---

## Suggested structure

### 1. The situation (one paragraph)

What you were handed and why it mattered. Facts available:

- One Alteryx workflow, 13 tools, calculating quarterly advisory fees
- Author left the firm in 2023, no documentation, no tests
- First of roughly 30 workflows the firm is moving off Alteryx
- It sits in the revenue path: its output becomes client invoices

**Write the hook yourself.** The strongest opening is the finding that an
undocumented workflow had been producing an empty exceptions report for seven
years and everyone read that as a clean run.

### 2. How you read the as-is (half a page)

What you did, in order. Facts available:

- A `.yxmd` is plain XML, so you parsed it rather than clicking through it
- `tools/yxmd_inventory.py` extracted all 13 tools, 7 expressions, 4 file
  dependencies, and flagged 6 risks automatically
- Two files sat in the input folder that no tool read: `households.csv` and
  `fee_schedule.csv`. That absence was the largest finding in the whole exercise
- A 2019 comment box on the canvas referenced ticket BIL-412, which was never
  located

**Make the point about method.** Parsing rather than reading scales to thirty
workflows; clicking through them does not. That is the difference between an
analyst and a tool.

### 3. What was wrong (one to one and a half pages)

Pick four or five, not all twenty. Lead with the ones that cost money or would
generate a client call. The full set is in `analysis/GAP_LOG.md`.

The strongest candidates:

| Finding | The number |
|---|---|
| Exceptions report structurally cannot populate | 0 rows, every run since 2019 |
| Tier pricing not monotonic | $999,999 → $2,520; $1,000,001 → $1,890 |
| Client holding $2.45M never invoiced | Orphan account number, join dropped it |
| Client never invoiced because of a trailing space | Alteryx does not trim join keys |
| One client billed twice | Duplicate row, join fanned out |
| Account holding $45.27M for 55 days invoiced nothing | Status filter dropped it on closure |
| Account holding nothing invoiced $250 | Minimum fee applied before the zero check |
| Client who held assets 2 days invoiced $27,295 | No proration anywhere in the workflow |

**Do not just list them.** Group them. The pattern worth naming is that four of
the six defects are the same root cause: the workflow had no way to say "this
record did not make it, and here is why."

### 4. The decisions you made (one page — this is the section that matters)

Take three gaps and show the reasoning end to end: options, what you
recommended, why, who confirms, what it costs if you are wrong. GAP-01 is the
obvious one because $88,236 turns on it in a single quarter.

**What makes this section good.** Not that you found the ambiguity — that you
resolved it with a defensible default instead of escalating it. Say explicitly
that you would not hold delivery waiting for a meeting; you would recommend,
flag, and proceed.

Also say what you deliberately did **not** decide: four households contracted
for aggregate tiering hold accounts on mixed fee schedules, and choosing a
ladder for them would be inventing a contract term. Knowing which calls are not
yours is part of the skill.

### 5. How you proved it (half a page)

Facts available:

- Reconciliation full-outer-joins both runs and classifies every account
- Every variance attributed to a numbered gap; `v_defects` holds what cannot be
  attributed, and it is empty
- All 115 fees recalculated a second way from an independently typed schedule
- Five invariants asserted; 13 tests, all passing
- Net movement +$89,058.84 (+14.3%), fully decomposed by cause

**Make the argument about what parity means.** Matching totals prove nothing.
Two runs can agree on a total and disagree on every account. The test is whether
each difference is a decision or a surprise.

Note the direction of the movement: the firm had been **underbilling**, not
overbilling. That reframes the conversation from refunds to restatement, and it
is the kind of implication worth stating.

### 6. Scaling it (short)

Pull from `delivery/ROADMAP.md`: measuring the estate rather than estimating it,
complexity weighting by the tools that do not survive the move to SQL, waves,
dependencies first, revenue paths get a parallel run, and expect 10–20% of
workflows to have no consumer and be worth retiring rather than migrating.

### 7. What you would ask on day one (short, and finish here)

This is the section that reads like someone who has done the job. From
`delivery/ROADMAP.md`:

1. What does "Microsoft" mean here — Azure SQL, Synapse, Fabric warehouse or
   lakehouse? It changes orchestration, not logic
2. How is parity being proved on the migrations already done?
3. Who owns the Operations spreadsheets downstream of these workflows? Fee
   billing has one in its revenue path and it is in no inventory
4. How many of the 30 have a live consumer?

---

## Things to be careful about

- **State the provenance.** Synthetic data, hand-authored `.yxmd`, planted
  defects, SQLite rather than SQL Server. It is all in the README; say it in the
  case study too, briefly, near the top. Anyone technical will work it out in
  five minutes, and getting there first is a point in your favour rather than
  against you.
- **Do not inflate it.** "A self-directed exercise built over a weekend" is
  accurate and sufficient. It does not need to sound like client work.
- **Be ready for the obvious challenge.** "You planted these defects yourself,
  so how do I know you could find them in the wild?" The honest answer is the
  strong one: the defects are the realistic ones — unconnected Join anchors,
  untrimmed keys, hard-coded rates, an ordering bug that makes a control
  unfirable — and the detection is generic. The inventory script finds
  unconnected anchors and hard-coded literals in any workflow, not just this
  one. Have that answer ready rather than improvising it.
- **Know your own SQL.** You will be asked to read or write some. Make sure you
  can walk through `04_fee_calc.sql` line by line, especially the tier
  arithmetic and why household allocation works the way it does. If any of it is
  unclear, that is the first hour of your ten, not the last.
