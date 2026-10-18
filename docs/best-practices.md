# A local model beside a frontier coding agent: best practices

This is the canonical summary of what we measured about when a local LLM helps a frontier coding agent such as Claude Code, and how to shape the work so it does. The rules are written tool-neutrally where they can be; section 7 says how this plugin applies them. Every number names its source; the short labels (results A, findings, prior art) are defined in [Sources](#9-sources).

Setup behind the numbers: an M5 Pro with 64 GB, LM Studio, a 32k loaded context, 4-bit Qwen models (the MoE `Qwen3.6-35B-A3B-Splash` unless a row says otherwise), Sonnet or Haiku 5.5 as the frontier side (findings, header).

## 1. The answer in one paragraph

A local model pays off only when the frontier agent stays out of its loop. Each delegation the agent makes inside its own loop costs about 6 agent turns (load the instructions, check the size, find the tool, call it, spot-check) against 2 for reading the file itself, so per-call delegation cost 17% more on 20k–36k-character files and saved about half only near 50k characters (results A, B). On real files its answers were usable 4 of 10 times against 8 of 10 for a direct read (results C). The shape that works is a deliberate batch: one brief, the local model maps many windows with no agent in the loop, the output is mechanically checkable (a verbatim quote per row), and the agent reads only a short index. A cheap frontier judge on the candidates turns that recall into precision: local recall plus one Haiku call beat Haiku alone on precision (83% against 50%) for about a twelfth of the Haiku-alone spend, $0.008 against about $0.10 (findings, Cascade). In dollars the local model competes with Haiku, not with Opus; what it durably buys is subscription quota, privacy and freedom from rate limits, and it buys them in batch (prior art, Answer).

## 2. Do and don't

| Do                                                                                          | Don't                                                                                               |
| ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Run many-file jobs as one batch the agent starts once and reads back as an index            | Delegate one file at a time from inside the agent's loop                                            |
| Ask for one kind of fact per job, in small windows                                          | Pack several kinds of fact into one instruction over a 50k window                                   |
| Require a verbatim quote and a line id per row, and drop rows whose quote isn't on the line | Treat a passing quote as proof the row is right or that nothing was missed                          |
| Count windows that returned no rows, and set a floor where one exists                       | Read "Completed" as "found everything"                                                              |
| Turn reasoning or thinking off for structured extraction                                    | Leave a reasoning model on its default thinking for schema-bound jobs                               |
| Derive window and file caps from the loaded context and the content's chars per token       | Assume 4 chars per token, or the model's advertised maximum context                                 |
| Follow local recall with a cheap frontier judge on the candidates                           | Ask the local model to judge, synthesize or rank                                                    |
| Price the agent's direct read before piloting a chore                                       | Pilot where the direct read already costs cents, or on structured records a script extracts exactly |
| Measure on real files the way users will name them                                          | Trust a harness that passes on synthetic fixtures                                                   |
| Make delegation explicit or opt-in per task kind                                            | Route unprompted and expect the agent to stay hands-off                                             |

## 3. Use cases that work, and that don't

### Works

**Classification.** The best of the single-file kinds.

- Delegated classification on real files was usable 3 of 4 times (results C).
- In batch, put the labels in an enum in the row schema; the quote per row shows where the evidence sits.

**Narrow extraction.** Works when the job asks for one kind of fact.

- On 4 hand-labeled Slack windows holding 39 facts: one job asking for four kinds found 62% at 77% precision; one kind per job in 4k windows found 87% at 78%; adding a Haiku judge ($0.044) took precision to 100% (82% strictly matched) at 87% recall (findings, people-ops follow-up).
- Broad single-file extraction did poorly: usable 1 of 3 (results C).
- Structured records (GitHub or Linear rows) are a script's job: the model only restates lines a script extracts exactly (findings, people-ops).

**Mining with quotes, plus a judge.** The strongest result.

- Friction mining, 10 sessions (19 windows): the MoE model returned 29–33 rows, 91–92% passed the quote check and 83% (25/30) were judged real, in 22 s warm with 0 agent turns. Haiku via `claude -p` found 37 rows, 93% judged real, for about $0.03 at API rates (findings, Batch map).
- Correction mining, the hardest class: local one-instruction recall (100% recall, 30% precision, 91 s), then one Haiku call judging the 20 candidates (83% precision and recall, $0.008), beat Haiku alone (50% precision, about $0.10) (findings, Cascade).

### Weak or doesn't work

**Open-ended mapping into themes (weak).**

- 1,124 planning documents (5.2M tokens) took 91 minutes and reduced to 10 generic, mention-weighted themes. A Sonnet lane on the same folders took about 144k tokens and 3 minutes, and its result was sharper and actionable (findings, Batch map). The local model maps; it does not decide what matters.

**Summaries (don't).**

- Delegated summaries were usable 0 of 3 on real files (results C). A summary has no mechanical check, so a bad one costs the agent a full read anyway.

**Judgment, synthesis and computed claims (don't).**

- On claim checking, the local model got lookup claims right (24/24; the easy set 48/48 with 0 false accepts) but made 12 false accepts on 48 hard, computed claims (counts, comparisons, dates), 2 of them unanimous (AGENTS.md, verify eval).
- Published studies agree: only the largest judges align reasonably with humans, and even frontier judges score near random on hard pairs (prior art: Judging the Judges, JudgeBench).
- Re-checking a corpus to validate local conclusions erased the batch's savings (results D).

**Small files (don't).**

- The overhead is fixed, so 20k–25k-character files cost the same or more delegated; below 20k is unmeasured. The break-even sits between 25k and 50k (results A, B), and this plugin's floor is 30k (findings, Single-file).

**Unprompted single-file delegation (don't, by default).**

- The size hint had to be an instruction: hedged, the agent read real files itself 22 of 23 times; as an instruction it delegated 25 of 27 (findings, Single-file).
- Once it delegated reliably, its answers were usable 4 of 10 against 8 of 10 direct, at 3.4% more cost and a median of 6 turns against 2 (results C).

**Unprompted batch routing (don't).**

- The agent started a 60-ticket classification batch on its own, but finishing took 14–17 turns and $0.19–0.44: inline JSON tripped a shell-quoting check, globs were rejected, and the agent re-read tickets to check rows (results D). Batch stays an explicit request.

## 4. Job-shape rules

- **One instruction per job.** Splitting a multi-kind job into one-kind jobs, with smaller windows, doubled local recall on corrections (50% to 100%) (findings, Cascade) and lifted Slack recall from 62% to 87% (findings, people-ops follow-up). MinionS measured +56 points from splitting a multi-step instruction (prior art, Minions).
- **Small windows.** About 20k characters for interpretation-heavy kinds (corrections, causes), 4k for dense chat text (findings, Cascade and people-ops follow-up). MinionS gained 11.7 points going from 100-page to 5-page chunks, and lost 13% on simple extraction as context grew from under 1k to over 65k tokens (prior art, Minions).
- **A quote-in-line check.** Each row carries a line id and a verbatim quote of at least 12 characters (or the whole line), and a row whose quote is not a substring of that line is dropped. It is a cheap gate: 91–92% of friction rows passed, and 61% of chore rows (findings, Batch map). It proves where evidence sits, not that the label is right or recall complete. Google's LangExtract uses the same grounding gate at character offsets (prior art).
- **Count empty windows.** Silent under-extraction is the main danger: a window that returns too few rows or none looks complete in an index. Count zero-row windows, list them, and check row counts against a floor where the content implies one (findings, people-ops follow-up). The dense 27B model stopped partway through long lists with no error (findings, people-ops).
- **Reasoning off for structured jobs.** With reasoning on, 11 of 19 transcript windows spent the whole 4,000-token budget thinking and returned no rows (findings, Batch map). With an explicit rubric, thinking cut precision (dense: 100% to 55%; MoE: 30% to 25%, with recall falling to 33%) and added minutes (findings, Cascade table). One MLX build ignored reasoning-off and put its answer in the reasoning field (findings, Batch map). OpenAI's guide documents the same trap: reasoning tokens count toward the output cap (prior art).
- **Dense vs MoE.** On the one-instruction correction job, the dense 27B with thinking off reached 100% precision (5/5) at 83% recall in 422 s; the 35B-A3B MoE reached 30% precision at 100% recall in 91 s (findings, Cascade table). On friction mining the dense model was 4–18× slower and found 5 rows to the MoE's 29–33 (findings, Batch map). Use the MoE for recall feeding a judge; use the dense model when precision matters and there is time. A local dense-judges-MoE cascade failed on its first try (thinking leaked into the strict-schema answer, which degenerated into whitespace) (findings, Cascade).
- **Know the tokenizer.** Qwen tokenizes every digit separately. Measured with its own tokenizer: prose and code about 2.7 chars/token, logs 1.6–2.4, numeric CSV 1.0 (findings, Context and tokenization). Numbered dense logs measure about 1.5 (AGENTS.md, delegation bounds).
- **Derive caps from the loaded context.** The cap is in characters: (loaded context − reserve) × chars per token, where the context is what the server loaded, not the model's maximum (findings, Context). At 1.6 chars/token and a 32k load that is 45,875 characters for one file (4,096-token reserve) and 44,390 per batch window (5,024) (AGENTS.md, delegation bounds and Batch runner). Overflow must fail loudly (`context_length_exceeded`), never truncate.
- **A cascade: local recall, then a cheap judge.** The judge sees each candidate with a few lines of context (±3 lines, 59k characters for 20 candidates), not the corpus (findings, Cascade). Haiku agreed with a Sonnet reference on 18 of 20 candidates (findings, Cascade). This is FrugalGPT's cascade with the order chosen for recall (prior art).

## 5. Cost model

**Orchestration turns dominate.**

- The local model's own time is about 4 s per call. The cost is the agent's turns around it: about 6 per delegation against 2 for a direct read (findings, Single-file; results, summary).
- Trimming turns (pairing loads, reusing the hinted size, spot-checking in proportion to stakes) cut the median from 7 to 5 and the mean cost per job from $0.056 to $0.032 (results, Implications). Small files still did not pay.
- Anthropic reports agents use about 4× the tokens of chat, and multi-agent systems about 15× (prior art).
- Router papers (RouteLLM, Hybrid LLM) price one stateless call per query, and practitioner claims of 86–95% savings leave out the agent's orchestration and checking turns, so neither transfers to an agent loop (prior art, Answer).

**The prompt cache erodes the savings.**

- Re-reading a just-read 50k file cost $0.015 warm against $0.023–0.033 delegated (results B).
- Cache reads cost 0.05× base input on Opus and Sonnet 5.5; the cache lives 1 hour on a subscription and 5 minutes on an API key (prior art, pricing and costs docs).
- The other side, untested: a direct read stays in context and is re-billed at 0.05× on every later turn until compaction (about 2.25× its tokens after 20 turns), so delegation may win below 50k in long sessions (findings, Untried 2).

**Where the break-even sits.**

- Per-call delegation breaks even between 25k and 50k characters and saves about half near 50k (results A, B).
- A batch costs zero agent turns while running, so its break-even is what the agent would otherwise pay. Price the direct read first: the people-ops collation cost about $0.93 per team-month to read directly, so a batch could save under $1 (findings, people-ops).
- In dollars, Haiku 5.5 ($0.10/$0.50 per MTok as listed) is the competitor, not the main model (prior art, pricing).

## 6. Measurement practice

- **Real files, not synthetic.** Synthetic fixtures with tidy names passed the delegation harness while real project files failed: before the size-hint fix, 1 of 23 real-file runs delegated (results A), and the file's path decided the outcome, which is why the harness gained a real-looking project case (AGENTS.md, case h). Repetitive synthetic prose also produced local answers that ran to the token limit (AGENTS.md, historical measurements). Usable-answer rates came only from real files graded blind (results C).
- **Measure usability, not only cost.** The harness's delegation cases passed while real-file answers were usable 4 of 10 (results C). Grade every answer against the file, with the configuration hidden from the judge (AGENTS.md, Measuring).
- **Run a Haiku arm.** Every local comparison needs the cheapest frontier tier beside it, scored the same way (prior art, Ideas 1; findings, Batch map).
- **Count only valid runs, and price controls.** Subtract a no-file control per configuration, count a run only on positive evidence, and keep failed delegations in the totals at their real cost (AGENTS.md, Measuring).
- **Check matched conditions.** One published compressor's −75.5% headline fell to −2.4% under matched conditions (prior art, Shevchenko). Ambient context skews small numbers: connectors loading into some sessions made the fixed cost 3.4k tokens instead of about 0.7k, and an ancestor directory's instruction file added about 8.5k tokens per call (AGENTS.md, Measuring).

## 7. How this plugin encodes it

- ✅ **Default off for unprompted single-file delegation.** `delegate_tasks` is empty; Claude reads files itself unless you ask ("use the local model to classify …") or opt in per kind (`classify,extract`). Add `summarize` only after measuring reliable summaries (README, options).
- ✅ **A size hint bounded by the measured break-even and the loaded context.** From 30,000 bytes through `floor((contextTokens − 4096) × 1.6)` characters, with a 32k fallback; above the cap it says to read slices instead (AGENTS.md, Permissions and delegation bounds).
- ✅ **An explicit-only batch skill.** `batch-local` runs only on an explicit local-model or batch request over many files: one-instruction job, strict row schema, `check: "quote-in-line"`, about 20k windows for interpretation, temperature 0, `reasoning_effort: "none"` by default, an optional `min_rows_per_window` floor, and an `index.md` that counts no-row windows and failures. Claude reads the index and only the rows its answer depends on, never the inputs again (`skills/batch-local/SKILL.md`; AGENTS.md, Batch runner).
- ✅ **Approval without broad permissions.** A hook approves the two skills, the two read-only tools, and a whole runner command only in its headless `--job-json` form with every input inside `allowed_dirs`; everything else, the interactive `--job <file>` form included, takes the normal prompt (AGENTS.md, Permissions).
- ✅ **`verify_claims` is a hint.** Every result carries `auto_accept: false`; computed claims are where it fails (AGENTS.md, verify_claims).
- 🔲 **Planned or untried:** an abstain field and a gap-only follow-up round (MinionS), escalating dropped rows to Haiku, parallel slots with prefix reuse, and a 64k load (findings, Untried; prior art, Ideas).

## 8. Relation to model-routing

The model-routing project routes each job to the worker that suits it, and this document is the routing rule set for the local worker. Route to the local model only a deliberate batch of one-kind, checkable mapping jobs (classification, narrow extraction, quote-backed mining) over many inputs, started once and read back as an index, with a cheap frontier judge where precision matters. Route summaries, judgment, synthesis, computed claims, small files and structured records elsewhere: to the agent itself, Haiku, or a script. Any other worker that runs outside the agent's loop with a report-file contract inherits the same cost rule: it pays off only when the agent stays out of its loop.

## 9. Sources

- **results A–D, Implications:** [docs/results.md](results.md) in this repo ([A](results.md#a-paired-runs-on-the-frozen-real-corpus), [B](results.md#b-files-near-50k-characters), [C](results.md#c-unprompted-single-file-delegation-re-measured-2026-10-17-run-20261017-213110), [D](results.md#d-unprompted-batch-routing), [Implications](results.md#implications)).
- **AGENTS.md:** [the contributor guide](../AGENTS.md): the delegation harness cases, Measuring, the delegation bounds and Permissions under Non-obvious design decisions, and Batch runner.
- **README:** [When to use it](../README.md#when-to-use-it) and the plugin options.
- **findings:** `findings-2026-10-17.md` in the operator's local-llm planning references (not in this repo): sections Single-file delegation, Batch map, Cascade, Real chore: people-ops collation, Context and tokenization, Untried.
- **prior art:** `prior-art-hybrid-local-2026-10-17.md` beside it: the Answer paragraph, the comparison table (Minions, FrugalGPT, RouteLLM, Hybrid LLM, Anthropic's multi-agent report, the Claude pricing and costs docs, Shevchenko, Judging the Judges, JudgeBench, LangExtract, the OpenAI reasoning guide) and Ideas we haven't tried. Published sources there were opened and read; key ones: Minions <https://arxiv.org/abs/2502.15964>, FrugalGPT <https://arxiv.org/abs/2305.05176>, RouteLLM <https://arxiv.org/abs/2406.18665>.
