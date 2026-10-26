# jsscan.awk: AJAX call sites in page JavaScript, with the context that runs them.
# Usage: awk -f jsscan.awk BLADE_FILES... JS_FILES...   (blades first: they
# define base-URL variables such as  const baseURL = "{{ url('/') }}")
# In *.blade.php files only inline <script> blocks (no src=) are read.
# Prints
#   J<TAB>file<TAB>line<TAB>METHOD|?<TAB>url<TAB>ctxkind<TAB>ctxname    a call
#        url: /path (dynamic parts {}) or R:route.name (Blade route() in inline scripts)
#   U<TAB>file<TAB>line<TAB>reason<TAB>ctxkind<TAB>ctxname             URL not resolvable
#   D<TAB>file<TAB>name                                                 function defined
#   X<TAB>file<TAB>line<TAB>name<TAB>ctxkind<TAB>ctxname               bare call name(
# ctxkind: fn (named function), sel (event handler bound to a CSS selector),
# load (document ready / top level: runs when the page loads).
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function nostr(s,   t) { t = s; gsub(/"([^"\\]|\\.)*"|\047([^\047\\]|\\.)*\047|`[^`]*`/, "\"\"", t); sub(/\/\/.*/, "", t); return t }
function cnt(s, ch,   t) { t = s; return gsub(ch, "", t) }
# one URL expression -> "/a\t/b" (several for a ternary), "" if not a URL, "?<reason>" if unresolvable
function resolve(e,   out, t, v, lit, rest, n, parts, i, p) {
  e = trim(e)
  if (e ~ /^["\047`][ \t]*\{\{[ \t]*route\(/) { v = e; sub(/^[^(]*\([ \t]*["\047]/, "", v); sub(/["\047].*/, "", v); return "R:" v }
  if (e ~ /^["\047`][ \t]*\{\{[ \t]*url\(/) { v = e; sub(/^[^(]*\([ \t]*["\047]/, "", v); sub(/["\047].*/, "", v); return norm(v) }
  # ternary: every literal in it
  if (e ~ /\?/ && e ~ /:/ && e !~ /^["\047`]/) {
    out = ""; t = e
    while (match(t, /["\047][^"\047]*["\047]/)) { lit = substr(t, RSTART + 1, RLENGTH - 2); t = substr(t, RSTART + RLENGTH); if (lit ~ /^\/?[A-Za-z0-9_][A-Za-z0-9_\/{}.-]*$/ && lit !~ /^[0-9]/) out = out (out == "" ? "" : "\t") norm(lit) }
    return out == "" ? "?ternary without literal URLs" : out
  }
  # BASEVAR + '/x' ...  or  '/x/' + id ...  or  `/x/${id}`
  n = split(e, parts, /[ \t]*\+[ \t]*/)
  p = ""
  for (i = 1; i <= n; i++) {
    v = trim(parts[i])
    if (v ~ /^["\047`]/) { lit = v; sub(/^["\047`]/, "", lit); sub(/["\047`].*$/, "", lit); gsub(/\$\{[^}]*\}/, "{}", lit); p = p lit }
    else if (i == 1 && (v in base)) p = p ""
    else if (i == 1 && (v in urlv)) { if (urlv[v] ~ /\t/ || urlv[v] ~ /^\?/) return (n == 1 ? urlv[v] : "?variable " v " joined with more parts"); p = p urlv[v] }
    else if (i == 1) return "?url built from variable " v
    else p = p "{}"
  }
  if (p == "") return ""
  if (p ~ /^(https?:)?\/\//) return ""                       # another host: not a route of this app
  if (p !~ /^\/?[A-Za-z0-9_{]/) return ""
  return norm(p)
}
function norm(p) { sub(/[?#].*/, "", p); if (p !~ /^\//) p = "/" p; gsub(/\{\}[^\/]*/, "{}", p); gsub(/\/+/, "/", p); return p }
# the expression after "url:" / "$.post(" / "fetch(": up to the first , ) } at depth 0
function argexpr(s,   i, c, d, q, out) {
  d = 0; q = ""; out = ""
  for (i = 1; i <= length(s); i++) { c = substr(s, i, 1)
    if (q != "") { out = out c; if (c == q) q = ""; continue }
    if (c == "\"" || c == "\047" || c == "`") { q = c; out = out c; continue }
    if (c == "(" || c == "[") d++
    if ((c == ")" || c == "]") && d > 0) { d--; out = out c; continue }
    if (d == 0 && (c == "," || c == ")" || c == "}" || c == ";")) break
    out = out c }
  return out
}
function ctxk() { return sp > 0 ? skind[sp] : "load" }
function ctxn() { return sp > 0 ? sname[sp] : "" }
# m "~" = method not known yet: the row waits in pend until type:/method: is seen
# in the same $.ajax/fetch block (it often comes after url:)
function emit(m, ex,   r, n, a, i, row) {
  r = resolve(ex)
  if (r == "") return
  if (r ~ /^\?/) { printf "U\t%s\t%d\t%s\t%s\t%s\n", FILENAME, FNR, substr(r, 2), ctxk(), ctxn(); return }
  n = split(r, a, "\t")
  for (i = 1; i <= n; i++) { row = sprintf("J\t%s\t%d\t%s\t%s\t%s\t%s\n", FILENAME, FNR, m, a[i], ctxk(), ctxn()); if (m == "~") pend = pend row; else printf "%s", row }
}
function flush(m,   t) { if (pend != "") { t = pend; gsub(/\t~\t/, "\t" m "\t", t); printf "%s", t; pend = "" } }
FNR == 1 { flush("?"); sp = 0; depth = 0; isblade = (FILENAME ~ /\.blade\.php$/); insc = 0; delete urlv; ajax = 0 }
END { flush("?") }
{
  line = $0
  if (isblade) {
    if (!insc) { if (line ~ /<script/ && line !~ /<script[^>]*src=/) { insc = 1; sub(/.*<script[^>]*>/, "", line) } else next }
    if (line ~ /<\/script>/) { sub(/<\/script>.*/, "", line); endsc = 1 } else endsc = 0
  }
  if (line ~ /^[ \t]*(\/\/|\*|\/\*)/) { if (isblade && endsc) insc = 0; next }
  # minified or data lines: not scanned (regex loops on them are too slow);
  # say so if one looks like it makes a call
  if (length(line) > 1500) {
    if (line ~ /\$\.(ajax|post|get)\(|fetch\(|url[ \t]*:/) printf "U\t%s\t%d\tline longer than 1500 characters not scanned (minified code?)\t%s\t%s\n", FILENAME, FNR, ctxk(), ctxn()
    if (isblade && endsc) insc = 0
    next }
  code = nostr(line)
  # ---- base-URL variables (this app's own origin)
  if (match(line, /(const|let|var|window\.)?[ \t]*[A-Za-z_$][A-Za-z0-9_$]*[ \t]*=[ \t]*["\047][ \t]*\{\{[ \t]*url\([ \t]*["\047]\/?["\047][ \t]*\)/) || match(line, /(const|let|var)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*[ \t]*=[ \t]*(window\.)?location\.origin/)) {
    v = substr(line, RSTART, RLENGTH); sub(/^(const|let|var|window\.)?[ \t]*/, "", v); sub(/[ \t]*=.*/, "", v); base[v] = 1 }
  # ---- URL variables in this file:  let url = cond ? '/a' : '/b';
  # A declaration (let/var/const) starts the variable afresh; a plain re-assignment
  # (if/else branches: url = '/a'; ... url = '/b';) adds its value, so a later
  # "url: url" yields every URL the variable can hold.
  if (match(code, /(^|[^A-Za-z0-9_$.])(const|let|var)?[ \t]*[A-Za-z_$][A-Za-z0-9_$]*[ \t]*=[ \t]*[^=>]/) && line ~ /=[ \t]*[^=]/) {
    lhs = line; sub(/[ \t]*=[^=].*/, "", lhs); decl = (lhs ~ /(^|[^A-Za-z0-9_$])(const|let|var)[ \t]/); sub(/.*[^A-Za-z0-9_$]/, "", lhs)
    rhs = line; sub(/^[^=]*=[ \t]*/, "", rhs); sub(/;[ \t]*$/, "", rhs)
    if (lhs != "" && (rhs ~ /^["\047`][ \t]*\/[A-Za-z]/ || rhs ~ /\{\{[ \t]*(route|url)\(/ || (rhs ~ /\?/ && rhs ~ /["\047]\/[A-Za-z]/))) {
      r = resolve(rhs)
      if (r != "" && r !~ /^\?/ && !decl && (lhs in urlv) && urlv[lhs] !~ /^\?/ && ("\t" urlv[lhs] "\t") !~ ("\t" r "\t")) urlv[lhs] = urlv[lhs] "\t" r
      else if (r != "") urlv[lhs] = r }
    else if (lhs != "" && decl) delete urlv[lhs]
  }
  # ---- context openers
  op = ""; on = ""
  if (match(code, /\$\([ \t]*(document|window)[ \t]*\)\.ready[ \t]*\(|^[ \t]*\$\([ \t]*function|jQuery\([ \t]*(document|function)|addEventListener\([ \t]*""[ \t]*,[ \t]*(function|\()|window\.onload[ \t]*=/) && line !~ /addEventListener\([ \t]*["\047](click|change|submit|input|keyup|keydown|blur|focus)/) { op = "load" }
  else if (match(line, /\$\([ \t]*(document|["\047]body["\047]|["\047]html["\047])[ \t]*\)\.on\([ \t]*["\047][^"\047]*["\047][ \t]*,[ \t]*["\047][^"\047]+["\047]/)) {
    s = substr(line, RSTART, RLENGTH); sub(/.*,[ \t]*["\047]/, "", s); sub(/["\047]$/, "", s); op = "sel"; on = s }
  else if (match(line, /\$\([ \t]*["\047][^"\047]+["\047][ \t]*\)\.(on|click|change|submit|keyup|keydown|keypress|input|blur|focus|dblclick|select)\(/)) {
    s = substr(line, RSTART, RLENGTH); sub(/^\$\([ \t]*["\047]/, "", s); sub(/["\047].*/, "", s); op = "sel"; on = s }
  else if (match(line, /document\.(getElementById|querySelector)\([ \t]*["\047][^"\047]+["\047][ \t]*\)\.addEventListener\(/)) {
    s = substr(line, RSTART, RLENGTH); g = (s ~ /getElementById/); sub(/^[^"\047]*["\047]/, "", s); sub(/["\047].*/, "", s); op = "sel"; on = (g ? "#" : "") s }
  else if (match(code, /(^|[^A-Za-z0-9_$.])function[ \t]+[A-Za-z_$][A-Za-z0-9_$]*[ \t]*\(/)) {
    s = substr(code, RSTART, RLENGTH); sub(/.*function[ \t]+/, "", s); sub(/[ \t]*\($/, "", s); op = "fn"; on = s }
  else if (match(code, /[A-Za-z_$][A-Za-z0-9_$]*[ \t]*[:=][ \t]*(async[ \t]+)?function[ \t]*\(/) || match(code, /(const|let|var)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*[ \t]*=[ \t]*(async[ \t]*)?(\([^)]*\)|[A-Za-z_$][A-Za-z0-9_$]*)[ \t]*=>/)) {
    s = substr(code, RSTART, RLENGTH); sub(/^(const|let|var)[ \t]+/, "", s); sub(/[ \t]*[:=].*/, "", s); op = "fn"; on = s }
  if (op == "sel" && line !~ /function|=>/) {           # handler passed by name: $(sel).on('click', doThing)
    h = line; sub(/.*,[ \t]*/, "", h); sub(/^\.(click|change|submit|keyup|keydown|input|blur|focus)\(/, "", h); sub(/[ \t]*\).*/, "", h)
    if (h ~ /^[A-Za-z_$][A-Za-z0-9_$]*$/) printf "X\t%s\t%d\t%s\tsel\t%s\n", FILENAME, FNR, h, on
    op = "" }
  if (op == "fn") printf "D\t%s\t%s\n", FILENAME, on
  # ---- calls on this line (in the context the line belongs to)
  if (op != "") { sp++; skind[sp] = op; sname[sp] = on; sdepth[sp] = depth; sopen[sp] = 0 }
  if (pend != "" && FNR - ajax > 12) flush("?")
  if (match(line, /\$\.ajax\(|(^|[^A-Za-z0-9_$.])fetch\(/)) { flush("?"); ajax = FNR; amethod = "" }
  if (ajax && FNR - ajax <= 12 && match(line, /(type|method)[ \t]*:[ \t]*["\047][A-Za-z]+["\047]/)) {
    m = substr(line, RSTART, RLENGTH); sub(/.*:[ \t]*["\047]/, "", m); sub(/["\047]$/, "", m); amethod = toupper(m); flush(amethod) }
  # (emit() calls match() too, so the position is saved in nx before calling it)
  t = line
  while (match(t, /(^|[^A-Za-z0-9_$])url[ \t]*:[ \t]*/)) { nx = RSTART + RLENGTH; ex = argexpr(substr(t, nx)); emit((ajax && FNR - ajax <= 12) ? (amethod != "" ? amethod : "~") : "?", ex); t = substr(t, nx) }
  t = line
  while (match(t, /\$\.(post|get|getJSON)\([ \t]*/)) { nx = RSTART + RLENGTH; m = substr(t, RSTART + 2); sub(/\(.*/, "", m); m = (m == "post") ? "POST" : "GET"; ex = argexpr(substr(t, nx)); emit(m, ex); t = substr(t, nx) }
  t = line
  while (match(t, /\$\.ajax\([ \t]*["\047`]/)) { nx = RSTART + RLENGTH; ex = argexpr(substr(t, RSTART + 7)); emit("?", ex); t = substr(t, nx) }
  t = line
  while (match(t, /(^|[^A-Za-z0-9_$.])fetch\([ \t]*/)) { nx = RSTART + RLENGTH; ex = argexpr(substr(t, nx)); emit((line ~ /method[ \t]*:[ \t]*["\047]POST/) ? "POST" : "?", ex); t = substr(t, nx) }
  t = line
  while (match(t, /axios\.(get|post|put|patch|delete)\([ \t]*/)) { nx = RSTART + RLENGTH; m = substr(t, RSTART + 6); sub(/\(.*/, "", m); ex = argexpr(substr(t, nx)); emit(toupper(m), ex); t = substr(t, nx) }
  # bare calls name(  (for the call graph: which context calls which function)
  t = " " code
  while (match(t, /[^A-Za-z0-9_$.][A-Za-z_$][A-Za-z0-9_$]*[ \t]*\(/)) {
    nm = substr(t, RSTART + 1, RLENGTH - 1); sub(/[ \t]*\($/, "", nm); t = substr(t, RSTART + RLENGTH)
    if (nm !~ /^(if|for|while|switch|catch|function|return|typeof|new|await|super|this|async|else|do|in|of|var|let|const|alert|confirm|parseInt|parseFloat|setTimeout|setInterval|clearTimeout|clearInterval|String|Number|Boolean|Array|Object|Date|JSON|Math|Promise|isNaN|encodeURIComponent|decodeURIComponent|require|\$|jQuery)$/ && nm != on)
      printf "X\t%s\t%d\t%s\t%s\t%s\n", FILENAME, FNR, nm, ctxk(), ctxn()
  }
  # ---- braces
  depth += cnt(code, "{") - cnt(code, "}")
  if (sp > 0 && depth > sdepth[sp]) sopen[sp] = 1
  while (sp > 0 && (depth < sdepth[sp] || (depth == sdepth[sp] && sopen[sp]))) sp--
  if (isblade && endsc) { insc = 0; sp = 0; depth = 0 }
}
