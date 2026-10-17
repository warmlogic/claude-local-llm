# Mechanical checks on one answer, run before the judge. Input: the answer text.
# Args: $task ("summary"|"classification"|"extraction"), $file (the file's text), $labels (array).
# Output: {ok, reason, extra_text}. A reason names a field, never file text, so it is safe to commit.
# JSON answers: one ```json fence is stripped; when the whole reply still does not parse, the span from the first
# "{" to the last "}" is tried, and extra_text is set (a trailing "summarized by the local model" note, say).
# "Verbatim" means a substring of the file after collapsing every whitespace run to one space.

def collapse: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
def obj_or_null: if type == "object" then . else null end;
def parse_obj:
  sub("^\\s+"; "") | sub("\\s+$"; "") as $s
  | (first($s | capture("^```(?:json)?[ \\t]*\\n(?<b>[\\s\\S]*?)\\n?```$") | .b) // $s) as $u
  | ((try ($u | fromjson) catch null) | obj_or_null) as $j
  | if $j != null then {j: $j, extra: false}
    else {j: ((first($s | capture("(?<o>\\{[\\s\\S]*\\})") | .o) // "") as $o | (try ($o | fromjson) catch null) | obj_or_null), extra: true}
    end;
def isstr: type == "string";

($file | collapse) as $F
| def vb: . as $q | isstr and ($q | collapse | length) > 0 and ($F | contains($q | collapse));
  (if type != "string" or (collapse | length) == 0 then {ok: false, reason: "empty answer", extra_text: false}
   elif $task == "summary" then {ok: true, reason: null, extra_text: false}
   else parse_obj as $p | $p.j as $j
   | (if $j == null then "not a JSON object"
      elif $task == "classification" then
        if ($j.kind | isstr | not) or ($labels | index($j.kind)) == null then "kind not in the label set"
        elif ($j.topic | isstr | not) then "topic missing"
        elif ($j.evidence | vb | not) then "evidence not verbatim"
        else null end
      elif $task == "extraction" then
        if ($j | keys) != (["first_date", "key_items", "last_date", "subject"]) then "fields are not exactly subject, first_date, last_date, key_items"
        elif ($j.subject | isstr | not) then "subject not a string"
        elif any($j.first_date, $j.last_date; . != null and (isstr | not)) then "a date is neither a string nor null"
        elif ($j.first_date != null and ($j.first_date | vb | not)) then "first_date not verbatim"
        elif ($j.last_date != null and ($j.last_date | vb | not)) then "last_date not verbatim"
        elif ($j.key_items | type) != "array" or ($j.key_items | length) == 0 or ($j.key_items | length) > 5 then "key_items is not an array of 1 to 5 items"
        elif any($j.key_items[]; type != "object" or (.quote | isstr | not) or (.why | isstr | not)) then "a key item lacks a string quote and why"
        else ([$j.key_items | to_entries[] | select(.value.quote | vb | not) | "key_items[\(.key)].quote not verbatim"] | first // null)
        end
      else "unknown task \($task)" end) as $why
   | {ok: ($why == null), reason: $why, extra_text: $p.extra}
   end)
