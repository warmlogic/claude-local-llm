# Measured savings

Single-file delegation through the MCP tool saves about 50% of Claude cost on files near 50k characters and costs the same or more on files of 10k to 25k characters. The break-even sits between those sizes. The cause is fixed orchestration overhead: about 6 Claude turns (skill load, size check, ToolSearch, the call, a spot check) against 1 to 2 for a direct read. Wall time is 2 to 5 times higher; the local model itself takes about 4 s (median).

## A. Paired runs on the frozen real corpus

Ten files of 20k to 36k characters (classification, summary and extraction jobs), Sonnet as the main model, plugin off against plugin on. Plugin-on figures are the mean over runs that called the tool (25 of 27 runs delegated, after the size-hint fix; the transcript job f10 comes from the earlier run, one delegated run). Plugin-off is one run per file. Each cell is off / on.

| File | Chars | Delegated runs | Seconds | USD | Turns | Cost change |
| --- | --- | --- | --- | --- | --- | --- |
| f01 | 33.5k | 3 | 4 / 16 | 0.062 / 0.062 | 2 / 6 | 0% |
| f02 | 34.7k | 2 | 4 / 14 | 0.030 / 0.060 | 2 / 6 | +103% |
| f03 | 36.4k | 3 | 5 / 15 | 0.032 / 0.059 | 2 / 6 | +87% |
| f04 | 24.1k | 3 | 4 / 14 | 0.029 / 0.057 | 2 / 6 | +94% |
| f05 | 20.6k | 3 | 11 / 20 | 0.064 / 0.066 | 2 / 6 | +3% |
| f06 | 26.7k | 3 | 10 / 21 | 0.073 / 0.064 | 2 / 6 | -12% |
| f07 | 28.1k | 3 | 7 / 26 | 0.068 / 0.086 | 2 / 10 | +26% |
| f08 | 21.9k | 3 | 7 / 27 | 0.062 / 0.085 | 2 / 9 | +35% |
| f09 | 30.1k | 2 | 7 / 32 | 0.091 / 0.100 | 2 / 13 | +11% |
| f10 | 33.4k | 1 | 13 / 22 | 0.091 / 0.061 | 2 / 6 | -33% |
| Sum | | | 72 / 206 | 0.602 / 0.701 | | +17% |

The first full measurement, before the size-hint fix, delegated 1 of 23 plugin-on runs (cost -1.5%). Delegation reliability was fixed first; the table above is the result once the tool is actually called.

## B. Files near the cap

Ad hoc, 2026-10-17, main at fdc1b75: three real documents of 48k to 54k characters, "Summarize <path> in 5 bullets", 2 reps each.

| | Cold read, plugin off | Delegated |
| --- | --- | --- |
| USD | 0.142 to 0.146 | 0.070 to 0.076 |
| Seconds | about 8 | about 21 |
| Turns | 2 | 6 |

A warm-cache repeat with the plugin off cost $0.015 against $0.023 to $0.033 delegated: the prompt cache makes re-reading a just-read file nearly free.

## Gate

The plan's gate (per-job Claude cost at least 50% lower) is met only for files near the cap. It is not met as a general claim.

## Implications

- Raise the skill's lower bound to about 30k characters and derive the upper bound from the loaded model's context (task local-llm-8al.4).
- Many-file jobs go through `batch/run.mjs`: one start and one index read, instead of 6 turns per file.

## Quality

The operator spot-check sheet is pending; usable-answer rates are not reported yet.
