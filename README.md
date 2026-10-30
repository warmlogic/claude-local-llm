# local-llm

Offload file-heavy, low-stakes text jobs from Claude Code to a model running locally in LM Studio.

Unprompted single-file delegation is off by default (`delegate_tasks` is empty). On real files with today's local model, delegated answers were usable 4/10 vs 8/10 when Claude read the file itself, and cost 3% more. Claude reads the file itself unless you explicitly ask, for example, "use the local model to classify …", or opt in to task kinds such as `classify,extract` in the plugin configuration.

When enabled, the size hint names eligible task kinds for files from about 30k characters through the loaded model's context cap (about 45k without a size hint). The local model reads the file and returns text; only its answer and any lines Claude spot-checks enter Claude's context. Claude treats the answer as a draft and checks it in proportion to what depends on it. Above-cap warnings remain active with delegation off. Batch classification, extraction and mining across many files use `batch-local` only when you explicitly request the local model or a batch/local run. Single-file jobs never start batch.

## When to use it

The rules behind this list, with every measurement, are in [docs/best-practices.md](docs/best-practices.md).

- **An explicit single-file job:** “Use the local model to extract ERROR messages from /path/to/app.log.” Use files from 30k characters through the loaded context cap, with output you can check.
- **A deliberate batch over many files or transcripts:** “Use the local model to classify these 200 tickets in /path/to/tickets.” Or: “Run a local batch over these transcripts to mine corrections with quotes.” Choose classification, narrow extraction or mining with evidence; [batch measurements](docs/results.md#d-unprompted-batch-routing) explain why this requires an explicit request.
- **Measured opt-in delegation:** once your model measures well, set `delegate_tasks` to kinds such as `classify,extract`, then ask “Classify /path/to/large-document.md by topic.” [The current model's results](docs/results.md#c-unprompted-single-file-delegation-re-measured-2026-10-17-run-20261017-213110) keep this off by default.

Don't use it for:

- **Open-ended summaries or drafts:** summaries were usable 0/3; drafts have no measured quality result. Prefer checkable tasks ([results C](docs/results.md#c-unprompted-single-file-delegation-re-measured-2026-10-17-run-20261017-213110)).
- **Judgment or synthesis:** quotes establish evidence location, not sound conclusions; re-checking the corpus erased the intended batch benefit ([results D](docs/results.md#d-unprompted-batch-routing)).
- **Small files:** fixed orchestration overhead makes 20k–25k files cost the same or more; below 20k is unmeasured ([results](docs/results.md)).
- **Anything secret:** answers, quotes and fallback reads can reach Claude; local inference does not make this a private channel (see [Privacy and security](#privacy-and-security)).

Outside Claude, save a job JSON file ([example below](#bulk-jobs)), then run `node "/path/to/plugin/batch/run.mjs" --job "/tmp/job.json" --number "/path/a" "/path/b"`. Use `--transcripts` instead of `--number` for session JSONL.

Status:

- ✅ Implemented: the MCP server (houtini-lm, pinned) behind a fenced launcher, the `delegate-local` skill, the permission hook, and the tests.
- ✅ Implemented: a second server, local-verify, with one tool, `verify_claims`: the local model votes on whether short claims are supported by a file, without the file entering Claude's context. Its answer is a hint, never verification, and the skill does not use it yet.
- ✅ Implemented: a repeatable measurement harness (`bash measure/run.sh`; see AGENTS.md, "Measuring") for Claude cost, tokens and answer quality on real files.
- ✅ Implemented: real-file cost and quality measurements (`docs/results.md`). The latest result motivates keeping unprompted single-file delegation off by default.
- ✅ Implemented: a permanent install from the public `ai-plugin-marketplace` (section 4), or per session with `--plugin-dir`.

## Prerequisites

- An Apple Silicon Mac with enough memory for the model. The recommended model is a 20.95 GB download, and the Splash runtime asks for a Mac with an M3 or later, macOS 26.4 or later, and at least 36 GB of memory (vendor figures).
- Node.js with `npx`. The plugin starts its server with `npx`.
- [LM Studio](https://lmstudio.ai) and its `lms` command line tool, with its server running on loopback (section 3) and a model loaded (section 2). The alternative is LM Studio's just-in-time model loading with the plugin's `model` option set: LM Studio then loads that model on the first request (see section 2).
- A model loaded with a context of at least 32k tokens. The plugin's 30k-character floor only fits from there: the cap is `floor((contextTokens - 4096) * 1.6)` characters, so a model loaded at 8,192 tokens caps out near 6.5k characters and nothing at or above the floor fits. A model can load at a smaller default context, and a just-in-time load uses that default. Set the context length in LM Studio's load settings, or load from the command line with `lms load <model> --context-length 32768` (section 2 has the full command).
- Network access on the first launch: the plugin runs a pinned copy of houtini-lm through `npx`, which downloads it into the npx cache once and works offline from then on. Behind a proxy, pre-warm the cache once (see [First launch is slow or times out](#first-launch-is-slow-or-times-out)).
- Claude Code.
- At least one folder of files for the local model to read. You choose these folders yourself; the plugin has no default (see [Choose the folders the local model may read](#choose-the-folders-the-local-model-may-read)).

## Bulk jobs

Ask explicitly: “Run a local batch over the logs in /path/to/logs to extract ERROR lines and their stated causes with quotes.” Ordinary requests never trigger the batch skill. Automatic routing was measured at 14–17 Claude turns and $0.19–0.44 on 60 tickets; [results D](docs/results.md#d-unprompted-batch-routing) explains the decision.

In an interactive session, Claude writes the job JSON to a scratch file with Write, lists inputs to expand globs into explicit paths, then starts the runner in the background with `--job <file>`. This avoids inline-JSON shell quoting. Claude reads the returned `index.md` and checks only rows the answer depends on, without re-reading the inputs.

For the same job outside Claude, save this as `/tmp/local-job.json`:

```json
{"prompt":"Find every ERROR line and its stated cause. Cite line L<n> and quote verbatim (at least 12 characters or the whole line). Do not infer causes. Return no rows when none match.","check":"quote-in-line","max_window_chars":20000,"row_schema":{"type":"object","additionalProperties":false,"required":["line","quote","cause"],"properties":{"line":{"type":"string"},"quote":{"type":"string"},"cause":{"type":"string"}}}}
```

Then run (replace the plugin and input paths with yours):

```bash
node "/path/to/claude-local-llm/batch/run.mjs" --job "/tmp/local-job.json" --number "/path/log-a" "/path/log-b"
```

`--job-json '<job JSON>'` is the headless alternative, auto-approved by the plugin hook when the whole command and inputs pass its checks. `--job <file>` uses normal permissions. The two forms are mutually exclusive and validated identically. Omit `--out` to create a fresh private OS temporary directory; the last stdout line gives its absolute `index.md` path. Read the index for counts, no-row windows and failures.

`--number` adds `L<n><TAB>` to raw lines in memory, preserving source line numbers for quote checks. For session JSONL, use `--transcripts` instead; it flattens in memory, cuts blocks at 2000 characters, and reports unparseable lines skipped. Interpretation-heavy jobs use about 20k-character windows. Quote checks establish where evidence occurs, not whether labels are correct or every fact was found.

While a batch runs, it also shows as a lane in Catalyst's band when Catalyst is installed (it writes `~/catalyst/band/lanes/local-<pid>.json` and removes it on exit. With Catalyst present, a failed lane write prints one `local-llm:` stderr line and the run is otherwise unchanged; without Catalyst, nothing is written).

Batch uses Bash's filesystem access. Only pass intended inputs, and keep scratch jobs, transcripts and rows uncommitted. The runner uses `LOCAL_LLM_ENDPOINT_URL` and `LOCAL_LLM_MODEL` for non-default setups; plugin configuration does not reach Bash. The offline delegation self-test retains case l, which guards against single-file batch launches. Case l is in the default paid harness (55 sessions); no paid run is needed for the offline checks.

## 1. Set up LM Studio

Install LM Studio (the steps below were tested with LM Studio 0.4.26), open it once, and run its bundled CLI to confirm it works. The CLI lives at `~/.lmstudio/bin/lms` and may not be on your `PATH`; every command here calls it by that path.

```bash
~/.lmstudio/bin/lms version
```

The model runs on LM Studio's Splash runtime. LM Studio's Settings > Runtime screen has no toggle for it here (it lists "Runtime Selections", an updates channel and extensions), so use the CLI. Check whether Splash is already installed and selected:

```bash
~/.lmstudio/bin/lms runtime ls
```

You want a `splash-...` row with a check mark under `SELECTED`. If there is none, find the engine, install it, then select it:

```bash
~/.lmstudio/bin/lms runtime get splash --list   # shows the engine name and whether you have it; downloads nothing
~/.lmstudio/bin/lms runtime get splash          # downloads it, and prints the exact select line to use
~/.lmstudio/bin/lms runtime select splash-mac-arm64-apple-metal-advsimd --latest
~/.lmstudio/bin/lms runtime ls                  # confirm the check mark
```

Copy the `splash-...` name from `runtime ls` or `get splash --list` rather than typing the one above, which is only the name at the time of writing. `--latest` selects the newest installed version; without it, `select` can fail with "Multiple runtime extensions found" once two versions are installed (see `lms runtime select --help`).

Download the model (Splash supports only specific models, and this is the one the plugin is tested with):

```bash
~/.lmstudio/bin/lms get incoai/Qwen3.6-35B-A3B-Splash
```

The model key afterwards is `qwen3.6-35b-a3b-splash`. `~/.lmstudio/bin/lms ls` lists it.

## 2. Load the model at 32k context and keep it loaded

```bash
~/.lmstudio/bin/lms load qwen3.6-35b-a3b-splash --context-length 32768 --yes
```

Do not pass `--ttl`: without it, LM Studio never unloads the model for being idle. Confirm the load:

```bash
~/.lmstudio/bin/lms ps
```

The `CONTEXT` column should read `32768`.

The model must hold the whole file, instructions and answer. The size hint reads the loaded context from LM Studio and estimates the input cap as `floor((contextTokens - 4096) * 1.6)`: 45,875 characters at 32k tokens, or 98,304 at 64k. The cap is clamped to 1,000,000 characters, matching the file limit. It reserves prompt and answer room using 1.6 chars/token; measured rates are 1.74 for the log fixture and 2.4 for LM Studio logs. Pure numeric data (about 1.0) can still overflow: `context_length_exceeded` fails loudly, and Claude reads the file itself. With several loaded chat models, it uses the smallest context, or the loaded model selected by the plugin's `model` option. Unavailable or invalid metadata falls back to an assumed 32768 tokens (about 45k chars), with a reason in the hint. Other loaded contexts work too; the cap follows them.

Optional hardening, only if you set the plugin's `model` option: just-in-time (JIT) model loading matters only when a request names a model, and the plugin's server (houtini) names one only when `model` is set. With JIT on, naming a model that is not loaded makes LM Studio load it with its default (smaller) context. With JIT off, that request fails with `Invalid model identifier ... just-in-time (JIT) model loading is disabled` instead. With `model` empty (the default) the server uses whichever model is loaded, JIT never applies, and nothing loaded gives `No models loaded` either way. To turn JIT off, use the app's "Just-in-Time Model Loading" switch in the Developer tab's server options, then restart the server. The setting is stored as `justInTimeModelLoading` in `~/.lmstudio/.internal/http-server-config.json`; `lms` has no flag for it.

## 3. Start the server on loopback

```bash
~/.lmstudio/bin/lms server start --port 1234
~/.lmstudio/bin/lms server status
```

`--bind` defaults to `127.0.0.1`, so the server accepts connections from this machine only. Leave it that way: never pass `--bind 0.0.0.0`, which opens the server to your network. The plugin enforces the same rule on its side and refuses to start against a non-loopback `endpoint_url`.

## 4. Install the plugin

Install from the public marketplace:

```bash
claude plugin marketplace add warmlogic/ai-plugin-marketplace
claude plugin install local-llm@ai-plugin-marketplace
```

The plugin then loads in every session, under the id `local-llm@ai-plugin-marketplace`. Its servers will not start until you set `allowed_dirs`, which has no default: see [Choose the folders the local model may read](#choose-the-folders-the-local-model-may-read). The configure commands below use the per-session id `local-llm@inline`. For the marketplace install, run them without `--plugin-dir` and with the installed id, e.g. `claude plugin configure local-llm@ai-plugin-marketplace`.

**Update.** The plugin is unversioned, so every merge to `main` is a release. Refresh the catalog, update the plugin, then restart Claude Code or run `/reload-plugins`:

```bash
claude plugin marketplace update ai-plugin-marketplace
claude plugin update local-llm@ai-plugin-marketplace
```

**Uninstall.**

```bash
claude plugin uninstall local-llm@ai-plugin-marketplace
claude plugin marketplace remove ai-plugin-marketplace
```

The marketplace also lists other plugins; remove it only if you use none of them.

**Try it for one session.** Clone the repo and point Claude Code at it:

```bash
git clone https://github.com/warmlogic/claude-local-llm.git "$HOME/github/claude-local-llm"
claude --plugin-dir "$HOME/github/claude-local-llm"
```

`--plugin-dir` shows no setup prompt, and `allowed_dirs` has no default, so the plugin's servers will not start until you set it: see [Choose the folders the local model may read](#choose-the-folders-the-local-model-may-read). `--plugin-dir` loads the plugin for that session only, so pass it each time.

The plugin has four options (declared as `userConfig` in `.claude-plugin/plugin.json`):

| Option | Default | Meaning |
| --- | --- | --- |
| `allowed_dirs` | none (required) | The folders the local model may read. Nothing outside them is readable *by the local model*. Folder rules: [Choose the folders](#choose-the-folders-the-local-model-may-read). |
| `endpoint_url` | `http://127.0.0.1:1234` | The LM Studio server's root. Must be loopback, with no path, query or fragment. |
| `model` | empty | A model id to request. Empty means whichever model LM Studio has loaded. |
| `delegate_tasks` | empty (off) | Comma-separated read-only task kinds to delegate unprompted: `classify`, `extract`, `summarize`, `draft`. Add `summarize` only for a local model whose summaries have been measured as reliable. Unknown kinds are ignored with a stderr note; empty or all-unknown disables delegation instructions while keeping oversized-file warnings. |

### Choose the folders the local model may read

`allowed_dirs` is the only option you must set, and it has no default. Set it to the folders where your big logs and documents live, and no wider: it is the only boundary on what the local model reads. Claude Code's `Read(...)` deny rules do not apply to the plugin's tools, so a file you have denied to Claude is still readable through the local model if it sits inside `allowed_dirs`, and the model's answer reaches Claude. Keep private folders out of it.

Each folder must be an absolute path to a directory other than `/` (a leading `~`, `$HOME` or `${HOME}` is expanded). No folder name may contain `,` or `:`, and no path may start or end with whitespace, in the path you enter or in its real path after symlinks. A folder that does not exist is skipped with a warning; if none exists, the servers refuse to start.

Anything under these folders can reach Claude's context with no permission prompt: the local model's answers and batch rows are returned to Claude, and a file's content can steer what gets asked. Do not include folders that hold secrets (`.env` files, credentials, keys).

Until it is set, Claude Code does not start the plugin's servers: `/mcp` shows them failed with `Plugin option "allowed_dirs" isn't set`, and the plugin's tools do not exist. Set it any one of these ways, then restart Claude Code:

- **The prompt.** Claude Code asks for the plugin's options when you enable it, and its dialog does not accept an empty value for a required option. A `--plugin-dir` session has no enable step and so no prompt; use one of the next two.
- **The `/plugin` UI.** Open `/plugin`, pick the plugin, and choose its configuration.
- **`claude plugin configure`.** Run it with the plugin's id (`local-llm@ai-plugin-marketplace` for the marketplace install above, `local-llm@inline` with `--plugin-dir`) to see the options and which are unset. For a `--plugin-dir` session, pass the same flag:

```bash
claude --plugin-dir "$HOME/github/claude-local-llm" plugin configure local-llm@inline
```

To save values, pipe a JSON object of strings to the same command with `--values-stdin`. A list of folders is one comma-separated string:

```bash
printf '%s\n' '{"allowed_dirs": "$HOME/logs,$HOME/projects"}' |
  claude --plugin-dir "$HOME/github/claude-local-llm" plugin configure local-llm@inline --values-stdin
```

This writes `pluginConfigs["local-llm@inline"].options` in `~/.claude/settings.json`. Restart Claude Code to apply it. The same command works for `endpoint_url`, `model` and `delegate_tasks`. To opt in to unprompted classification and extraction:

```bash
printf '%s\n' '{"delegate_tasks":"classify,extract"}' |
  claude --plugin-dir "$HOME/github/claude-local-llm" plugin configure local-llm@inline --values-stdin
```

Save `{"delegate_tasks":""}` to turn it off again. Existing saved options take precedence over the new default. With no hint naming task kinds, the skill delegates only when you explicitly ask for the local model. Add `summarize` only after measuring reliable summaries from your loaded model.

## 5. Permissions: nothing to configure

The plugin ships what it needs, so you do not add an allow rule.

- A `PreToolUse` hook (`hooks/hooks.json`, `scripts/approve-own-tools.mjs`) approves the exact skills `local-llm:delegate-local` and `local-llm:batch-local`, the read-only tools `mcp__plugin_local-llm_local-llm__code_task_files` and `mcp__plugin_local-llm_local-verify__verify_claims`, and whole Bash commands invoking `node "<resolved plugin root>/batch/run.mjs" <args>`. Approval requires `--job-json` and every input realpathed into `allowed_dirs`, with `--number` as the only optional flag. `--transcripts`, `--out`, `--job` and the manual flattener CLI get no automatic approval: they go through the normal permission prompt, since transcripts hold copies of files from past sessions. The hook also approves a Read of the runner's own `index.md`, `rows.jsonl`, `dropped.jsonl` or `failures.jsonl` when the file is in a `local-llm-batch-XXXXXX` dir that `mkdtemp` made directly under the OS tmpdir: mode 0700, owned by you, no symlinks or hardlinks. This assumes the hook and the Bash tool share one `TMPDIR`; where they differ (sandbox mode), the Read falls back to a prompt.
- The skill's `allowed-tools` line covers `code_task_files` for the turn that loads the skill.
- A `UserPromptSubmit` hook (`scripts/size-hint.mjs`) stats files named in your prompt, using bytes as a char proxy. From 30,000 bytes through the loaded context cap it instructs Claude to invoke the skill for exactly the known kinds configured in `delegate_tasks` (default empty: no delegation instruction); above the cap it says to Grep or Read relevant slices, or use `batch/run.mjs` when you explicitly request a local batch over multiple files. Files that together exceed the cap get one call per file. Below 30,000 it is silent. It reads no file contents and queries loopback context metadata at most once per eligible prompt, with a 1-second timeout and a 32k-token fallback.
- The skill sends Claude to the Read and Grep tools for the rest, because compound shell commands can still prompt in any session.

## Privacy and security

- **The local model's inference never leaves your machine.** The model runs in LM Studio on loopback, and the launcher refuses any `endpoint_url` that is not `127.0.0.1`, `localhost`, or `[::1]`, so the file is never sent to a remote model server.
- **Some text still reaches Claude.** The model's answer does, and an extraction answer can quote the file verbatim. When Claude spot-checks a fact it runs a narrow Grep for a specific pattern, which returns a few matching lines. `allowed_dirs` limits only the local model. When the local model cannot do a job (LM Studio down, a path outside `allowed_dirs`, a file too large, a bad answer), Claude reads the file itself with its own tools and permissions, wherever Claude Code is allowed to read. Do not ask for jobs on files you would not show Claude. To keep a folder from Claude entirely, leave it out of `allowed_dirs` and add `Read(...)` deny rules for it; the deny rules cover Claude's own tools, `allowed_dirs` covers the local model's.
- **One outbound call carries the model id.** At startup, and every 7 days per model, houtini-lm (the MCP server the plugin pins) asks `huggingface.co` for the loaded model's metadata, which sends the model id (for example `incoai/Qwen3.6-35B-A3B-Splash`), never file text. Houtini 3.3.4 has no setting to turn this off. So the claim is "the file is never sent to a remote model server", not "nothing leaves the machine". Houtini also keeps a cache at `~/.houtini-lm/model-cache.db`.
- **The version pin covers houtini-lm's own code, not its dependencies.** `@modelcontextprotocol/sdk` is a version range resolved at the first `npx` launch (houtini-lm ships no shrinkwrap), and the npx cache keeps that resolution until it is cleared. This residual exposure is accepted. When bumping the pin, maintainers re-check its dependency ranges with `npm view @houtini/lm@<pin> dependencies`.
- **The API key is a dummy.** LM Studio needs no key. The launcher sets `HOUTINI_LM_API_KEY=not-needed` because otherwise houtini falls back to `OPENROUTER_API_KEY` from your environment and would use it as the credential. The launcher also clears the other environment variables houtini reads, so nothing ambient changes its routing.
- **The local model's reads are fenced to `allowed_dirs` and read-only.** Every path is resolved through symlinks before it is compared with the roots, so these are refused: a path outside the roots (`outside the allowed roots`), a symlink that points out of a root, a sibling folder that shares a prefix (`repo-evil` next to `repo`), and any file over 1 MB. The launcher also refuses to start with no usable root, with `/` as a root, or with a relative path, because houtini reads any absolute path when its roots are unset.
- **Output is treated as data.** The skill tells Claude to ignore any instructions it finds in the local model's answer or in the file.

## Smoke test

Make a file of about 35k characters in a folder inside one of your `allowed_dirs`, and start Claude Code from that folder. The commands below use `$HOME/github`; if it is not in your `allowed_dirs`, use one of your folders instead.

```bash
mkdir -p "$HOME/github/local-llm-smoke"
cd "$HOME/github/local-llm-smoke"
for i in $(seq 1 700); do printf '2026-10-16 10:00:%02d INFO job %d finished in %d ms\n' $((i % 60)) "$i" $((i * 7 % 900)); done > smoke.log
wc -c smoke.log
claude --plugin-dir "$HOME/github/claude-local-llm" "Use the delegate-local skill to classify $PWD/smoke.log by log type."
```

`wc -c` should report about 35k. The shell fills in the absolute path, and the prompt names the skill, so this tests your setup rather than Claude's choice to delegate. Asking plainly ("Use the local model to classify ...") works too. If Claude Code asks whether you trust the folder, accept it (it asks the first time you start in a folder).

Success looks like this:

- Claude loads the `delegate-local` skill and calls `code_task_files` without a permission prompt. To see the tool result, open the transcript view (`ctrl+o`).
- The result contains a footer such as `Model: qwen3.6-35b-a3b-splash | 13226→130 tokens | TTFT: 4355ms, 148.7 tok/s, 5.2s | unknown · 1 file(s) read`.
- Claude's reply says the local model produced the classification.

Optional: after opting in with `delegate_tasks=classify,extract`, to see whether Claude delegates unprompted, repeat with "Classify $PWD/smoke.log by log type." That depends on the model's judgment, so it is probabilistic; a miss is not a setup failure. Clean up when you are done: `rm -r "$HOME/github/local-llm-smoke"`.

## Troubleshooting

### The server does not connect, or `/mcp` shows it failed

If `/mcp` instead says `Plugin option "allowed_dirs" isn't set`, Claude Code never launched the server: set `allowed_dirs` ([Choose the folders](#choose-the-folders-the-local-model-may-read)) and restart. Otherwise the launcher exits with status 2 and a reason before houtini starts. These are the refusals:

| Message starts with | Cause and fix |
| --- | --- |
| `local-llm: node (Node.js) is required` / `npx (Node.js) is required` | Install Node.js so both are on the `PATH` Claude Code sees. |
| `local-llm: no allowed folders configured` | `allowed_dirs` is empty. Set it ([Choose the folders](#choose-the-folders-the-local-model-may-read)) and restart Claude Code. |
| `local-llm: allowed folder must not contain ':'` | Rename the folder or pick another; see the folder rules in [Choose the folders](#choose-the-folders-the-local-model-may-read). |
| `local-llm: endpoint must be loopback` | `endpoint_url` must be `http(s)://` with host `127.0.0.1`, `localhost`, or `[::1]`, no user info, an optional numeric port, and nothing after it but an optional `/`: a server root such as `http://127.0.0.1:1234`, not `http://127.0.0.1:1234/v1`. |
| `local-llm: none of the allowed folders exist` | Every folder in `allowed_dirs` is missing. Fix the paths. |
| `local-llm: allowed folder must be an absolute path` | Use absolute paths ([folder rules](#choose-the-folders-the-local-model-may-read)). A comma splits a folder name in two, and the fragment after the comma is what the message names, as a relative path: `/a/b,c` is read as `/a/b` and `c`. Rename the folder. |
| `local-llm: allowed folder has leading/trailing whitespace`, `... is not a directory`, `cannot resolve allowed folder`, `refusing '/'` | Fix the entry named in the message. |
| `local-llm: resolved folder would be altered by houtini's split/trim` | The folder's real path (after symlinks) contains `,` or `:` or edge whitespace. Use a folder whose real path does not. |
| `local-llm: HOME is not an absolute path` | A `$HOME` or `~` entry needs `HOME` set to an absolute path in the environment Claude Code runs in. |
| `local-llm: cannot enter the plugin directory` | The plugin folder moved or is unreadable. Re-clone it or fix its permissions. |

The second server, local-verify, starts through its own launcher with the same folder and endpoint checks. Its folder refusals are the `local-llm:` messages above; its own checks start with `local-verify:`, such as `local-verify: endpoint must be loopback` and, when the server is started without its launcher while a proxy variable is defined, `local-verify: refusing to start`.

### Where to read the server's stderr

Claude Code saves each MCP server's stderr under `~/Library/Caches/claude-cli-nodejs/<project>/mcp-logs-plugin-local-llm-local-llm/` (local-verify's in `mcp-logs-plugin-local-llm-local-verify/` beside it), one `.jsonl` file per start, where `<project>` is the folder you launched `claude` from with its slashes and dots turned into dashes. The refusal messages above are in the `Server stderr:` entries. `claude --debug` also prints them.

### The `allowed folders:` line

On a healthy start, stderr shows `local-llm: allowed folders: <comma-separated resolved paths>`. This is the exact set the model can read, after symlinks are resolved. A folder that does not exist is skipped with `local-llm: allowed folder not found, skipping: <path>`, and the server starts as long as one folder remains. If a folder you expected is missing from the line, that is why: check the path for a typo.

### First launch is slow or times out

On a cold `npx` cache the first start downloads `@houtini/lm`, which needs network and can take a few seconds. If Claude Code reports the server timed out, run `/mcp` and reconnect. Later starts use the cache.

Behind a proxy that first download fails, because the launcher clears the proxy variables (a proxy would otherwise also carry the local model's traffic, file text included). Pre-warm the cache once from a shell that still has the proxy set, outside any project with a `node_modules`: `npx -y @houtini/lm@3.3.4 </dev/null` (it starts, sees no input and exits). Later starts use the cache.

### `outside the allowed roots` (or `READ FAILED`)

The file is not under any folder in `allowed_dirs`. Add its folder in the plugin options, or the symlink you used points elsewhere. If the folder is already listed, check the server log for `allowed folder not found, skipping` (a typo in the path). Claude will read the file itself in the meantime and tell you why.

### `context_length_exceeded`

The file does not fit the model's context. Check `~/.lmstudio/bin/lms ps` and the size hint's cap. Claude should split inputs above that cap or read slices. The cap estimates chars from tokens, so digit-dense text or large instructions can still overflow; Claude reads the file itself on that error. If the hint assumes a 32k context, check its metadata failure reason and that the endpoint exposes `/api/v0/models`. Select a loaded model with the plugin's `model` option. A pin that is absent or unloaded is reported as `pinned model not loaded`.

### `Error: fetch failed`, `No models loaded`, or `Invalid model identifier`

LM Studio is not serving, or no model is loaded. `Invalid model identifier ... just-in-time (JIT) model loading is disabled` means the `model` option names a model that is not loaded while JIT is off: load that model (step 2) or clear the option. (If the `code_task_files` tool is missing from Claude's tool list instead, the plugin's server failed to start, which is not an LM Studio problem: see [the server does not connect](#the-server-does-not-connect-or-mcp-shows-it-failed) and its refusal table and log.) Run `~/.lmstudio/bin/lms server status` and `~/.lmstudio/bin/lms ps`, then start the server and load the model (steps 2 and 3). When this happens Claude does the job itself by reading the whole file with its Read tool, and the final reply of that turn tells you the cause and how to retry. Later turns in the same session answer without mentioning it and do not call the local model again, so after you fix LM Studio, tell Claude to "try the local model again". Treat this as best-effort behavior from the skill's instructions, not a guarantee.

### Claude never delegates

This is the default: `delegate_tasks` is empty because real-file delegation produced fewer usable answers (4/10 vs 8/10) and cost 3% more. Ask explicitly ("use the local model to classify …") to test your setup, or save `{"delegate_tasks":"classify,extract"}` to opt in. Unprompted delegation then applies only to the kinds named by the size hint, from about 30k characters through the loaded context cap. Inputs above the cap should be split or read directly; many-file and mining jobs use `batch/run.mjs` only on an explicit local-model or batch/local request.

## Swapping the server

The model server is a swap seam. The skill keeps every houtini-specific name (tool name, footer fields, error strings, the `allowed-tools` line) in one table in `skills/delegate-local/SKILL.md`. To use a different MCP server, change that table and the `allowed-tools` line, the `command` in `.mcp.json`, and the launcher's environment. The launcher's fence checks exist because houtini fails open without its roots variable; a replacement needs an equivalent fence. Pointing at a different model in LM Studio needs no code change: load it and set the `model` option.

## Development

`AGENTS.md` is the contributor guide: layout, design decisions, and why each safety check exists. Run the suite before committing:

```bash
bash tests/test-fence.sh
```

It needs `node`, `jq`, and `curl`. Cases that need a model skip themselves when LM Studio is unreachable. `tests/test-delegation.sh` runs real `claude -p` sessions and costs quota, so it is not part of the per-commit suite.

## License

See `LICENSE`.
