# AGENTS.md — local-llm developer guide

This is the canonical contributor guide, at the repo root. `.claude/CLAUDE.md` is a symlink to this file, so Claude Code loads the same content as project memory.

Claude Code plugin that runs a small MCP server (houtini-lm, pinned) backed by a model running locally in LM Studio. Text in, text out, loopback only, fenced read-only file access. The main session calls the plugin's tools directly, guided by a skill.

## Running tests

```bash
bash tests/test-fence.sh   # must pass before committing
```

Tests drive `scripts/launch-server.sh` over stdio MCP JSON-RPC (`tests/mcp-call.mjs`, node stdlib; `tests/fake-endpoint.mjs` is a loopback stand-in for LM Studio) using `mktemp` roots and generated synthetic fixtures. Needs `node`, `jq`, `curl`. Cases that need a model (happy path, oversized input) print `SKIP` when LM Studio is unreachable at `LOCAL_LLM_ENDPOINT_URL` (default `http://127.0.0.1:1234`); every fence case, the 1 MB cap and endpoint passthrough run without one. The oversized case assumes LM Studio loads the model at a 32k context and fails, not skips, if a 130k-char file is accepted. Scratch dirs under `tests/.tmp-*` are gitignored and removed on exit.

## Project layout

```text
.claude-plugin/
  plugin.json        # name/description/userConfig — unversioned; see "Unversioned" below
.mcp.json            # one server, local-llm: runs scripts/launch-server.sh, passes userConfig via env
scripts/
  launch-server.sh   # validates allowed folders (fail closed), sets HOUTINI_* env, execs the pinned houtini
tests/
  test-fence.sh      # fence + launcher + model-backed cases
  mcp-call.mjs       # minimal stdio MCP client used by the tests
  fake-endpoint.mjs  # loopback HTTP listener that logs request headers (endpoint passthrough test)
```

## Non-obvious design decisions

- **The launcher exists because houtini fails open, and it validates what houtini will use.** With `HOUTINI_LM_FILE_ROOTS` unset or empty, houtini's `code_task_files` reads any absolute path; houtini also splits the variable on `,` and `:` and realpaths each piece, so a raw-string check is not enough (`/repo:archive` adds a cwd-relative `archive`; `//`, `/.` and `/tmp/..` resolve to `/`). `launch-server.sh` therefore trims, expands `$HOME`/`~`, drops empty entries, refuses relative entries and any `:`, resolves each entry with `cd -P` and passes houtini the resolved paths. A resolved `/` is refused; a folder that does not exist (a default missing on this machine) is skipped with a warning; if no folder remains it exits 2 before starting houtini. It logs the resolved roots on stderr at startup. Never launch houtini from `.mcp.json` directly.
- **`allowed_dirs` is a `directory` option with `multiple: true`.** Claude Code joins the array with `,` on `${user_config.allowed_dirs}` substitution, which is one of the separators houtini splits on (`:` or `,`). Consequence: folder names cannot contain `,` or `:`. Defaults (`$HOME/github`, `$HOME/catalyst`) reach the launcher literally, and a headless `--plugin-dir` run applies them without prompting; the launcher expands a leading `$HOME`, `${HOME}` or `~` (Claude Code itself expands only `${HOME}`). The value travels in `LOCAL_LLM_ALLOWED_DIRS`, not argv, so an empty value cannot vanish as an argument.
- **The endpoint must be loopback.** The launcher accepts only `http(s)://` URLs whose host is `127.0.0.1`, `localhost` or `[::1]` (no userinfo), so a misconfigured `endpoint_url` cannot send file contents off-box.
- **Fence semantics are houtini's.** Roots and files are `realpath`ed before comparison, so symlinks out of a root and sibling-prefix directories (`root-evil` next to `root`) are rejected; the rejection never echoes file contents.
- **`HOUTINI_LM_API_KEY=not-needed`.** LM Studio needs no key; setting a dummy stops houtini from falling back to `OPENROUTER_API_KEY` from the user's environment and sending anything off-box.
- **`HOUTINI_LM_STRUCTURED` stays unset.** Plain text output is the contract.
- **`HOUTINI_LM_MAX_FILE_MB=1`** (houtini's minimum) caps a single read well below the context window's reach.
- **`npx -y @houtini/lm@3.3.4` with `npm_config_prefer_offline=true`.** The exact pin keeps the fence code reviewed; the offline preference makes startup hit the npx cache (about 0.4 s warm) instead of the registry. Never pin below 3.3.3: 3.3.0–3.3.2 hid answers from Claude Code. Re-run `tests/test-fence.sh` when bumping the pin. The first launch on a cold npx cache needs network and can take a few seconds; if the server times out, reconnect via `/mcp`. The launcher exits 2 with a clear message when `npx` is missing.
- **Oversized input is a hard error, not a truncated summary.** The limit is the loaded model's context window in tokens, not houtini's byte cap. Dense synthetic text runs about 2.7 chars/token, so ~80k chars (~30k tokens) still fit a 32k context while ~90k+ chars return `Error: Upstream model error mid-stream: ... context_length_exceeded` and no summary. Houtini does not truncate silently. A size check before delegating is still the skill's job, because the error costs a round trip and real prose tokenizes at a different rate.
- **Tool names** for a plugin server are `mcp__plugin_local-llm_local-llm__<tool>` (`code_task_files`, `discover`, ...); use the full name in `allowed-tools` and permission rules.

## Unversioned

This plugin carries no `version` field in `.claude-plugin/plugin.json`. Claude Code keys an unversioned install by the git commit SHA of the source, so every merge to `main` is a release. `claude plugin validate .` warns "No version specified" for this; that one warning is expected and accepted. Don't add a `version` field to silence it.

## Don't edit the plugin cache

The installed copy lives under `~/.claude/plugins/cache/` and is overwritten on plugin update. Edit the source repo and reinstall. To try a change without installing, run `claude --plugin-dir <worktree>`.
