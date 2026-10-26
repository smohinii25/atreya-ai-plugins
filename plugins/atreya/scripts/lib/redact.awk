# Shared secret patterns for every atreya script (one place to maintain).
#
#   mode=redact (default): print each input line with secrets masked.
#   mode=scan:             print "FILE<TAB>LINE<TAB>TYPE<TAB>CONFIDENCE<TAB>COMMENTED"
#                          per finding. Values are NEVER printed in scan mode.
#
# WHY: docs and script output must never carry a key, even one that sits in a
# normal-looking code file (e.g. commented-out Razorpay keys).

BEGIN {
  if (mode == "") mode = "redact"
  KW   = "([Kk][Ee][Yy]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd])"
  NAME = "[\"']?[A-Za-z0-9_.$-]*" KW "[A-Za-z0-9_.-]*[\"']?"
  SEP  = "[ \t]*(=>|:=|=|:)[ \t]*"
  VAL  = "(\"[^\"]*\"|'[^']*'|[^ \t,;)}&'\"]+)"
  ASSIGN = NAME SEP VAL
}

FNR == 1 { inkey = 0 }

function commented() { return ($0 ~ /^[ \t]*(\/\/|#|\*|\/\*|<!--|--)/) ? "yes" : "no" }
function emit(type, conf) {
  if (mode == "scan" && !(type in seen)) {
    seen[type] = 1
    printf "%s\t%d\t%s\t%s\t%s\n", FILENAME, FNR, type, conf, commented()
  }
}
# Replace every match of re in `line`; report type once per line.
function mask(re, rep, type,   n) { n = gsub(re, rep, line); if (n > 0) emit(type, "high"); return n }

# Is this assignment value a literal that could be a secret?
#   strict=1 (scan): stricter, to keep the report readable.
function literal_secret(v, strict,   u, quoted) {
  u = v; quoted = 0
  if (u ~ /^".*"$/ || u ~ /^'.*'$/) { u = substr(u, 2, length(u) - 2); quoted = 1 }
  if (u == "" || u ~ /\[REDACTED/) return 0
  if (u ~ /^\$/ || u ~ /\(/ || u ~ /->/ || u ~ /[ \t]/) return 0      # code / text, not a literal
  if (u ~ /\\/ || u ~ /::/) return 0                                  # PHP class refs: \App\...\X::class
  if (u ~ /\|/ || u ~ /^(required|nullable|sometimes|bail|string|confirmed|min:|max:|regex:)/) return 0  # validation rules
  if (u ~ /^(true|false|null|none|nil|undefined|TBD|TODO)$/) return 0
  if (u ~ /^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$/) return 0  # code refs like TextInputType.number
  if (!quoted && u ~ /^[A-Za-z_]+$/) return 0                              # bare identifier (token: token)
  if (!strict) return 1
  if (length(u) < 8) return 0
  if (u ~ /^(your|xxx|\*\*\*|changeme|example|dummy|test|placeholder)/) return 0
  if (u ~ /\.(png|jpe?g|svg|gif|json|php|dart|js|css|html|md)$/) return 0
  if (u ~ /[0-9]/ && u ~ /[A-Za-z]/) return 1
  return (length(u) >= 24)
}

function mask_assignments(   out, rest, seg, head, val, q) {
  out = ""; rest = line
  while (match(rest, ASSIGN)) {
    out = out substr(rest, 1, RSTART - 1)
    seg = substr(rest, RSTART, RLENGTH)
    rest = substr(rest, RSTART + RLENGTH)
    match(seg, SEP)
    head = substr(seg, 1, RSTART + RLENGTH - 1)
    val = substr(seg, RSTART + RLENGTH)
    # a file name is not a variable: UpdatePasswordController.php:213 is a citation
    if (substr(seg, 1, RSTART - 1) ~ /\.(php|dart|js|ts|json|md|ya?ml|blade|html|css|txt)["']?$/) { out = out seg; continue }
    if (literal_secret(val, 0)) {
      if (literal_secret(val, 1)) emit("assignment to a key/secret/token/password name", "medium")
      q = substr(val, 1, 1); if (q != "\"" && q != "'") q = ""
      val = q "[REDACTED]" q
    }
    out = out head val
  }
  line = out rest
}

{
  line = $0
  delete seen
  # Private key blocks (PEM), on one line or spanning lines.
  if (inkey) {
    if (line ~ /-----END [A-Z ]*PRIVATE KEY-----/) {
      inkey = 0; sub(/.*-----END [A-Z ]*PRIVATE KEY-----/, "", line)
      if (mode == "redact" && line != "") print line
    }
    next
  }
  if (line ~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/) {
    emit("private key block", "high")
    if (line ~ /-----BEGIN [A-Z ]*PRIVATE KEY-----.*-----END [A-Z ]*PRIVATE KEY-----/) {
      gsub(/-----BEGIN [A-Z ]*PRIVATE KEY-----.*-----END [A-Z ]*PRIVATE KEY-----/, "[REDACTED-PRIVATE-KEY]", line)
    } else {
      sub(/-----BEGIN [A-Z ]*PRIVATE KEY-----.*/, "[REDACTED-PRIVATE-KEY]", line)
      inkey = 1
      if (mode == "redact") print line
      next
    }
  }
  mask("rzp_live_[A-Za-z0-9]+", "rzp_live_[REDACTED]", "Razorpay live key")
  mask("rzp_test_[A-Za-z0-9]+", "rzp_test_[REDACTED]", "Razorpay test key")
  mask("(AKIA|ASIA)[0-9A-Z]{16}", "[REDACTED-AWS-KEY]", "AWS access key ID")
  mask("AIza[0-9A-Za-z_-]{30,}", "[REDACTED-GOOGLE-API-KEY]", "Google API key")
  mask("sk_live_[0-9A-Za-z]{8,}", "sk_live_[REDACTED]", "Stripe-style live secret key")
  mask("sk_test_[0-9A-Za-z]{8,}", "sk_test_[REDACTED]", "Stripe-style test secret key")
  mask("AAAA[A-Za-z0-9_-]{7}:APA91b[A-Za-z0-9_-]+", "[REDACTED-FCM-SERVER-KEY]", "Firebase Cloud Messaging server key")
  mask("gh[pousr]_[A-Za-z0-9]{20,}", "[REDACTED-GITHUB-TOKEN]", "GitHub token")
  mask("xox[baprs]-[A-Za-z0-9-]{10,}", "[REDACTED-SLACK-TOKEN]", "Slack token")
  mask("SG\\.[A-Za-z0-9_-]{16,}\\.[A-Za-z0-9_-]{16,}", "[REDACTED-SENDGRID-KEY]", "SendGrid API key")
  mask("eyJ[A-Za-z0-9_-]{8,}\\.eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}", "[REDACTED-JWT]", "JWT")
  mask("Zoho-enczapikey [A-Za-z0-9+/=_-]+", "Zoho-enczapikey [REDACTED]", "ZeptoMail API key")
  mask("Bearer [A-Za-z0-9+/=._-]{20,}", "Bearer [REDACTED]", "Bearer token")
  mask("Basic [A-Za-z0-9+/=]{16,}", "Basic [REDACTED]", "Basic auth credentials")
  mask("://[^/ :@'\"]+:[^/ @'\"]+@", "://[REDACTED]@", "credentials in URL")
  mask_assignments()
  if (mode == "redact") print line
}
