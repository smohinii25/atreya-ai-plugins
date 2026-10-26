#!/bin/bash
# Feeds fake PreToolUse JSON to hooks/guard.sh and prints PASS/FAIL per case.
# Builds a throwaway workspace (fake repos, dummy secrets, an approved ticket)
# under $TMPDIR, so it never touches the real repos. Exit code 1 if any FAIL.
#
#   bash plugins/atreya/tests/guard-tests.sh          # all cases
#   bash plugins/atreya/tests/guard-tests.sh -v       # also show guard output

VERBOSE=0; [ "$1" = -v ] && VERBOSE=1
HERE=$(cd "$(dirname "$0")" && pwd -P)
PLUGIN=$(cd "$HERE/.." && pwd -P)
GUARD="$PLUGIN/hooks/guard.sh"
JQ=/usr/bin/jq
[ -x "$JQ" ] || { echo "needs /usr/bin/jq (macOS 15+)"; exit 1; }

W=$(mktemp -d "${TMPDIR:-/tmp}/atreya-guard-tests.XXXXXX") || exit 1
W=$(cd "$W" && pwd -P)
trap 'rm -rf "$W"' EXIT
export CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_OPTION_WORKSPACE_ROOT="$W"

# ---------------------------------------------------------------- fixture
R=$W/repos; D=$W/atreya-docs; Q=$W/atreya-qa
mkrepo() {  # mkrepo NAME BRANCH
  local d="$R/$1"; mkdir -p "$d/app" "$d/routes" "$d/config" "$d/lib/api" "$d/ios" "$d/key"
  echo "APP_KEY=dummy" > "$d/.env"; echo "APP_KEY=" > "$d/.env.example"; echo "x" > "$d/.env.local"
  echo '<?php // x' > "$d/app/x.php"; echo '<?php // routes' > "$d/routes/web.php"
  echo '{}' > "$d/config/firebase-key.json"; echo '{}' > "$d/config/google-services.json"
  echo 'k' > "$d/key/release.jks"; echo 'k' > "$d/ios/GoogleService-Info.plist"
  echo '// a' > "$d/lib/a.dart"; echo '// secret' > "$d/lib/api/gchat_logger.dart"
  mkdir -p "$d/lib/utilities"; echo 'baseUrl = "https://staging-api.example.test";' > "$d/lib/utilities/flavor_config.dart"
  ( cd "$d" && git init -q -b master && git add -A \
      && git -c user.name=t -c user.email=t@t commit -q -m init \
      && { [ "$2" = master ] || git checkout -q -b "$2"; } )
}
mkrepo backend master
mkrepo app feature/T1
mkrepo mobile production
mkdir -p "$D/dev/T1" "$D/dev/T2" "$Q/.claude" "$W/links"
echo T1 > "$D/dev/.active-ticket"; touch "$D/dev/T1/APPROVED"; echo old > "$D/old.md"
ln -s "$R/backend" "$W/links/be"
BE=$R/backend; AP=$R/app

# ---------------------------------------------------------------- runner
PASSN=0; FAILN=0
check() {  # check EXPECT LABEL JSON
  local exp="$1" label="$2" json="$3" out rc got
  out=$(printf '%s' "$json" | /bin/bash "$GUARD" 2>&1); rc=$?
  if [ $rc = 2 ]; then got=block
  elif [ $rc = 0 ] && printf '%s' "$out" | grep -q '"permissionDecision":"ask"'; then got=ask
  elif [ $rc = 0 ]; then got=allow
  else got="exit$rc"; fi
  if [ "$got" = "$exp" ]; then PASSN=$((PASSN+1)); printf 'PASS  %-5s  %s\n' "$exp" "$label"
  else FAILN=$((FAILN+1)); printf 'FAIL  %-5s  %s   (got %s)\n' "$exp" "$label" "$got"; fi
  [ $VERBOSE = 1 ] && [ -n "$out" ] && printf '        %s\n' "$(printf '%s' "$out" | head -c 300)"
}
bash_c() { check "$1" "Bash[$(basename "$2")]: $3" "$($JQ -nc --arg c "$2" --arg x "$3" '{tool_name:"Bash",cwd:$c,tool_input:{command:$x}}')"; }
file_c() { check "$1" "$2 ${3#$W/}" "$($JQ -nc --arg t "$2" --arg p "$3" '{tool_name:$t,cwd:"/",tool_input:{file_path:$p,content:"x",old_string:"a",new_string:"b"}}')"; }
grep_c() { check "$1" "Grep ${2#$W/} mode=${3:-default} glob=$4 type=$5" "$($JQ -nc --arg p "$2" --arg m "$3" --arg g "$4" --arg t "$5" \
  '{tool_name:"Grep",cwd:"/",tool_input:({pattern:"x",path:$p} + (if $m!="" then {output_mode:$m} else {} end) + (if $g!="" then {glob:$g} else {} end) + (if $t!="" then {type:$t} else {} end))}')"; }
glob_c() { check "$1" "Glob $2" "$($JQ -nc --arg p "$2" --arg d "$BE" '{tool_name:"Glob",cwd:$d,tool_input:{pattern:$p}}')"; }
tool_c() { check "$1" "$2 $3" "$($JQ -nc --arg t "$2" --argjson i "$3" '{tool_name:$t,cwd:"/",tool_input:$i}')"; }
raw_c()  { check "$1" "raw input: $2" "$3"; }
section() { printf '\n== %s\n' "$1"; }

# ---------------------------------------------------------------- a. secrets
section "a. secret files"
file_c block Read "$BE/.env"
file_c allow Read "$BE/.env.example"
file_c block Read "$BE/.env.local"
file_c block Read "$BE/key/release.jks"
file_c block Read "$BE/config/firebase-key.json"
file_c block Read "$BE/config/google-services.json"
file_c block Read "$BE/ios/GoogleService-Info.plist"
file_c block Read "$BE/lib/api/gchat_logger.dart"
file_c allow Read "$BE/app/x.php"
grep_c block "$BE/.env" content
grep_c block "$BE" content
grep_c allow "$BE"
grep_c allow "$BE" files_with_matches
grep_c allow "$BE" content "*.php"
grep_c block "$BE/lib" content "" dart
grep_c allow "$BE/routes" content
grep_c block "$BE" "" ".env*"
glob_c block "**/.env*"
glob_c allow "**/.env.example"
glob_c allow "**/*.php"
bash_c block "$BE" "cat .env"
bash_c allow "$BE" "cat .env.example"
bash_c block "$BE" "cat config/*"
bash_c block "$BE" "grep -rn APP_KEY ."
bash_c allow "$BE" "grep -rl APP_KEY ."
bash_c allow "$BE" "grep -rn 'patient/list' routes app"
bash_c block "$BE" "rg APP_KEY"
bash_c allow "$BE" "rg -l APP_KEY"
bash_c block "$BE" "find . -type f -exec cat {} \\;"
bash_c allow "$BE" "find . -name '*.php'"
bash_c block "$BE" "find . -name '*.php' | xargs grep foo"
bash_c block "$BE" "bash -c 'cat .env'"
bash_c block "$BE" 'echo "$(head -1 .env)"'
bash_c block "$BE" "git show HEAD:.env"
file_c block Read "$AP/lib/utilities/flavor_config.dart"
grep_c block "$AP/lib/utilities/flavor_config.dart" content
grep_c block "$AP/lib/utilities" content
bash_c block "$AP" "cat lib/utilities/flavor_config.dart"
bash_c block "$AP" "grep -n baseUrl lib/utilities/flavor_config.dart"
glob_c block "**/flavor_config.dart"
file_c block Read "$BE/app/Http/Controllers/SamvitPaymentBridgeController.php"
bash_c block "$BE" "cat app/Http/Controllers/SamvitPaymentBridgeController.php"
bash_c allow "$AP" "bash \"$PLUGIN/scripts/extract-baseurl.sh\" --root \"$W\" app"

# ---------------------------------------------------------------- b. repo writes
section "b. repo writes (backend=master, app=feature/T1, T1 APPROVED)"
file_c block Edit "$BE/app/x.php"
file_c allow Edit "$AP/app/x.php"
file_c block Write "$R/mobile/app/x.php"
file_c block MultiEdit "$BE/app/x.php"
file_c block NotebookEdit "$BE/app/n.ipynb"
file_c allow Write "$D/notes.md"
file_c allow Write "$Q/tests/login.spec.ts"
file_c block Write "$W/links/be/app/x.php"
bash_c block "$BE" "echo x > app/x.php"
bash_c allow "$AP" "echo x > app/x.php"
bash_c block "$BE" "echo x >> app/x.php"
bash_c block "$BE" "echo x | tee app/y.php"
bash_c block "$BE" "sed -i '' 's/a/b/' app/x.php"
bash_c allow "$AP" "sed -i '' 's/a/b/' app/x.php"
bash_c allow "$BE" "sed -n 1p app/x.php"
bash_c block "$BE" "mv app/x.php app/z.php"
bash_c block "$BE" "cp routes/web.php app/"
bash_c block "$BE" "rm app/x.php"
bash_c block "$BE" "touch app/new.php"
bash_c block "$W" "rm -rf repos/backend/app"
bash_c block "$BE" "curl -o app/x.html https://staging-dashboard.naditarangini.com"
bash_c allow "$BE" "php artisan route:list --json > $D/routes.json"
bash_c allow "$BE" "git log --oneline > $Q/log.txt"
bash_c allow "$BE" "ls > /tmp/atreya-guard-test.txt"
bash_c block "$BE" "ls > $HOME/atreya-guard-test.txt"
bash_c allow "$BE" "ls app 2>/dev/null"
bash_c allow "$D" "echo hi > notes.md"
echo T2 > "$D/dev/.active-ticket"
file_c block Edit "$AP/app/x.php"
echo "../T1" > "$D/dev/.active-ticket"
file_c block Edit "$AP/app/x.php"
rm -f "$D/dev/.active-ticket"
file_c block Edit "$AP/app/x.php"
echo T1 > "$D/dev/.active-ticket"

# ---------------------------------------------------------------- c. git
section "c. git (read-only allow-list)"
for g in "git status" "git diff --stat" "git log --oneline -3" "git show --stat HEAD" "git blame app/x.php" \
         "git branch --list" "git branch" "git rev-parse HEAD" "git ls-files" "git grep -l APP" "git remote -v" \
         "git diff HEAD -- app" "git grep APP -- app" "git -C $BE status"; do
  bash_c allow "$BE" "$g"
done
for g in "git commit -m x" "git push" "git checkout -b x" "git branch newbranch" "git stash" "git reset --hard" \
         "git add ." "git -c core.pager=less log" "git diff" "git diff -- ." "git show HEAD" "git log -p" "git grep APP" \
         "git diff --output=/tmp/x HEAD" "git remote add x y"; do
  bash_c block "$BE" "$g"
done
bash_c allow "$Q" "git status"
bash_c block "$Q" "git commit -m x"

# ---------------------------------------------------------------- d. artisan
section "d. php artisan"
bash_c allow "$BE" "php artisan route:list"
bash_c allow "$BE" "php artisan list"
bash_c allow "$BE" "php artisan about"
bash_c block "$BE" "php artisan migrate"
bash_c block "$BE" "php artisan db:wipe --force"
bash_c block "$BE" "php artisan tinker"

# ---------------------------------------------------------------- e. installs
section "e. package installs"
bash_c block "$BE" "npm install"
bash_c block "$BE" "composer require foo/bar"
bash_c block "$AP" "flutter pub get"
bash_c block "$BE" "pip install requests"
bash_c block "$AP/ios" "pod install"
bash_c block "$BE" "yarn"
bash_c block "$Q" "npm --prefix $BE install"
bash_c allow "$Q" "npm install"
bash_c allow "$Q" "npx playwright install chromium"
bash_c allow "$BE" "npm ls"

# ---------------------------------------------------------------- f. production hosts
section "f. production hosts"
bash_c block "$W" "curl https://dashboard.naditarangini.com/login"
bash_c block "$W" "wget -qO- https://api.ashoka.world/health"
bash_c block "$W" "curl -s https://x.dashboard.naditarangini.com"
bash_c allow "$W" "curl -s https://staging-dashboard.naditarangini.com/login"
bash_c allow "$W" "curl -s https://staging-api.ashoka.world/health"
bash_c allow "$BE" "grep -rn api.ashoka.world app"
tool_c block mcp__plugin_playwright_playwright__browser_navigate '{"url":"https://dashboard.naditarangini.com/login"}'
tool_c allow mcp__plugin_playwright_playwright__browser_navigate '{"url":"https://staging-dashboard.naditarangini.com/login"}'
tool_c block mcp__claude_ai_Playwright_Local__browser_run_code '{"code":"await page.goto(\"https://dashboard.naditarangini.com\")"}'
tool_c block WebFetch '{"url":"https://api.ashoka.world/","prompt":"x"}'
tool_c allow WebFetch '{"url":"https://staging-dashboard.naditarangini.com/","prompt":"x"}'

# ---------------------------------------------------------------- g. Zoho
section "g. Zoho Sprints"
tool_c allow mcp__claude_ai_Zoho_MCP_Atreya__ZohoSprints_GetItems '{}'
tool_c allow mcp__other_name__ZohoSprints_GetItemDetails '{}'
tool_c ask   mcp__claude_ai_Zoho_MCP_Atreya__ZohoSprints_CreateItem '{}'
tool_c ask   mcp__claude_ai_Zoho_MCP_Atreya__ZohoSprints_UpdateItem '{}'
tool_c ask   mcp__other_name__ZohoSprints_MoveItem '{}'
tool_c ask   mcp__other_name__ZohoSprints_StartSprint '{}'
tool_c block mcp__zoho_crm__ZohoCRM_CreateRecord '{}'
tool_c allow mcp__zoho_crm__ZohoCRM_GetRecords '{}'

# ---------------------------------------------------------------- s. self-protection
section "s. self-protection"
file_c block Write "$D/dev/T2/APPROVED"
file_c block Edit "$D/dev/T1/APPROVED"
bash_c block "$D" "touch dev/T2/APPROVED"
bash_c block "$D" "rm dev/T1/APPROVED"
bash_c block "$D" "mv dev/T1/APPROVED /tmp/x"
bash_c block "$D" "rm -rf dev/T1"
bash_c allow "$D" "rm old.md"
file_c allow Write "$D/dev/.active-ticket"
file_c block Edit "$PLUGIN/hooks/guard.sh"
file_c block Write "$PLUGIN/config/prod-hosts.txt"
file_c block Write "$HOME/.claude/settings.json"
file_c block Write "$Q/.claude/settings.local.json"

# ---------------------------------------------------------------- fail-closed
section "fail-closed"
raw_c block "not JSON" 'hello'
raw_c block "empty" ''
raw_c block "no tool_name" '{"tool_input":{}}'
bash_c block "$W" 'echo "unterminated'
bash_c allow "$BE" "echo \"routes: \$(grep -c 'Route::post(' routes/web.php)\""
bash_c block "$BE" "echo \"\$(grep -c 'x(' .env)\""
bash_c block "$W" "eval rm -rf x"

printf '\n%d passed, %d failed\n' "$PASSN" "$FAILN"
[ $FAILN = 0 ]
