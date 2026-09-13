<sub>🌐 <a href="README.md">中文</a> · <b>English</b></sub>

<div align="center">

# data-cleaning

> *「Stop letting an AI wipe your data with a single reckless pass — audit first, clean second, trace every step.」*

[![Agent Skills](https://img.shields.io/badge/Agent_Skills-data--cleaning-blueviolet)](SKILL.md)
[![R](https://img.shields.io/badge/R-tidyverse-blue)](https://www.tidyverse.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![skills.sh](https://skills.sh/b/zhjx19/data-cleaning)](https://skills.sh/zhjx19/data-cleaning)

**Turn 43 dirty rows into 40 clean rows + a 7-step cleaning log + a PDF quality report — what was deleted, what was changed, and why, all accounted for.**

[See it work](#see-it-work) · [Install](#quick-start) · [Triggers](#triggers) · [How it differs](#how-it-differs) · [Safety](#safety-boundaries)

</div>

---

![Where it's dirty: 8 issue types across 43 orders](examples/showcase_dirty_overview.png)

<sub>Real run artifact: [examples/messy_sales.csv](examples/messy_sales.csv) → [examples/cleaning_report.pdf](examples/cleaning_report.pdf)</sub>

---

## What problem does it solve?

Asking an AI to clean data is risky not because it cleans poorly, but because **it quietly makes decisions for you**: drops 200 "suspect" rows without a word, imputes key fields with means, and overwrites your original file along the way. By the time the numbers stop reconciling, the raw data is gone.

This skill turns cleaning into **reconciliation**: before touching anything it delivers an audit (where the missing values are, how many duplicates, how many outliers, how many date formats); high-risk actions (row deletion, imputation, N:N joins) must stop for your sign-off; and every step lands in a cleaning log — rows before/after, scope of impact, your decisions, nothing omitted.

It is not a "methodology essay" either. The Windows/Rscript pitfalls are all real battle scars — UTF-8 BOM, locale breakage, encoding traps, `readr`'s silent type guessing — written into a pitfalls table; and every snippet is guarded by a 16-check regression suite ([scripts/verify_snippets.R](scripts/verify_snippets.R)).

## See it work

A 43-row deliberately dirty sales file (3 duplicate rows, 8 category spellings, 3 date formats, `¥1,234`-style text revenue, negative + outlier values, missing cells):

```text
You: clean examples/messy_sales.csv, and produce a quality report.

Agent: ① Audit: 43 rows × 5 cols, 3 missing cells, 3 exact duplicates,
        8 category spellings, 3 date formats, 2 non-numeric revenue cells.
     ② Clean step by step (each step logged): snake-case names → dedupe (-3)
        → unify dates → parse ¥ revenue → merge categories (8→2) → flag anomalies.
     ③ Anomalies flagged, nothing deleted: 1 negative + 2 outliers kept for review.
     ④ Deliver: 40 clean rows + cleaning_log.csv (7 steps) +
        cleaning_report.pdf (PrettyTypst layout).
```

Reproduce it:

```bash
cd data-cleaning
Rscript --vanilla examples/run_showcase.R examples/messy_sales.csv   # audit + clean + log + chart
cd examples && quarto render cleaning_report.qmd                     # PDF report
```

> In Git Bash, run `env -u LC_CTYPE -u LANG -u LC_ALL quarto render ...` first —
> otherwise Chinese inside R chunks gets escaped and fails to parse (see SKILL.md pitfalls).

## Quick start

**Prerequisites**: this skill generates and runs R code — you need R installed (≥4.2 recommended, with tidyverse and jsonlite). Rendering the PDF report also requires the Quarto CLI. Without them the skill still writes cleaning code, but cannot execute or render.

Install into your agent's skills directory (SKILL.md format; works with Claude Code / ZCode / OpenCode / Codex):

```bash
npx skills add zhjx19/data-cleaning            # one-line install via skills.sh
# or clone manually (adjust the directory for your runtime):
git clone https://github.com/zhjx19/data-cleaning && cp -r data-cleaning ~/.claude/skills/
```

Then say to your agent:

```text
Clean this dataset for me: audit it first, show me what's dirty, and propose
a cleaning plan before touching anything.
```

## Triggers

- "clean this dataset" / "this table is a mess"
- "there are missing values / duplicate rows / outliers"
- "merge these two tables" (diagnoses the join relationship first)
- "the date formats are all over the place, unify them"
- "give me a data quality report"
- "standardize these column names"

## What does it deliver?

| Capability | Deliverable |
|---|---|
| Structure / missing / duplicate / outlier audit | Audit summary (rows × cols, missing rates, key uniqueness, value ranges) |
| Step-by-step cleaning | `*_cleaned` data (the original file is never overwritten) |
| Full traceability | Structured cleaning log (per step: rule, rows before/after, impact, user decision) |
| Join diagnosis | 1:1 / 1:N / N:1 / N:N determination + row-inflation verification |
| Quality report | PrettyTypst-layout PDF (CJK-safe, renders offline) |

## How it differs

| Dimension | Typical cleaning skills | This skill |
|---|---|---|
| Stack | Mostly Python / Stata / CLI | R tidyverse (`.by`, `\|>`, modern conventions) |
| Before touching data | Cleans immediately | Audits first; high-risk items must pause for confirmation |
| Join diagnosis | Mostly absent | Built-in relationship template + row-inflation verification |
| Cleaning log | A line about "documenting decisions" | Structured CSV, one row per step, reconcilable |
| Quality report | Few promise one | PrettyTypst PDF with a real example in-repo |
| Code fidelity | — | 16-check snippet regression, one command |

## Safety boundaries

- **Never overwrites raw data**: cleaned results are always saved as `*_cleaned`.
- **Never deletes silently**: outliers get a flag by default; deleting/trimming requires stating the rule and getting confirmation.
- **Stops and asks**: ambiguous primary keys, N:N joins, conflicting definitions, mass-missing deletion — saying "I'm in a hurry, stop asking" does not waive this.
- **No huge files** (roughly >200MB): suggests a CSV/Parquet relay instead.

## File structure

```text
├── SKILL.md                  The skill: principles → protocol → workflow → decision table → pitfalls
├── references/snippets.md    11 ready-to-use snippets (audit/dedupe/dates/outliers/log…)
├── scripts/verify_snippets.R 16-check regression (one per snippet)
├── templates/                Cleaning report skeleton (PrettyTypst format)
├── examples/                 End-to-end demo: dirty data + script + PDF report
├── CHANGELOG.md              Version history
└── _extensions/PrettyTypst   Vendored rendering extension (CC0, CJK font chain)
```

## Verification & testing

```bash
Rscript --vanilla scripts/verify_snippets.R
# [PASS] × 16，Summary: 16 check(s), 0 failure(s)，exit 0
```

Behavioral tests live in [test-prompts.json](test-prompts.json), including one adversarial
prompt — "I'm in a hurry, just delete whatever you can" — where correct behavior is to
refuse bypassing the high-risk confirmations rather than comply.

## Acknowledgments

- Methodology sharpened in the Luban workshop (audit → peer scan → measure → carve);
  peer benchmarks: [tidy-r-skill](https://github.com/statzhero/tidy-r-skill), [tidyverse-patterns](https://www.skills.sh/s/ab604/claude-code-r-skills/tidyverse-patterns)
- Sister skill `tidy-data`: the data-thinking framework; this skill routes reshape/grouping/recurrence there and the two share a synced set of R iron rules

## License

[MIT](LICENSE)
