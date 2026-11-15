# Outreach drafts — edit before sending

Not for the repo. These are starting points in a neutral voice; rewrite them so
they sound like you. If the LinkedIn post reads like it was written by someone
else, that is worse than not posting.

---

## LinkedIn post

> I spent the weekend migrating an undocumented Alteryx workflow to SQL, because
> I wanted to see what the work actually looks like rather than describe it.
>
> The setup: a quarterly advisory fee calculation, 13 tools, built in 2019 by
> someone who has since left. No documentation, no tests. The kind of thing that
> runs quietly until it doesn't.
>
> What reading the XML turned up:
>
> → The exceptions report had been empty for seven years. Not because the data
> was clean — because the minimum-fee rule ran before the "exclude zero fees"
> filter, so every row was forced above the threshold and the filter could never
> catch anything. An empty exceptions report looks exactly like a clean run.
>
> → Tier pricing wasn't monotonic. One rate was applied to a client's entire
> balance, so a client at $1,000,001 paid $630 less per quarter than one at
> $999,999.
>
> → A client holding $2.45M was never invoiced at all. Their positions
> referenced an account number missing from the account file, and the join
> discarded them without a word. Another was never invoiced because of a
> trailing space in a key.
>
> → Two files sat in the input folder that no tool ever read. One of them was
> the published fee schedule.
>
> The rebuild was the easy half. The harder half was deciding what the new
> system should do about each ambiguity, and being able to defend it: marginal
> or cliff tiers, prorate a mid-quarter open or bill the full period, does a
> margin debit reduce billable assets. Twenty of those. Each one needs a
> recommendation, not an escalation.
>
> Then proving it. Matching totals prove nothing — two runs can agree on a total
> and disagree on every account. So every account where the two runs differ is
> attributed to a specific signed-off decision, and anything unattributable
> lands in a defect log that blocks cutover. That log is empty, and 13 tests
> recalculate every fee a second way to keep it that way.
>
> Everything is synthetic and the defects are planted — the repo says so up
> front. The detection isn't planted, though. The inventory script finds
> unconnected join anchors and hard-coded business rates in any Alteryx file,
> which is how you scope thirty of these instead of guessing.
>
> Repo in the comments. Happy to talk to anyone doing this kind of migration
> work.

**Before posting:**
- Put the link in a comment, not the post. Reach is better.
- Cut it by a third if it feels long. The first two findings carry it.
- Hashtags: skip them or use two at most.
- If you are not comfortable with any sentence in it, delete that sentence.

---

## Note to the recruiter or hiring manager

> Hi [name],
>
> I noticed the role centres on the Alteryx to Microsoft migration, so over the
> weekend I built a small version of one to show how I would approach it rather
> than just describe it: an undocumented fee-billing workflow, reverse-engineered
> from the XML, rebuilt in SQL, with a reconciliation that accounts for every
> account where the two runs disagree.
>
> It surfaced six real pricing and record-loss defects, including an exceptions
> report that was structurally incapable of reporting anything. The repo is
> here: [link]
>
> Everything in it is synthetic and the write-up says so. I would be glad to
> walk through the decisions, particularly the ones I deliberately did not make.
>
> [your name]

**Keep it to five sentences.** The repo is the pitch.

---

## Answers worth having ready

**"You planted the defects yourself."** True, and the repo says so. The defects
are the realistic ones — unconnected Join anchors, untrimmed keys, rates
hard-coded in a Formula tool, an ordering bug that makes a control unfirable.
The detection is generic: the inventory script flags those patterns in any
workflow. Offer to run it against one of theirs.

**"Why SQLite and not SQL Server?"** So it runs with one command and no licence.
The SQL is set-based ANSI style and `target/PORTING.md` lists exactly what
changes, including money becoming `decimal(18,2)` rather than a float, which
matters because fee arithmetic on binary floating point produces one-cent
invoice disputes.

**"Which of these would you actually escalate?"** The four households contracted
for aggregate tiering whose accounts span different fee schedules. Picking a
tier ladder for them would be inventing a contract term. Everything else gets a
recommended default and a flag.

**"What would you do differently with more time?"** Effective dating on the fee
schedule, so a rate change is a dated row and any prior period can be
recalculated as it stood at the time. Fee billing is retroactively auditable by
nature and the proof is not.

**Have a question ready for them too.** The best one: *how are you proving
parity on the migrations you have already done?* It is the question someone who
has done this work asks first.
