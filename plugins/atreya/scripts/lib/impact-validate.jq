# impact-validate.jq: checks Claude's analysis (references/impact-facts-schema.md)
# against the script facts, before impact-render.sh merges it.
#   jq --slurpfile Af draft.json --argjson modids '["auth",...]' -f impact-validate.jq impact-facts.json
# Prints {errors: [...], cites: [Verified Repo:path:line to check], reports: [...], refs: [...]}.
# The file checks (citations exist, QA reports exist, requirement IDs exist) are
# done by impact-render.sh with these lists.
. as $F | $Af[0] as $A |
def classes: ["Verified", "Inferred", "Assumption", "Unknown", "Not affected"];
def at($p): $p | map(tostring) | join(".");
def arr($k): ($A[$k] // []) | if type == "array" then . else [] end;
def nonempty: type == "string" and (gsub("\\s"; "") | length) > 0;
def dups: group_by(.) | map(select(length > 1) | .[0]);
def allowed_top: ["input", "requirement", "summary", "module_notes", "added_modules", "not_affected", "workflow", "data_fields",
                  "data_consistency", "risks", "qa_scenarios", "traceability", "open_questions", "assumptions", "actions"];
def script_rules: ["MONEY-01", "MONEY-02", "MONEY-03", "CRIT-01", "CRIT-02", "SEC-01", "DATA-01", "DATA-02", "DATA-03", "DATA-04",
                   "DEP-01", "DEP-02", "DEP-03", "CALL-01", "EXT-01"];
[$F.modules[].id] as $fm | [arr("added_modules")[].id] as $am | ($fm + $am) as $known |
($known + [$F.not_affected[].id]) as $checked |
[arr("open_questions")[].id] as $qids | [arr("assumptions")[].id] as $aids |
[arr("qa_scenarios")[].id] as $sids | [arr("risks")[].id] as $rids | [arr("workflow")[].step] as $steps |
([$F.risks[].id] + $rids) as $allrisks |
def refok($x): ($qids + $aids + $sids + $allrisks + ($steps | map("step \(.)")) + $known) | index($x) != null;
def isstep: . as $s | $steps | index($s) != null;

if ($A | type) != "object" then {errors: ["the analysis must be a JSON object"], cites: [], reports: [], refs: []} else
{errors: [
  ($A | keys[] | select(. as $k | allowed_top | index($k) | not) |
     if . == "review" or . == "status" then "\(.): the review status is set by a human, never by the analysis"
     else "\(.): not a known analysis section (\(allowed_top | join(", ")))" end),
  # ---- input and requirement
  (if (["zoho", "free-text"] | index($A.input.source // "")) == null then "input.source must be \"zoho\" or \"free-text\"" else empty end),
  (if $A.input.source == "zoho" and (($A.input.id // "") | test("^[A-Za-z0-9._-]+$") | not) then "input.id must be the Zoho Sprints item id" else empty end),
  (if $A.input.source == "zoho" and $A.input.id != $F.ticket then "input.id \($A.input.id) is not the ticket \($F.ticket)" else empty end),
  (if $A.input.source == "free-text" and ($F.ticket | startswith("adhoc-") | not) then "free-text input needs an adhoc-<slug> ticket (got \($F.ticket))" else empty end),
  (if ($A.input.title // "" | nonempty | not) then "input.title is empty" else empty end),
  (if ($A.input.text // "" | nonempty | not) then "input.text is empty (quote the ticket or the free text)" else empty end),
  (if ($A.summary.headline // "" | nonempty | not) then "summary.headline is empty" else empty end),
  (if (($A.requirement.proposed // []) | length) == 0 and (($A.requirement.missing // []) | length) == 0
   then "requirement.proposed is empty: state the proposed behaviour, or list what is missing under requirement.missing with a question" else empty end),
  (($A.requirement.ambiguities // []) + ($A.requirement.missing // []) | .[] | select((.question // "") as $q | $qids | index($q) | not) |
     "requirement: \"\(.text // "?")\" needs a question id from open_questions (got \(.question // "none"))"),
  # ---- evidence on every statement
  ($A | paths(type == "object" and has("evidence")) as $p | ($A | getpath($p)) as $o | $o.evidence as $e |
    if ($e | type) != "object" then "\(at($p)): evidence must be an object {class, cites}"
    elif (classes | index($e.class)) == null then "\(at($p)): evidence class \"\($e.class)\" is not one of \(classes | join(", "))"
    elif ($e.cites // [] | type) != "array" then "\(at($p)): evidence.cites must be a list"
    elif $e.class == "Verified" and ($e.cites | length) == 0 then "\(at($p)): Verified needs a Repo:path:line citation"
    elif $e.class == "Verified" and any($e.cites[]; (test("^[A-Za-z0-9_.-]+:[^ :]+(:[0-9]+([,-][0-9]+)*)?$") or (. == "Zoho Sprints \($F.ticket)" and $A.input.source == "zoho")) | not)
      then "\(at($p)): Verified accepts only Repo:path:line citations (or \"Zoho Sprints \($F.ticket)\" for a Zoho item)"
    elif $e.class == "Inferred" and ($e.cites | length) == 0 then "\(at($p)): Inferred must cite what it was derived from (code, facts:<key>, Zoho)"
    elif $e.class == "Assumption" and (($e.assumption // "") as $a | $aids | index($a) | not) then "\(at($p)): an Assumption must name its entry in assumptions (evidence.assumption)"
    elif ($e.class == "Unknown" or $e.class == "Not affected") and ($e.note // "" | nonempty | not) then "\(at($p)): \($e.class) needs evidence.note (why)"
    else empty end),
  ($A | paths(type == "object" and has("evidence")) as $p | ($A | getpath($p)) | .evidence.cites // [] | .[] | select(startswith("facts:")) |
     select(.[6:] | split(".")[0] as $k | $F | has($k) | not) | "\(.): no such key in impact-facts.json"),
  # ---- modules
  ($A.module_notes // {} | keys[] | select(. as $m | $known | index($m) | not) | "module_notes.\(.): not an affected module in the facts (add it to added_modules with evidence, or remove it)"),
  (arr("added_modules")[] | select(. as $x | $modids | index($x.id) | not) | "added_modules: \(.id) is not a module in modules.yaml"),
  (arr("added_modules")[] | select(. as $x | $fm | index($x.id)) | "added_modules: \(.id) is already in the facts"),
  (arr("added_modules")[] | select(.why // "" | nonempty | not) | "added_modules: \(.id) needs a why"),
  (arr("not_affected")[] | . as $n | $F.modules[] | select(.id == $n.id) |
     "not_affected: \(.id) contradicts the facts (\(.role) module: \(.why[0])); keep it and explain in module_notes, or ask in open_questions"),
  (arr("workflow")[] | select(.module != null and .module != "" and (.module as $m | $checked | index($m) | not)) | "workflow step \(.step): unknown module \(.module)"),
  (arr("qa_scenarios")[] | select(.module != null and .module != "" and (.module as $m | $checked | index($m) | not)) | "\(.id): unknown module \(.module)"),
  # ---- workflow
  ($steps | dups[] | "workflow: step \(.) appears twice"),
  (arr("workflow")[] | select((.step | type) != "number") | "workflow: step numbers must be numbers"),
  (arr("workflow")[] | select((.actor // "" | nonempty | not) or (.before // "" | nonempty | not) or (.after // "" | nonempty | not) or (.on_failure // "" | nonempty | not)) |
     "workflow step \(.step): actor, before, after and on_failure are required"),
  # ---- risks: Claude adds or raises, never lowers
  ($rids | dups[] | "risks: \(.) appears twice"),
  (arr("risks")[] | select(.id | test("^RA-[0-9]{2,}$") | not) | "risks: id \(.id) must look like RA-01"),
  (arr("risks")[] | select((.level as $v | ["Critical", "High", "Medium", "Low"] | index($v)) == null) | "\(.id): level must be Critical, High, Medium or Low"),
  (arr("risks")[] | select((.rule // "") as $r | (script_rules + ["FAIL-01", "FAIL-02", "FAIL-03", "FAIL-04"]) | index($r) | not) |
     "\(.id): rule must be one of references/impact-risk-rules.md (FAIL-01..04 for failure consequences)"),
  (arr("risks")[] | select(.rule as $r | ["FAIL-01", "FAIL-02", "FAIL-03", "FAIL-04"] | index($r)) |
     select(.level != {"FAIL-01": "Critical", "FAIL-02": "High", "FAIL-03": "Medium", "FAIL-04": "Low"}[.rule]) | "\(.id): \(.rule) has a fixed level (see impact-risk-rules.md)"),
  (arr("risks")[] | select(.raises != null and (.raises as $r | [$F.risks[].id] | index($r) | not)) | "\(.id): raises \(.raises), which is not a script risk"),
  (arr("risks")[] | select(.raises != null) | . as $a | $F.risks[] | select(.id == $a.raises) |
     select(({"Critical": 4, "High": 3, "Medium": 2, "Low": 1}[$a.level]) <= ({"Critical": 4, "High": 3, "Medium": 2, "Low": 1}[.level])) |
     "\($a.id): raises \(.id) but is not higher (\($a.level) vs \(.level)); a risk can only be raised, never lowered: ask in open_questions"),
  (arr("risks")[] | select((.reason // "" | nonempty | not) or (.consequence // "" | nonempty | not)) | "\(.id): reason and consequence are required"),
  (arr("risks")[] | select(has("evidence") | not) | "\(.id): evidence is required"),
  # ---- QA: never "executed" without evidence
  ($sids | dups[] | "qa_scenarios: \(.) appears twice"),
  (arr("qa_scenarios")[] | select(.id | test("^QA-[0-9]{2,}$") | not) | "qa_scenarios: id \(.id) must look like QA-01"),
  (arr("qa_scenarios")[] | select((.type as $v | ["positive", "negative", "boundary", "integration"] | index($v)) == null) | "\(.id): type must be positive, negative, boundary or integration"),
  (arr("qa_scenarios")[] | select((.origin as $v | ["existing", "suggested"] | index($v)) == null) | "\(.id): origin must be existing or suggested"),
  (arr("qa_scenarios")[] | select(.status != "Not run") |
     if (.status as $v | ["Passed", "Failed", "Blocked"] | index($v)) == null then "\(.id): status \"\(.status)\" is not allowed (Not run, or Passed/Failed/Blocked with a QA report)"
     elif (.evidence.report // "" | nonempty | not) then "\(.id): status \(.status) needs evidence.report (a QA report file); nothing was executed by this analysis"
     else empty end),
  (arr("qa_scenarios")[] | select(.origin == "existing") | select((.trace // []) | length == 0 or any(.[]; . as $t | [$F.qa_scope.existing[].ref] | index($t) | not)) |
     "\(.id): an existing scenario must trace to an existing test or acceptance criterion in qa_scope.existing"),
  (arr("qa_scenarios")[] | select(.step != null and (.step | isstep | not)) | "\(.id): workflow step \(.step) does not exist"),
  (arr("qa_scenarios")[] | select((.title // "" | nonempty | not) or (.expected // "" | nonempty | not)) | "\(.id): title and expected are required"),
  # ---- questions, assumptions, cross references
  ($qids | dups[] | "open_questions: \(.) appears twice"),
  (arr("open_questions")[] | select(.id | test("^Q[0-9]+$") | not) | "open_questions: id \(.id) must look like Q1"),
  (arr("open_questions")[] | select((.role as $v | ["PO", "Dev", "QA", "Owner"] | index($v)) == null) | "\(.id): role must be PO, Dev, QA or Owner"),
  (arr("open_questions")[] | select(.question // "" | nonempty | not) | "\(.id): question is empty"),
  (arr("open_questions")[] | (.blocks // [])[] as $b | select(refok($b) | not) | "\(.id): blocks \($b), which does not exist"),
  ($aids | dups[] | "assumptions: \(.) appears twice"),
  (arr("assumptions")[] | select(.id | test("^A[0-9]+$") | not) | "assumptions: id \(.id) must look like A1"),
  (arr("assumptions")[] | select(.text // "" | nonempty | not) | "\(.id): text is empty"),
  (arr("assumptions")[] | (.affects // [])[] as $b | select(refok($b) | not) | "\(.id): affects \($b), which does not exist"),
  (arr("data_consistency")[] | select(.risk != null and (.risk as $r | $allrisks | index($r) | not)) | "data_consistency: risk \(.risk) does not exist"),
  (arr("actions")[] | select((.text // "" | nonempty | not) or ((.role as $v | ["PO", "Dev", "QA", "Owner"] | index($v)) == null)) | "actions: each needs text and a role (PO, Dev, QA, Owner)")
 ],
 cites: ([$A | .. | objects | select(has("evidence")) | .evidence | objects | select(.class == "Verified") | .cites // [] | .[] | strings
          | select(test("^[A-Za-z0-9_.-]+:[^ :]+(:[0-9]+([,-][0-9]+)*)?$"))] | unique),
 reports: ([arr("qa_scenarios")[] | .evidence.report // empty] | unique),
 refs: ([(arr("qa_scenarios")[] | .trace // [] | .[]), (arr("traceability")[] | .ref)] | unique)}
end
