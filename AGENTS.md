# AGENTS.md — local-llm developer guide

This is the canonical contributor guide, at the repo root. `.claude/CLAUDE.md` is a symlink to this file, so Claude Code loads the same content as project memory.

Claude Code plugin that runs a small MCP server (houtini-lm, pinned) backed by a model running locally in LM Studio. Text in, text out, inference over loopback only, fenced read-only file access. The main session calls the plugin's tools directly, guided by a skill.

## Running tests

```bash
bash tests/test-fence.sh   # must pass before committing
```

Tests drive `scripts/launch-server.sh` over stdio MCP JSON-RPC (`tests/mcp-call.mjs`, node stdlib; `tests/fake-endpoint.mjs` is a loopback stand-in for LM Studio) using `mktemp` roots and generated synthetic fixtures. Needs `node`, `jq`, `curl`. Cases that need a model (happy path, oversized input) print `SKIP` when LM Studio is unreachable at `LOCAL_LLM_ENDPOINT_URL` (default `http://127.0.0.1:1234`); every fence case, the 1 MB cap and endpoint passthrough run without one. The oversized case assumes LM Studio loads the model at a 32k context and fails, not skips, if a 130k-char file is accepted. Scratch dirs under `tests/.tmp-*` are gitignored and removed on exit.

`tests/test-delegation.sh` is the delegation acceptance harness and is **not** part of the per-commit suite: every run is a real `claude -p` session and costs quota (five cases at five runs each is about 25 sessions). It loads the plugin with `--plugin-dir`, passes no `--allowedTools`, and checks the stream-json traces with jq: a 20k-char file is delegated unprompted (a), a 2k-char file is read directly (b), a dead endpoint (c) and a no-model endpoint (d, `fake-endpoint.mjs no-model`) fall back to Claude, two jobs against a dead endpoint announce the outage once (e), and `permission_denials` is empty in every run (f). `DELEG_RUNS` (default 5), `DELEG_CASES`, `DELEG_MODEL`, `DELEG_OUT` (trace dir) and `DELEG_SETTING_SOURCES` (default `project`, which keeps the user's own allow rules out of the result) tune a run. Cases a and b need LM Studio at `127.0.0.1:1234`; c to e never touch it. Re-run it after editing `skills/delegate-local/SKILL.md`. Measured at the current skill with the default model: a to d pass 5/5 each; e passes 3/5 (the model narrates "server is down" between tool calls and again in its final reply, and three rewordings made it no better); f fails, with a denied compound `Bash` command (`f=<path>; grep ...`) in about 4 of 25 runs, because Claude verifies with shell commands despite the skill pointing it at Grep. Both are model habits the skill text did not move; the user's own allow rules normally cover the shell commands.

## Project layout

```text
.claude-plugin/
  plugin.json        # name/description/userConfig — unversioned; see "Unversioned" below
package.json         # no dependencies; pins npm's project root to the plugin (see launch-server.sh)
.mcp.json            # one server, local-llm: runs scripts/launch-server.sh, passes userConfig via env
skills/
  delegate-local/SKILL.md  # when and how Claude hands big text jobs to the local model; one table holds every server-specific name
hooks/
  hooks.json         # PreToolUse on Skill: runs scripts/approve-skill.mjs
scripts/
  approve-skill.mjs  # allows this plugin's own skill call, silent for everything else
  launch-server.sh   # fail-closed checks, scrubs and sets HOUTINI_* env, execs the pinned houtini
  resolve-roots.mjs  # resolves allowed folders with houtini's own split/trim/realpath semantics
tests/
  test-fence.sh      # fence + launcher + model-backed cases
  mcp-call.mjs       # minimal stdio MCP client used by the tests
  fake-endpoint.mjs  # loopback HTTP listener that logs request headers; `no-model` mode mimics LM Studio with nothing loaded
  test-delegation.sh # delegation acceptance harness (real claude -p sessions; not in the per-commit suite)
```

## Non-obvious design decisions

- **The launcher exists because houtini fails open, and it validates what houtini will use.** With `HOUTINI_LM_FILE_ROOTS` unset or empty, houtini's `code_task_files` reads any absolute path. Houtini also parses the variable as `split(/[:,]/).map(trim).filter(Boolean)` and `realpathSync`s each piece, so a string check in sh is not enough (`/repo:archive` adds a cwd-relative `archive`; `//` and `/tmp/..` resolve to `/`; a root ending in U+FEFF or NBSP is trimmed into a sibling). `scripts/resolve-roots.mjs` therefore runs in node with houtini's exact parse: it expands `$HOME`/`${HOME}`/`~`, refuses relative entries and any `:`, refuses any entry with leading or trailing whitespace (entries are never trimmed, so padding cannot silently name a sibling folder; Claude Code joins the option with a bare `,`), resolves with `realpathSync.native` (on-disk case, matching houtini's per-file realpath on case-insensitive APFS; houtini's own `realpathSync` returns that result unchanged), and refuses unless houtini's parse of the resolved path yields exactly that path. A resolved `/` is refused; a nonexistent folder (a default missing on this machine) is skipped with a warning, and if every folder was skipped the launcher says none exist; any other resolution error (`EACCES`, `ENOTDIR`, `ELOOP`) or a non-directory exits 2. `launch-server.sh` exits 2 before starting houtini when no folder remains, and logs the resolved roots on stderr. The launcher also requires `node` and `npx`, and `cd`s to the plugin root (`CDPATH` cleared) before resolving and exec'ing. The root's `package.json` pins npm's project root there, so a stray `node_modules` in an ancestor directory cannot win either. Why: Claude Code spawns the server with the session's project dir as cwd, and `npx` runs a matching `@houtini/lm` found in `node_modules` up the cwd's ancestry (and reads a project `.npmrc`), so a repo carrying one would execute its code. Never launch houtini from `.mcp.json` directly.
- **Houtini's other environment variables are scrubbed.** The launcher unsets every `process.env.*` variable houtini 3.3.4 reads (`LM_STUDIO_*`, `OPENROUTER_API_KEY`, `HOUTINI_LM_STRUCTURED`, ...) before exporting the ones it sets, so ambient values cannot change routing or credentials. `tests/test-fence.sh` reads the list from the launcher, checks the environment a stub `npx` receives, and (when a cached 3.3.4 dist exists) fails if the dist reads a variable that is neither scrubbed nor exported; re-derive the list from the dist when bumping the pin.
- **`allowed_dirs` is a `directory` option with `multiple: true`.** Claude Code joins the array with `,` on `${user_config.allowed_dirs}` substitution, which is one of the separators houtini splits on (`:` or `,`). Consequence: folder names cannot contain `,` or `:`. Defaults (`$HOME/github`, `$HOME/catalyst`) reach the launcher literally, and a headless `--plugin-dir` run applies them without prompting; the resolver expands a leading `$HOME`, `${HOME}` or `~` (Claude Code itself expands only `${HOME}`). The value travels in `LOCAL_LLM_ALLOWED_DIRS`, not argv, so an empty value cannot vanish as an argument.
- **The endpoint must be loopback.** The launcher accepts only `http(s)://` URLs whose host is `127.0.0.1`, `localhost` or `[::1]` (no userinfo), so a misconfigured `endpoint_url` cannot send file contents to a remote server. The check covers the inference endpoint only; see the next bullet.
- **Accepted risk: houtini's Hugging Face metadata lookup.** At startup, and again every 7 days per cached model, houtini 3.3.4 sends the loaded model's id (never file text) to `huggingface.co/api/models/...` to fetch model metadata (`dist/model-cache.js`). No setting in 3.3.4 disables it, and the loopback check does not cover it. The accurate claim is therefore "file contents never leave the machine", not "nothing leaves the machine".
- **Fence semantics are houtini's.** Roots and files are `realpath`ed before comparison, so symlinks out of a root and sibling-prefix directories (`root-evil` next to `root`) are rejected; the rejection never echoes file contents.
- **`HOUTINI_LM_API_KEY=not-needed`.** LM Studio needs no key; setting a dummy stops houtini from falling back to `OPENROUTER_API_KEY` from the user's environment.
- **`HOUTINI_LM_STRUCTURED` stays unset.** Plain text output is the contract.
- **`HOUTINI_LM_MAX_FILE_MB=1`** (houtini's minimum) caps a single read well below the context window's reach.
- **`npx -y @houtini/lm@3.3.4` with `npm_config_prefer_offline=true`.** The exact pin keeps the fence code reviewed; the offline preference makes startup hit the npx cache (about 0.4 s warm) instead of the registry. Never pin below 3.3.3: 3.3.0–3.3.2 hid answers from Claude Code. Re-run `tests/test-fence.sh` when bumping the pin. The first launch on a cold npx cache needs network and can take a few seconds; if the server times out, reconnect via `/mcp`. The launcher exits 2 with a clear message when `npx` is missing.
- **Oversized input is a hard error, not a truncated summary.** The limit is the loaded model's context window in tokens, not houtini's byte cap. Dense synthetic text runs about 2.7 chars/token, so ~80k chars (~30k tokens) still fit a 32k context while ~90k+ chars return `Error: Upstream model error mid-stream: ... context_length_exceeded` and no summary. Houtini does not truncate silently. A size check before delegating is still the skill's job, because the error costs a round trip and real prose tokenizes at a different rate.
- **The skill's thresholds are rules of thumb; its table is the swap seam.** `skills/delegate-local/SKILL.md` delegates a bounded text job over roughly 10k to 60k characters: below 10k, reading it is cheaper than the round trip; the 60k ceiling comes from the 32k context and the measured ~2.7 chars/token (80k fits, 90k errors), with margin for real prose, and stays a guess until M2.3 measures it. Claude gets the size from `wc -c` without reading the file. Every houtini-specific name (tool, footer field, error and quality-flag string, the `allowed-tools` line) sits in the skill's one table, taken from houtini 3.3.4's dist; swapping the server edits that table and the frontmatter only. The skill loads into every session, so it stays under 80 lines (`test-fence.sh` checks).
- **Permissions (headless `claude -p`, no `--allowedTools`).** A skill's `allowed-tools` pre-approves the MCP tool for the turn that invokes it (negative control: the same skill without the line has `code_task_files` denied). It cannot approve the `Skill` call that loads it: without a rule that call is denied and the model falls back to calling the tool, which is also denied. A plugin cannot ship allow rules in `settings.json` (only `agent` and `subagentStatusLine` take effect), so `hooks/hooks.json` ships a `PreToolUse` hook on `Skill` that allows exactly `local-llm:delegate-local` and nothing else; deny rules still win. `wc -c` and other read-only shell commands are auto-allowed, but compound or piped shell commands are not, so the skill sends Claude to the Read and Grep tools. Do not run the harness with `disableAllHooks`, which disables that hook; `--setting-sources project` keeps user hooks out instead.
- **Tool names** for a plugin server are `mcp__plugin_local-llm_local-llm__<tool>` (`code_task_files`, `discover`, ...); use the full name in `allowed-tools` and permission rules.

## Unversioned

This plugin carries no `version` field in `.claude-plugin/plugin.json`. Claude Code keys an unversioned install by the git commit SHA of the source, so every merge to `main` is a release. `claude plugin validate .` warns "No version specified" for this; that one warning is expected and accepted. Don't add a `version` field to silence it.

## Don't edit the plugin cache

The installed copy lives under `~/.claude/plugins/cache/` and is overwritten on plugin update. Edit the source repo and reinstall. To try a change without installing, run `claude --plugin-dir <worktree>`.
