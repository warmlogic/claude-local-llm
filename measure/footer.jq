# The only parser of the local server's result footer (the swap seam: swapping the server rewrites this
# file, the skill's names table and .mcp.json). Format, from houtini 3.3.4 dist/index.js formatFooter:
#   <answer>\n\n---\nModel: <id> | <p>→<c> tokens[ (<r> reasoning / <v> visible)][ | <n> prompt tokens cached]
#   | TTFT: <ms>ms[, <x> tok/s][, <s>s] | <lang> · <n>[/<m>] file(s) read[ | Quality: ...][ | ⚠ ...]
# followed by optional benchmark and session lines. <s> is generationMs/1000 and includes the TTFT.
#
# houtini_footer: applied to a tool_result text; returns
#   {model, prompt_tokens, completion_tokens, ttft_ms, tok_s, total_s, files_read, files_total, flags[]}
# or null when the text has no footer. flags holds the bad-answer flags named in the skill's table.

def _num($re): (first(capture($re) | .v | tonumber) // null);

def houtini_footer:
  (if type == "string" then . else "" end) as $t
  | ([$t | split("\n")[] | select(startswith("Model: ") and contains(" | "))] | last) as $line
  | if $line == null or ($t | contains("\n---\n") | not) then null
    else
      ([$line | split(" | ")[] | select(startswith("TTFT: "))] | first // "" | split(", ")) as $perf
      | {
          model: ($line | split(" | ")[0] | ltrimstr("Model: ")),
          prompt_tokens: ($line | _num("(?<v>[0-9]+)→[0-9]+ tokens")),
          completion_tokens: ($line | _num("[0-9]+→(?<v>[0-9]+) tokens")),
          ttft_ms: ($line | _num("TTFT: (?<v>[0-9]+)ms")),
          tok_s: ($line | _num("(?<v>[0-9.]+) tok/s")),
          total_s: ([$perf[] | select(test("^[0-9.]+s$")) | rtrimstr("s") | tonumber] | first // null),
          files_read: ($line | _num("(?<v>[0-9]+)(/[0-9]+)? file\\(s\\) read")),
          files_total: (($line | _num("[0-9]+/(?<v>[0-9]+) file\\(s\\) read")) // ($line | _num("(?<v>[0-9]+) file\\(s\\) read"))),
          flags: [("TRUNCATED", "hit-max-tokens", "PREFILL-STALL", "reasoning-only", "think-strip-empty",
                   "CONTENT-FILTERED", "UPSTREAM ERROR") as $f | select($line | contains($f)) | $f]
        }
    end;
