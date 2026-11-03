#!/bin/bash
# Tests for plugins/atreya/scripts (redaction, secret-file filter, baseUrl
# extractor, secret scan, yaml2json). Uses FAKE key values and a throwaway
# workspace under $TMPDIR. Prints PASS/FAIL; exit 1 if any FAIL.
#
#   bash plugins/atreya/tests/scripts-tests.sh

HERE=$(cd "$(dirname "$0")" && pwd -P)
PLUGIN=$(cd "$HERE/.." && pwd -P)
S="$PLUGIN/scripts"
W=$(mktemp -d "${TMPDIR:-/tmp}/atreya-scripts-tests.XXXXXX") || exit 1
W=$(cd "$W" && pwd -P)
# ATREYA_KEEP_TEST_DIR=1 keeps the throwaway workspace for debugging
if [ -n "${ATREYA_KEEP_TEST_DIR:-}" ]; then echo "test workspace kept: $W"; else trap 'rm -rf "$W"' EXIT; fi

PASSN=0; FAILN=0
ok()   { PASSN=$((PASSN+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAILN=$((FAILN+1)); printf 'FAIL  %s\n' "$1"; [ -n "$2" ] && printf '        %s\n' "$2"; }
expect_contains()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing: $3" ;; esac; }
expect_absent()     { case "$2" in *"$3"*) bad "$1" "should not contain: $3" ;; *) ok "$1" ;; esac; }
expect_eq()         { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
section() { printf '\n== %s\n' "$1"; }

# Fake secrets (shaped like the real thing, never real).
F_RZP_LIVE=rzp_live_FAKE00TEST11; F_RZP_TEST=rzp_test_FAKE22TEST33; F_RZP_SECRET=FakeRzpSecret0099aa
F_AWS=AKIAFAKEFAKEFAKE1234; F_GOOGLE=AIzaFAKEfakeFAKEfakeFAKEfakeFAKEfake123
F_SK=sk_live_FAKEfake12345678; F_PEM=MIIFAKEPEMBODYLINEfake0000000000
F_TOKEN=FAKEtoken987654321; F_PASS=FakePass9876; F_SECRETKEY=FakeSecret12345

# ---------------------------------------------------------------- redaction
section "redaction filter (scripts/lib/redact.sh)"
IN=$(cat <<EOF
razorpayKeyId = '$F_RZP_LIVE';
// razorpayKeyId = '$F_RZP_TEST';
// razorpayKeySecret = '$F_RZP_SECRET';
aws_access_key_id = $F_AWS
const g = "$F_GOOGLE";
STRIPE=$F_SK
-----BEGIN RSA PRIVATE KEY-----
$F_PEM
-----END RSA PRIVATE KEY-----
"private_key": "-----BEGIN PRIVATE KEY-----\\n$F_PEM\\n-----END PRIVATE KEY-----\\n",
"api_token": "$F_TOKEN",
DB_PASSWORD=$F_PASS
\$secretKey = '$F_SECRETKEY';
EOF
)
OUT=$(printf '%s\n' "$IN" | bash "$S/lib/redact.sh")
for v in "$F_RZP_LIVE" "$F_RZP_TEST" "$F_RZP_SECRET" "$F_AWS" "$F_GOOGLE" "$F_SK" "$F_PEM" "$F_TOKEN" "$F_PASS" "$F_SECRETKEY"; do
  expect_absent "redacts ${v%%[0-9]*}..." "$OUT" "$v"
done
expect_contains "keeps Razorpay prefix as a type hint" "$OUT" "rzp_live_[REDACTED]"
expect_contains "marks private key block" "$OUT" "[REDACTED-PRIVATE-KEY]"
expect_eq "PEM body line removed (13 in -> 11 out)" "$(printf '%s\n' "$OUT" | grep -c '')" "11"
KEEP=$(cat <<'EOF'
'password' => 'required|string|min:8|confirmed',
"enterPassword": "Enter password",
Route::post('/forgot-password', [AuthController::class, 'forgotPassword']);
keyboardType: TextInputType.number,
$token = $request->bearerToken();
baseUrl = "https://staging-api.ashoka.world";
'auth.token' => \App\Http\Middleware\CheckAuthToken::class,
'Password' => Illuminate\Support\Facades\Password::class,
- source `Ashoka-World-Backend:app/Http/Controllers/UpdatePasswordController.php:213`
EOF
)
expect_eq "leaves validation rules, UI text, routes and code unchanged" "$(printf '%s\n' "$KEEP" | bash "$S/lib/redact.sh")" "$KEEP"

section "scan mode never prints values"
printf '%s\n' "$IN" > "$W/sample.php"
SCAN=$(. "$S/lib/redact.sh"; cd "$W" && secret_scan sample.php)
for v in "$F_RZP_LIVE" "$F_RZP_TEST" "$F_RZP_SECRET" "$F_AWS" "$F_GOOGLE" "$F_SK" "$F_PEM" "$F_TOKEN" "$F_PASS" "$F_SECRETKEY"; do
  expect_absent "scan output hides ${v%%[0-9]*}..." "$SCAN" "$v"
done
expect_contains "scan reports Razorpay live key with line 1" "$SCAN" "sample.php	1	Razorpay live key	high	no"
expect_contains "scan marks commented-out key" "$SCAN" "sample.php	2	Razorpay test key	high	yes"
expect_contains "scan reports private key block" "$SCAN" "private key block"
expect_contains "scan reports generic assignment as medium" "$SCAN" "assignment to a key/secret/token/password name	medium"

# ---------------------------------------------------------------- fixture workspace
R="$W/ws/repos"; mkdir -p "$R" "$W/ws/atreya-docs" "$W/ws/atreya-qa"
mkfx() {  # mkfx NAME
  local d="$R/$1"; mkdir -p "$d/lib/common_files/utilities" "$d/app/Http/Controllers" "$d/config"
  cat > "$d/lib/common_files/utilities/flavor_config.dart" <<EOF
enum Environment {staging, prod}
abstract class AppEnvironment {
  static late String baseUrl;
  static void setUpEnv(Environment environment) {
    switch (environment) {
      case Environment.staging:
        // razorpayKeyId = '$F_RZP_TEST';
        // baseUrl = "https://old-staging.example.com";
        baseUrl = "https://staging-api.example.test";
        break;
      case Environment.prod:
        // razorpayKeyId = '$F_RZP_LIVE';
        // razorpayKeySecret = '$F_RZP_SECRET';
        baseUrl = "https://api.example.test";
        break;
      case Environment.evil:
        baseUrl = "https://x.example.test/?key=$F_TOKEN";
        break;
    }
  }
}
EOF
  echo "APP_KEY=$F_RZP_LIVE" > "$d/.env"; echo "APP_KEY=" > "$d/.env.example"
  echo '{"private_key_id":"x"}' > "$d/config/firebase-admin.json"
  printf '<?php\n// legacy\n$key = "%s";\nclass PayController {}\n' "$F_RZP_LIVE" > "$d/app/Http/Controllers/PayController.php"
  echo '<?php // clean' > "$d/app/Http/Controllers/HomeController.php"
  ( cd "$d" && git init -q -b master && git add -A && git -c user.name=t -c user.email=t@t commit -q -m init )
}
mkfx app

# ---------------------------------------------------------------- secret-file filter parity
section "secret-file list: scripts/lib/common.sh == hooks/guard.sh"
. "$S/lib/common.sh"
NAMES=".env .env.local .env.production .env.example .ENV x.jks release.keystore firebase-admin-key.json firebase.json google-services.json GoogleService-Info.plist gchat_logger.dart flavor_config.dart Flavor_Config.dart SamvitPaymentBridgeController.php PaymentController.php app.php main.dart env.md config.env"
for n in $NAMES; do
  g=$(/usr/bin/jq -nc --arg p "$W/ws/repos/app/$n" '{tool_name:"Read",cwd:"/",tool_input:{file_path:$p}}' \
      | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_OPTION_WORKSPACE_ROOT="$W/ws" /bin/bash "$PLUGIN/hooks/guard.sh" >/dev/null 2>&1; echo $?)
  [ "$g" = 2 ] && g=secret || g=normal
  is_secret_name "$n" && c=secret || c=normal
  expect_eq "$n: guard=$g common=$c" "$g" "$c"
done
ROOT="$W/ws"
TF=$(tracked_files "$R/app")
expect_absent "tracked_files hides .env" "$TF" ".env
"
expect_absent "tracked_files hides flavor_config.dart" "$TF" "flavor_config.dart"
expect_absent "tracked_files hides firebase-*.json" "$TF" "firebase-admin.json"
expect_contains "tracked_files keeps .env.example" "$TF" ".env.example"
expect_contains "tracked_files keeps normal code" "$TF" "app/Http/Controllers/HomeController.php"

# ---------------------------------------------------------------- extractor
section "baseUrl extractor (the one script allowed to read flavor_config.dart)"
EX=$(bash "$S/extract-baseurl.sh" --root "$W/ws" app 2>"$W/ex.err")
expect_eq "staging baseUrl" "$(printf '%s' "$EX" | /usr/bin/jq -r .baseUrl.staging)" "https://staging-api.example.test"
expect_eq "prod baseUrl" "$(printf '%s' "$EX" | /usr/bin/jq -r .baseUrl.prod)" "https://api.example.test"
expect_eq "value with a query string is dropped" "$(printf '%s' "$EX" | /usr/bin/jq -r '.baseUrl.evil // "dropped"')" "dropped"
expect_absent "commented-out baseUrl ignored" "$EX" "old-staging"
for v in "$F_RZP_LIVE" "$F_RZP_TEST" "$F_RZP_SECRET" "$F_TOKEN" rzp_ Secret; do
  expect_absent "extractor output has no '$v'" "$EX$(cat "$W/ex.err")" "$v"
done
GJ() { /usr/bin/jq -nc --arg c "$1" --arg d "$R/app" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' \
      | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_OPTION_WORKSPACE_ROOT="$W/ws" /bin/bash "$PLUGIN/hooks/guard.sh" >/dev/null 2>&1; echo $?; }
expect_eq "guard allows running the extractor" "$(GJ "bash \"$S/extract-baseurl.sh\" --root \"$W/ws\" app")" 0
expect_eq "guard blocks cat of flavor_config.dart" "$(GJ "cat lib/common_files/utilities/flavor_config.dart")" 2

# ---------------------------------------------------------------- secret scan
section "one-time secret scan"
SOUT=$(bash "$S/secret-scan.sh" --root "$W/ws")
REP=$(cat "$W/ws/atreya-docs/security/secret-scan.md" 2>/dev/null)
expect_contains "writes atreya-docs/security/secret-scan.md" "$SOUT" "security/secret-scan.md"
expect_contains "finds key in a normally named code file (file+line+type)" "$REP" '| app | `app/Http/Controllers/PayController.php` | 3 | Razorpay live key | high | no |'
expect_contains "proposes that file as a guard candidate" "$REP" '| app | `app/Http/Controllers/PayController.php` | 1 | Razorpay live key |'
expect_contains "lists guarded files by name" "$REP" '| app | `lib/common_files/utilities/flavor_config.dart` |'
expect_absent "does not open .env (no finding for it)" "$(printf '%s' "$REP" | sed -n '/## All findings/,/## Already guarded/p')" ".env"
expect_absent "does not open flavor_config.dart" "$(printf '%s' "$REP" | sed -n '/## All findings/,/## Already guarded/p')" "flavor_config"
for v in "$F_RZP_LIVE" "$F_RZP_TEST" "$F_RZP_SECRET"; do expect_absent "report hides $v" "$REP$SOUT" "$v"; done

# ---------------------------------------------------------------- yaml2json
section "yaml2json (strict modules.yaml subset)"
Y="$S/yaml2json.sh"
cat > "$W/gen.yaml" <<'EOF'
# Generated by /atreya:map --merge. Edit by hand only in this format.
version: 1
generated: 2026-10-26
modules:
  - id: auth
    name: "Authentication"
    product: nt
    owner: TBD
    doc_status: none
    repos:
      - repo: Ashoka-World-Backend
        commit: 0123456789abcdef
        paths:
          - app/Http/Controllers/AuthController.php
          - routes/api.php
    routes:
      - "POST api/login"
      - "POST api/logout"
    screens: []
    in_use:
      dev: TBD
      staging: TBD
      production: TBD
unassigned_routes:
  - "GET api/ping"
EOF
# Same content, hand-edited: comments, blank lines, other key order, other
# quoting, CRLF line ends, extra spaces after the colon.
cat > "$W/hand.yaml" <<'EOF'
version: 1   # schema version
generated:   2026-10-26

modules:
  # the pilot module
  - name: 'Authentication'
    id: auth
    owner: TBD
    product: "nt"
    doc_status: none
    in_use:
      production: TBD
      staging: TBD
      dev: TBD
    repos:
      - commit: "0123456789abcdef"
        repo: Ashoka-World-Backend
        paths:
          - app/Http/Controllers/AuthController.php   # main controller
          - routes/api.php
    screens: []
    routes:
      - "POST api/login"
      - 'POST api/logout'
unassigned_routes:
  - "GET api/ping"
EOF
sed $'s/$/\r/' "$W/hand.yaml" > "$W/hand-crlf.yaml"
GJSON=$(bash "$Y" "$W/gen.yaml" 2>&1); RC=$?
expect_eq "valid file parses" "$RC" 0
expect_eq "module id" "$(printf '%s' "$GJSON" | /usr/bin/jq -r '.modules[0].id')" auth
expect_eq "nested list (paths)" "$(printf '%s' "$GJSON" | /usr/bin/jq -r '.modules[0].repos[0].paths | length')" 2
expect_eq "commit hash stays a string" "$(printf '%s' "$GJSON" | /usr/bin/jq -r '.modules[0].repos[0].commit | type')" string
expect_eq "empty list []" "$(printf '%s' "$GJSON" | /usr/bin/jq -c '.modules[0].screens')" "[]"
expect_eq "nested map (in_use)" "$(printf '%s' "$GJSON" | /usr/bin/jq -r '.modules[0].in_use.staging')" TBD
expect_eq "hand-edited valid file = same data" "$(bash "$Y" "$W/hand.yaml" | /usr/bin/jq -S -c .)" "$(printf '%s' "$GJSON" | /usr/bin/jq -S -c .)"
expect_eq "CRLF line ends accepted" "$(bash "$Y" "$W/hand-crlf.yaml" 2>&1 | /usr/bin/jq -S -c . 2>&1)" "$(printf '%s' "$GJSON" | /usr/bin/jq -S -c .)"
inv() {  # inv LABEL EXPECTED_LINE CONTENT
  printf '%s\n' "$3" > "$W/bad.yaml"
  local out rc; out=$(bash "$Y" "$W/bad.yaml" 2>&1 >/dev/null); rc=$?
  if [ $rc = 1 ] && case "$out" in *"bad.yaml:$2:"*) true ;; *) false ;; esac; then ok "invalid → fail at line $2: $1"
  else bad "invalid → fail at line $2: $1" "rc=$rc out=$out"; fi
}
inv "tab indentation"            3 $'modules:\n  - id: a\n\tname: x'
inv "odd indentation"            3 $'modules:\n  - id: a\n     name: x'
inv "flow list with content"     2 $'id: a\nroutes: [a, b]'
inv "anchor"                     2 $'id: a\nbase: &b x'
inv "duplicate key"              3 $'id: a\nname: x\nid: b'
inv "unterminated quote"         2 $'id: a\nname: "Auth'
inv "list not indented under key" 3 $'id: a\nroutes:\n- x'
inv "plain value with ': '"      2 $'id: a\nname: Auth: login'
inv "top-level list"             1 $'- id: a'
inv "block scalar"               2 $'id: a\nnote: |\n  text'
inv "bad key"                    2 $'id: a\n"quoted key": x'
expect_eq "front matter of a .md doc" "$(printf -- '---\nmodule: auth\nstatus: Draft\ncommits:\n  Ashoka-World-Backend: abc123\n---\n# PRD\n' > "$W/doc.md"; bash "$Y" --front-matter "$W/doc.md" | /usr/bin/jq -r '.status + " " + .commits["Ashoka-World-Backend"]')" "Draft abc123"
printf -- '---\nmodule: auth\nstatus: [x, y]\n---\n' > "$W/doc2.md"
expect_contains "front-matter error uses the file's line number" "$(bash "$Y" --front-matter "$W/doc2.md" 2>&1)" "doc2.md:3:"

# ---------------------------------------------------------------- map scripts
section "map: fixture repos (Laravel backend + frontend, Flutter app)"
W2="$W/ws2"; R2="$W2/repos"; mkdir -p "$R2" "$W2/atreya-docs" "$W2/atreya-qa"
CANARY=CANARY_GUARDED_42
gitinit() { ( cd "$1" && git init -q -b master && git add -A && git -c user.name=t -c user.email=t@t commit -q -m init ); }
B2="$R2/be"; mkdir -p "$B2/routes" "$B2/app/Providers" "$B2/app/Http/Controllers/Admin" "$B2/app/Models" "$B2/app/Services" "$B2/database/migrations" "$B2/resources/views/auth" "$B2/resources/views/reports"
cat > "$B2/app/Providers/RouteServiceProvider.php" <<'EOF'
<?php
namespace App\Providers;
class RouteServiceProvider {
    public function boot() {
        // we removed the prefix('api') on purpose
        Route::middleware('api')
            ->prefix('')
            ->group(base_path('routes/api.php'));
        Route::middleware('web')->group(base_path('routes/web.php'));
    }
}
EOF
cat > "$B2/routes/api.php" <<'EOF'
<?php
use App\Http\Controllers\AuthController;
use App\Http\Controllers\Admin\ReportController as RC;
use Illuminate\Support\Facades\Route;
Route::post('/login', [AuthController::class, 'login']);
// Route::post('/old-login', [AuthController::class, 'old']);
Route::group(['prefix' => 'otp', 'middleware' => ['throttle']], function () {
    Route::post('send', [AuthController::class, 'sendOtp']);
    Route::group(['prefix' => 'v2'], function () {
        Route::post('/send/{id}', [AuthController::class, 'sendOtpV2'])->name('otp.v2');
    });
});
Route::middleware(['auth.token'])->group(function () {
    Route::get('/report/{id}', [RC::class, 'show']);
    Route::match(['get', 'post'], '/report-list', [RC::class, 'index']);
});
Route::get('/ping', function () { return 'ok'; });
Route::post('/login', [AuthController::class, 'loginV2']);
/* Route::get('/blocked', [AuthController::class, 'x']); */
EOF
echo '<?php' > "$B2/routes/web.php"
cat > "$B2/app/Http/Controllers/AuthController.php" <<'EOF'
<?php
namespace App\Http\Controllers;
use App\Models\User;
class authController extends Controller
{
    public function login() {
        $u = User::where('a', 1)->first();
        DB::table('otp_logs')->insert([]);
        return view('auth.welcome');
    }
    public function sendOtp() { return 1; }
    public function sendOtpV2($id) { return 2; }
    public function loginV2() { return new User(); }
}
EOF
cat > "$B2/app/Http/Controllers/Admin/ReportController.php" <<'EOF'
<?php
namespace App\Http\Controllers\Admin;
use App\Models\Report;
class ReportController extends Controller
{
    public function show($id) { $r = Report::find($id); return view('reports.show'); }
    public function index() { return Report::all(); }
}
EOF
printf '<?php\nclass SamvitPaymentBridgeController { function x() { return view("%s"); } }\n' "$CANARY" > "$B2/app/Http/Controllers/SamvitPaymentBridgeController.php"
cat > "$B2/app/Models/User.php" <<'EOF'
<?php
namespace App\Models;
class User extends Model
{
    protected $table = 'users';
    protected $fillable = ['name', 'email'];
    public function reports() { return $this->hasMany(Report::class); }
}
EOF
printf '<?php\nnamespace App\\Models;\nclass Report extends Model {}\n' > "$B2/app/Models/Report.php"
cat > "$B2/database/migrations/2024_01_01_000000_create_users.php" <<'EOF'
<?php
return new class extends Migration {
    public function up() {
        Schema::create('users', function (Blueprint $table) {
            $table->id();
            $table->string('name');
            $table->timestamps();
        });
    }
    public function down() { Schema::dropIfExists('users'); }
};
EOF
printf '<?php\n// Razorpay order\n$u = "https://api.paygateway-test.org/v1";\n' > "$B2/app/Services/Pay.php"
echo '<h1>welcome</h1>' > "$B2/resources/views/auth/welcome.blade.php"; echo '<p>report</p>' > "$B2/resources/views/reports/show.blade.php"
gitinit "$B2"
F2="$R2/fe"; mkdir -p "$F2/routes" "$F2/app/Http/Controllers" "$F2/resources/views/auth" "$F2/resources/views/layouts"
printf "<?php\nuse App\\\\Http\\\\Controllers\\\\LoginController;\nRoute::get('/login', [LoginController::class, 'show'])->name('login');\nRoute::post('/register', [LoginController::class, 'register']);\n" > "$F2/routes/web.php"
printf "<?php\nRoute::get('/user', function () { return 1; });\n" > "$F2/routes/api.php"
printf "<?php\nnamespace App\\\\Http\\\\Controllers;\nclass loginController extends Controller {\n  public function show() { return view('auth.login'); }\n  public function register() { return 1; }\n}\n" > "$F2/app/Http/Controllers/LoginController.php"
printf '<a href="{{ route('"'"'login'"'"') }}">x</a>\n<form action="/register"></form>\n' > "$F2/resources/views/auth/login.blade.php"
echo '<html>@yield("c")</html>' > "$F2/resources/views/layouts/app.blade.php"
gitinit "$F2"
A2="$R2/ap"; mkdir -p "$A2/lib/route" "$A2/lib/login" "$A2/lib/home"
cat > "$A2/lib/route/router.dart" <<'EOF'
final router = GoRouter(
  routes: [
    GoRoute(
      path: '/login',
      name: 'login',
      pageBuilder: (context, state) => state.withTransition(
        BlocProvider<LoginBloc>(create: (c) => LoginBloc(), child: const LoginScreen()),
      ),
    ),
    GoRoute(
      path: '/home',
      name: 'home',
      builder: (context, state) => const HomeScreen(),
    ),
  ],
);
EOF
printf "class LoginScreen extends StatelessWidget {\n  void go(BuildContext context) { context.go('/home'); context.pushNamed('home'); }\n}\n" > "$A2/lib/login/login_screen.dart"
printf "class HomeScreen extends StatefulWidget {}\nclass OrphanScreen extends StatelessWidget {}\n" > "$A2/lib/home/home_screen.dart"
gitinit "$A2"

M="$S"; RT="--root $W2"; MAP="$W2/atreya-docs/_map"
for r in be fe; do for s in routes models controllers; do bash "$M/$s.sh" $RT $r >/dev/null 2>"$W/err.$s.$r" || bad "$s.sh $r runs" "$(cat "$W/err.$s.$r")"; done; done
for r in be fe ap; do for s in screens externals cluster; do bash "$M/$s.sh" $RT $r >/dev/null 2>"$W/err.$s.$r" || bad "$s.sh $r runs" "$(cat "$W/err.$s.$r")"; done; done
J() { /usr/bin/jq -r "$2" "$MAP/$1" 2>&1; }
expect_eq "api.php prefix from RouteServiceProvider, comment ignored" "$(J be/routes.json '.route_files[] | select(.file=="routes/api.php") | "\(.prefix)|\(.prefix_source)"')" "|RouteServiceProvider"
expect_eq "Laravel default prefix when provider missing" "$(J fe/routes.json '.route_files[] | select(.file=="routes/api.php") | "\(.prefix)|\(.prefix_source)"')" "api|Laravel default"
expect_eq "unique route keys" "$(J be/routes.json '[.routes[] | select(.shadowed|not) | .key] | sort | join(",")')" "GET ping,GET report-list,GET report/{id},POST login,POST otp/send,POST otp/v2/send/{id},POST report-list"
expect_eq "nested group prefix + middleware + name" "$(J be/routes.json '.routes[] | select(.key=="POST otp/v2/send/{id}") | "\(.middleware|join(","))|\(.name)"')" "throttle|otp.v2"
expect_eq "aliased controller resolved (use ... as RC)" "$(J be/routes.json '.routes[] | select(.key=="GET report/{id}") | "\(.controller)|\(.middleware|join(","))|\(.controller_status)"')" 'App\Http\Controllers\Admin\ReportController|auth.token|found'
expect_eq "Route::match expands to GET and POST" "$(J be/routes.json '[.routes[] | select(.uri=="report-list") | .method] | sort | join(",")')" "GET,POST"
expect_eq "closure route" "$(J be/routes.json '.routes[] | select(.key=="GET ping") | .kind')" "closure"
expect_eq "later duplicate shadows earlier one" "$(J be/routes.json '[.routes[] | select(.key=="POST login") | "\(.action):\(.shadowed)"] | sort | join(",")')" "login:true,loginV2:false"
expect_eq "counts: unparsed 0, commented-out 2" "$(J be/routes.json '"\(.counts.unparsed),\(.counts.commented_out_lines)"')" "0,2"
expect_eq "model table declared vs inferred" "$(J be/models.json '[.models[] | "\(.class):\(.table):\(.table_source)"] | join(",")')" "Report:reports:inferred,User:users:declared"
expect_eq "migration columns" "$(J be/models.json '.tables[] | select(.name=="users") | .columns | map(.name) | join(",")')" "created_at,id,name,updated_at"
expect_eq "relation" "$(J be/models.json '.models[] | select(.class=="User") | .relations[0] | "\(.method):\(.type):\(.target)"')" "reports:hasMany:Report"
expect_eq "controller method → models, tables, views" "$(J be/controllers.json '.controllers[] | select(.fqcn|test("authController")) | .methods[] | select(.name=="login") | "\(.models|join(","))|\(.tables|join(","))|\(.views|join(","))"')" 'App\Models\User|otp_logs,users|auth.welcome'
expect_eq "guarded controller listed, not opened" "$(J be/controllers.json '.guarded_files | join(",")')" "app/Http/Controllers/SamvitPaymentBridgeController.php"
expect_absent "canary from guarded file appears in no _map output" "$(cat "$MAP"/*/* 2>/dev/null)" "$CANARY"
expect_eq "blade view ← controller (case-insensitive) ← route" "$(J fe/screens.json '.screens[] | select(.id=="auth.login") | "\(.rendered_by[0].method)|\(.routes|join(","))"')" "show|GET login"
expect_eq "blade links: route() name and form action" "$(J fe/screens.json '.screens[] | select(.id=="auth.login") | [.links_to[] | (.route // .url)] | sort | join(",")')" "/register,GET login"
expect_eq "layouts are partials" "$(J fe/screens.json '.screens[] | select(.id=="layouts.app") | .partial')" "true"
expect_eq "GoRoute → screen class (inside BlocProvider)" "$(J ap/screens.json '.go_routes | map("\(.path)=\(.class)") | join(",")')" "/login=LoginScreen,/home=HomeScreen"
expect_eq "flutter navigation (path and named)" "$(J ap/screens.json '.screens[] | select(.id=="LoginScreen") | [.navigates_to[].path] | unique | join(",")')" "/home"
expect_eq "screen class without route" "$(J ap/screens.json '.counts.screen_classes_without_route')" "1"
expect_eq "external system by file:line only" "$(J be/externals.json '.systems[] | select(.system=="Razorpay") | .files[0] | "\(.file):\(.lines|join(","))"')" "app/Services/Pay.php:2"
expect_contains "other third-party host listed" "$(J be/externals.json '[.other_hosts[].host] | join(",")')" "api.paygateway-test.org"

section "map: build-modules (preview, conflicts, write, keep human fields)"
P="$W/prop.yaml"
cat > "$P" <<'EOF'
backend: be
modules:
  - id: auth
    name: "Authentication"
    repos:
      - repo: be
        controllers:
          - AuthController
      - repo: fe
        controllers:
          - LoginController
      - repo: ap
        paths:
          - lib/login/
  - id: reports
    name: "Reports"
    critical: true
    repos:
      - repo: be
        controllers:
          - ReportController
EOF
PV=$(bash "$M/build-modules.sh" $RT --from "$P" 2>&1); RC=$?
expect_eq "clean proposal previews with exit 0" "$RC" 0
expect_contains "coverage line" "$PV" "6 of 7 routes assigned, 1 unassigned"
expect_contains "preview row with route counts" "$PV" "| auth | Authentication |"
expect_absent "preview writes nothing" "$(ls "$W2/atreya-docs")" "modules.yaml"
sed 's/          - ReportController/          - ReportController\n          - AuthController/' "$P" | awk '{ gsub(/\\n/, "\n          "); print }' > "$W/conf.yaml"
printf '%s\n' 'backend: be' 'modules:' '  - id: a' '    name: "A"' '    repos:' '      - repo: be' '        controllers:' '          - AuthController' '  - id: b' '    name: "B"' '    repos:' '      - repo: be' '        controllers:' '          - authcontroller' > "$W/conf.yaml"
CV=$(bash "$M/build-modules.sh" $RT --from "$W/conf.yaml" 2>&1); RC=$?
expect_eq "conflict → exit 1" "$RC" 1
expect_contains "conflict listed (case-insensitive controller match)" "$CV" "POST login: a, b"
printf '%s\n' 'backend: be' 'modules:' '  - id: x' '    name: "X"' '    repos:' '      - repo: be' '        controllers:' '          - NoSuchController' > "$W/unk.yaml"
expect_contains "unknown controller → error" "$(bash "$M/build-modules.sh" $RT --from "$W/unk.yaml" 2>&1)" "unknown controller NoSuchController in be"
bash "$M/build-modules.sh" $RT --from "$P" --write >/dev/null 2>&1
MJ=$(bash "$S/yaml2json.sh" "$W2/atreya-docs/modules.yaml" 2>&1)
expect_eq "written modules.yaml round-trips through yaml2json" "$(printf '%s' "$MJ" | /usr/bin/jq -r '.modules | map(.id) | join(",")')" "auth,reports"
expect_eq "unassigned routes recorded" "$(printf '%s' "$MJ" | /usr/bin/jq -r '.unassigned_routes | join(",")')" "GET ping"
expect_eq "module routes, web routes, screens, tables" "$(printf '%s' "$MJ" | /usr/bin/jq -r '.modules[0] | "\(.routes|length)|\(.web_routes[0].routes|join(","))|\(.screens|map(.path)|join(","))|\(.tables|join(","))"')" "3|GET login,POST register|lib/login/login_screen.dart,resources/views/auth/welcome.blade.php,resources/views/auth/login.blade.php|otp_logs,users"
expect_eq "critical flag kept" "$(printf '%s' "$MJ" | /usr/bin/jq -r '.modules[1].critical')" "true"
sed -i '' 's/    owner: "TBD"/    owner: "Mohini"/' "$W2/atreya-docs/modules.yaml"
bash "$M/build-modules.sh" $RT --from "$P" --write >/dev/null 2>&1
expect_eq "re-write keeps human-owned owner" "$(bash "$S/yaml2json.sh" "$W2/atreya-docs/modules.yaml" | /usr/bin/jq -r '.modules[0].owner')" "Mohini"
expect_contains "coverage.sh checks the current modules.yaml" "$(bash "$M/coverage.sh" $RT 2>&1)" "6 of 7 routes assigned"

section "map: seed docs and determinism"
SD=$(bash "$M/seed-docs.sh" $RT 2>&1)
expect_contains "seeds environments.md" "$SD" "wrote $W2/atreya-docs/environments.md"
expect_contains "environments.md is all TO FILL" "$(cat "$W2/atreya-docs/environments.md")" "| staging | TO FILL |"
expect_contains "external-systems.md lists file:line" "$(cat "$W2/atreya-docs/external-systems.md")" '`app/Services/Pay.php:2`'
expect_contains "not-in-use.md has the confirmed Receptionist item" "$(cat "$W2/atreya-docs/not-in-use.md")" "| Receptionist |"
expect_contains "second run keeps existing docs" "$(bash "$M/seed-docs.sh" $RT 2>&1)" "kept $W2/atreya-docs/not-in-use.md"
H1=$(cd "$MAP" && cat be/*.json fe/*.json ap/*.json be/*.md fe/*.md ap/*.md | shasum)
for r in be fe; do for s in routes models controllers; do bash "$M/$s.sh" $RT $r >/dev/null 2>&1; done; done
for r in be fe ap; do for s in screens externals cluster; do bash "$M/$s.sh" $RT $r >/dev/null 2>&1; done; done
H2=$(cd "$MAP" && cat be/*.json fe/*.json ap/*.json be/*.md fe/*.md ap/*.md | shasum)
expect_eq "re-running every map script gives byte-identical output" "$H2" "$H1"

# ---------------------------------------------------------------- link-apis
section "link-apis: client calls → backend routes"
cat > "$F2/app/Http/Controllers/ApiController.php" <<'EOF'
<?php
namespace App\Http\Controllers;
class ApiController extends Controller
{
    public function doLogin($id) {
        $backendUrl = config('app.backend_url');
        $r = Http::asJson()->post("$backendUrl/login", ['a' => 1]);
        $r2 = Http::asJson()->get($backendUrl . '/report/' . $id);
        $u = "$backendUrl/otp/send";
        $r3 = Http::asJson()->post($u, []);
        $r4 = Http::asJson()->post("$backendUrl/missing-endpoint", []);
        $r5 = Http::asJson()->post("$backendUrl/{$id}", []);
        return view('auth.login', ['url' => $backendUrl . "/ping?x=" . $id]);
    }
}
EOF
printf "Route::get('/do-login/{id}', [App\\\\Http\\\\Controllers\\\\ApiController::class, 'doLogin']);\n" >> "$F2/routes/web.php"
mkdir -p "$A2/lib/common_files/constants" "$A2/lib/common_files/api_services" "$A2/lib/login/bloc"
cat > "$A2/lib/common_files/constants/strings_const.dart" <<'EOF'
class StringsConst {
  final String loginUrl = "${AppEnvironment.baseUrl}/login";
  final String otpUrl = '${AppEnvironment.baseUrl}/otp/v2/send';
  // final String oldUrl = "${AppEnvironment.baseUrl}/old";
  final String chatbotBaseUrl = "https://chatbot.example-lambda.test";
}
EOF
cat > "$A2/lib/common_files/api_services/api_repository.dart" <<'EOF'
class ApiRepository {
  Future<Map<String, dynamic>> loginUser({required String u}) async {
    final response = await _http.request(
      url: StringsConst().loginUrl,
      method: MethodType.post,
    );
  }
  Future<void> sendOtp(String id) async {
    final r = await _http.request(url: "${StringsConst().otpUrl}/$id", method: MethodType.post);
  }
  Future<void> chat() async {
    final r = await _http.request(url: StringsConst().chatbotBaseUrl, method: MethodType.post);
  }
}
EOF
printf "class LoginBloc {\n  void go() { repo.loginUser(u: 'x'); repo.sendOtp('1'); }\n}\n" > "$A2/lib/login/bloc/login_bloc.dart"
# LoginScreen uses the bloc; ForgotScreen (same folder) does not
printf "class _LoginState {\n  final bloc = LoginBloc();\n}\n" >> "$A2/lib/login/login_screen.dart"
printf "class ForgotScreen extends StatelessWidget {}\n" > "$A2/lib/login/forgot_screen.dart"
for d in "$F2" "$A2"; do ( cd "$d" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m calls ); done
for s in routes controllers screens; do bash "$M/$s.sh" $RT fe >/dev/null 2>&1; done
bash "$M/screens.sh" $RT ap >/dev/null 2>&1
for r in fe ap; do bash "$M/calls.sh" $RT $r >/dev/null 2>"$W/err.calls.$r" || bad "calls.sh $r runs" "$(cat "$W/err.calls.$r")"; done
expect_eq "Laravel: interpolated, concat ('/report/' . \$id), URL variable, config literal" \
  "$(J fe/calls.json '[.calls[] | select(.form != "link" and .path != null) | "\(.method) \(.path)"] | sort | join(",")')" \
  "GET /report/{},POST /login,POST /missing-endpoint,POST /otp/send"
expect_eq "Laravel: URL in an array is a link; query string dropped" "$(J fe/calls.json '[.calls[] | select(.form == "link") | .path] | join(",")')" "/ping"
expect_contains "Laravel: fully dynamic path is unresolved" "$(J fe/calls.json '.unresolved | map(.reason) | join(",")')" "path is fully dynamic"
expect_eq "Laravel: call context = controller@method" "$(J fe/calls.json '.calls[] | select(.path == "/login") | "\(.controller)@\(.action)"')" 'App\Http\Controllers\ApiController@doLogin'
expect_eq "Flutter: StringsConst constants (+ dynamic suffix), commented constant ignored" \
  "$(J ap/calls.json '[.calls[] | select(.path != null) | "\(.method) \(.path)"] | sort | join(",")')" "POST /login,POST /otp/v2/send/{}"
expect_contains "Flutter: non-baseUrl constant (chatbot) is unresolved" "$(J ap/calls.json '.unresolved | map(.reason) | join(",")')" "chatbotBaseUrl is not a backend baseUrl constant"
expect_eq "Flutter: 2nd hop (repository method → the line that calls it)" "$(J ap/calls.json '.calls[] | select(.path == "/login") | "\(.dart_method):\(.callers | join(","))"')" "loginUser:lib/login/bloc/login_bloc.dart:2"
LA=$(bash "$M/link-apis.sh" $RT --module auth --update-not-in-use 2>&1)
expect_eq "fe summary" "$(printf '%s\n' "$LA" | grep '^link-apis: fe:')" "link-apis: fe: 6 calls → 4 matched (4 with a page, 0 without), 0 method mismatch, 1 no route, 1 unresolved, 0 from dead code; overrides 0 applied, 0 unused"
expect_eq "ap summary" "$(printf '%s\n' "$LA" | grep '^link-apis: ap:')" "link-apis: ap: 3 calls → 2 matched (2 with a page, 0 without), 0 method mismatch, 0 no route, 1 unresolved, 0 from dead code; overrides 0 applied, 0 unused"
expect_contains "an empty overrides.yaml is created once" "$LA" "created $W2/atreya-docs/_map/overrides.yaml (empty)"
expect_eq "matched to the live (non-shadowed) route and controller" "$(J fe/api-links.json '.links[] | select(.endpoint == "/login") | "\(.route)|\(.controller)|\(.module)"')" "POST login|AuthController@loginV2|auth"
expect_eq "{} matches a {param} route" "$(J fe/api-links.json '.links[] | select(.endpoint == "/report/{}") | .route')" "GET report/{id}"
expect_eq "link with unknown method matches any method" "$(J fe/api-links.json '.links[] | select(.endpoint == "/ping") | "\(.status)|\(.route)"')" "matched|GET ping"
expect_eq "no-route call reported" "$(J fe/api-links.json '[.links[] | select(.status == "no-route") | .endpoint] | join(",")')" "/missing-endpoint"
expect_eq "pages are real pages (the rendered view); web routes listed apart" "$(J fe/api-links.json '.links[] | select(.endpoint == "/login") | "\(.pages | join(","))|\(.web_routes | join(","))"')" "auth.login|GET do-login/{id}"
expect_eq "App screen via the bloc it uses (not every screen in the folder)" "$(J ap/api-links.json '.links[] | select(.endpoint == "/login") | .pages | join(",")')" "LoginScreen"
expect_eq "calls.json records the screens that use the caller (bloc)" "$(J ap/calls.json '.calls[] | select(.path == "/login") | .screen_files | join(",")')" "lib/login/login_screen.dart"
expect_eq "models/tables of the matched controller method" "$(J ap/api-links.json '.links[] | select(.endpoint == "/otp/v2/send/{}") | "\(.route)|\(.controller)"')" "POST otp/v2/send/{id}|AuthController@sendOtpV2"
expect_contains "backend: routes no screen calls, per module" "$(cat "$MAP/be/api-links.md")" '### reports ('
expect_contains "backend: Route::match counted once (report-list not called)" "$(cat "$MAP/be/api-links.md")" '`GET report-list`'
NIU1=$(cat "$W2/atreya-docs/not-in-use.md")
expect_eq "re-running the not-in-use refresh prints no warning (macOS awk)" "$(bash "$M/link-apis.sh" $RT --update-not-in-use 2>&1 >/dev/null)" ""
expect_eq "not-in-use block replaced, not duplicated" "$(grep -c 'link-apis:start' "$W2/atreya-docs/not-in-use.md")" "1"
expect_eq "re-running the refresh leaves not-in-use.md unchanged" "$(cat "$W2/atreya-docs/not-in-use.md")" "$NIU1"
expect_contains "human part of not-in-use.md kept" "$(cat "$W2/atreya-docs/not-in-use.md")" "| Receptionist |"
expect_contains "module summary" "$LA" "module auth ← fe:"

# ---------------------------------------------------------------- prd/brd support scripts
section "docs: module-facts, doc-stamp, staging-delta, check-doc"
cat > "$B2/app/Http/Controllers/AuthController.php" <<'EOF'
<?php
namespace App\Http\Controllers;
use App\Models\User;
class authController extends Controller
{
    public function login() {
        $u = User::where('a', 1)->first();
        DB::table('otp_logs')->insert([]);
        return view('auth.welcome');
    }
    public function sendOtp() { return 1; }
    public function sendOtpV2($id) { return 2; }
    public function loginV2($r) {
        $validator = Validator::make($r, [
            'user_name' => 'required|string',
            'password' => 'required',
        ]);
        if ($validator->fails()) {
            return response()->json([
                'status' => false,
                'message' => 'Username is required'
            ], 400);
        }
        return new User();
    }
}
EOF
( cd "$B2" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m validate )
for s in routes models controllers; do bash "$M/$s.sh" $RT be >/dev/null 2>&1; done
MF=$(bash "$M/module-facts.sh" $RT auth 2>&1); FJ="$MAP/_modules/auth/facts.json"
expect_contains "module-facts summary" "$MF" "facts: auth: 3 backend routes (1 with validation rules, 1 with error messages)"
expect_eq "validation rules with source line" "$(/usr/bin/jq -r '.backend_routes[] | select(.key == "POST login") | .validation | map("\(.field)=\(.rules)@\(.source | split(":") | last)") | join(",")' "$FJ")" "user_name=required|string@15,password=required@16"
expect_eq "error message with HTTP code" "$(/usr/bin/jq -r '.backend_routes[] | select(.key == "POST login") | .errors[0] | "\(.http) \(.message)"' "$FJ")" "400 Username is required"
expect_contains "required languages listed with their source" "$(/usr/bin/jq -r '.languages | "\(.required | join(",")) \(.required_source)"' "$FJ")" "English,Marathi,Hindi,Czech,German,Spanish,Italian references/qa-scope-rules.md"
expect_contains "facts.md has route section" "$(cat "$MAP/_modules/auth/facts.md")" "### POST login"
ST=$(bash "$M/doc-stamp.sh" $RT auth PRD 2>&1); printf '%s\n# x\n' "$ST" > "$W/stamp.md"
expect_eq "doc-stamp is valid front matter with commits of every module repo" "$(bash "$S/yaml2json.sh" --front-matter "$W/stamp.md" | /usr/bin/jq -r '"\(.status) \(.commits | keys | join(","))"')" "Draft ap,be,fe"
SDO=$(bash "$M/staging-delta.sh" $RT auth 2>&1)
expect_contains "staging-delta waits while refs are TO FILL" "$SDO" "repos waiting for environments.md: 3"
BEHEAD=$(git -C "$B2" rev-parse HEAD~1)
awk -v p="$BEHEAD" '/^## be$/ { inb = 1 } /^## / && !/^## be$/ { inb = 0 } inb && /^\| staging \|/ { $0 = "| staging | master | TO FILL | TO FILL | TO FILL |" } inb && /^\| production \|/ { $0 = "| production | " p " | TO FILL | TO FILL | TO FILL |" } { print }' "$W2/atreya-docs/environments.md" > "$W/env.md"
# fixture environments.md comes from the template, whose repo headings differ: add a be section
printf '\n## be\n\n| Env | Ref | Host | Feature flags | Integration mode |\n|---|---|---|---|---|\n| staging | master | TO FILL | TO FILL | TO FILL |\n| production | %s | TO FILL | TO FILL | TO FILL |\n' "$BEHEAD" >> "$W/env.md"
cp "$W/env.md" "$W2/atreya-docs/environments.md"
SDO=$(bash "$M/staging-delta.sh" $RT auth 2>&1); SD=$(cat "$W2/atreya-docs/nt/auth/staging-delta.md")
expect_contains "staging-delta lists commits only on staging" "$SD" "### Commits only on staging (1)"
expect_contains "staging-delta lists changed files" "$SD" "app/Http/Controllers/AuthController.php"
expect_absent "staging-delta never prints code" "$SD" "Validator::make"
expect_contains "other repos still waiting" "$SD" "## fe"
bash "$M/module-facts.sh" $RT auth >/dev/null 2>&1
expect_eq "fact pack copies the repo's environment rows verbatim (own header)" \
  "$(/usr/bin/jq -r '.environment.repos[] | select(.repo == "be") | "\(.columns | join(","))|\(.rows[0] | join(","))"' "$FJ")" \
  "Env,Ref,Host,Feature flags,Integration mode|staging,master,TO FILL,TO FILL,TO FILL"
# check-doc
mkprd() {  # mkprd FILE  (valid minimal PRD)
  { printf '%s\n' "$ST"; echo "# Auth PRD"; grep -E '^## [0-9]+\. ' "$PLUGIN/references/prd-template.md" | while IFS= read -r h; do
      echo "$h"; echo
      case "$h" in
        "## 4. "*) printf '### AUTH-R01: Log in\n**Acceptance criteria**\n- Given x then 400 "Username is required".\n**Source**: `be:routes/api.php:5`, `be:app/Http/Controllers/AuthController.php:20`\n\n' ;;
        "## 13. "*) printf '1. **PO:** question?\n\n' ;;
        *) printf 'Text.\n\n' ;;
      esac; done; } > "$1"
}
mkprd "$W/ok.md"
CD=$(bash "$M/check-doc.sh" $RT "$W/ok.md" 2>&1); RC=$?
expect_eq "check-doc passes a valid PRD" "$RC" 0
expect_contains "check-doc counts citations" "$CD" "all 2 code citations exist"
sed 's/AuthController.php:20/AuthController.php:999/' "$W/ok.md" > "$W/bad1.md"
expect_contains "check-doc: citation beyond end of file fails" "$(bash "$M/check-doc.sh" $RT "$W/bad1.md" 2>&1)" "AuthController.php:999 (file has"
sed 's#be:routes/api.php:5#be:routes/missing.php:5#' "$W/ok.md" > "$W/bad2.md"
expect_contains "check-doc: untracked file fails" "$(bash "$M/check-doc.sh" $RT "$W/bad2.md" 2>&1)" "be:routes/missing.php:5 (file not tracked)"
grep -v '^## 7\. ' "$W/ok.md" > "$W/bad3.md"
expect_contains "check-doc: missing heading fails" "$(bash "$M/check-doc.sh" $RT "$W/bad3.md" 2>&1)" "FAIL  headings match the PRD template"
awk '{ print } /^\*\*Source\*\*/ && !d { print ""; print "### AUTH-R01: Duplicate"; print "**Acceptance criteria**"; print "- x"; print "**Source**: `be:routes/api.php:5`"; d = 1 }' "$W/ok.md" > "$W/bad4.md"
expect_contains "check-doc: duplicate requirement ID fails" "$(bash "$M/check-doc.sh" $RT "$W/bad4.md" 2>&1)" "FAIL  requirement IDs AUTH-Rnn present and unique"
sed "s/^Text\.$/Key: $F_RZP_LIVE/" "$W/ok.md" > "$W/bad5.md"
expect_contains "check-doc: key-like string fails" "$(bash "$M/check-doc.sh" $RT "$W/bad5.md" 2>&1)" "FAIL  no key-like strings"
expect_absent "check-doc never prints the key" "$(bash "$M/check-doc.sh" $RT "$W/bad5.md" 2>&1)" "$F_RZP_LIVE"
# what a cited line holds: blank fails, brace-only warns; ranges are checked; short citations warn
AC2=app/Http/Controllers/AuthController.php
BRL=$(awk '/^[ \t]*}[ \t]*$/ { print NR; exit }' "$B2/$AC2")
printf '<?php\n\n// a helper with a blank line 2\n' > "$B2/app/Services/Cite.php"
( cd "$B2" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m cite )
BLF=app/Services/Cite.php; BLL=2
CL() { sed "s#be:$AC2:20#$1#" "$W/ok.md" > "$W/cl.md"; bash "$M/check-doc.sh" $RT "$W/cl.md" 2>&1; }
expect_contains "check-doc: a cited blank line fails" "$(CL "be:$BLF:$BLL")" "be:$BLF:$BLL (line $BLL is blank)"
O=$(CL "be:$AC2:$BRL"); expect_contains "check-doc: a cited brace-only line is a warning" "$O" "WARN  cited lines that hold only a brace"
expect_contains "check-doc: …and does not fail the doc" "$O" "check-doc: PASS"
expect_contains "check-doc: a range is checked (and passes)" "$(CL "be:$AC2:1-3")" "all 2 code citations exist"
expect_contains "check-doc: a backwards range fails" "$(CL "be:$AC2:3-1")" "(range 3-1 runs backwards)"
expect_contains "check-doc: a range past the end of the file fails" "$(CL "be:$AC2:1-999")" "be:$AC2:1-999 (file has"
expect_contains "check-doc: every line of a list is checked" "$(CL "be:$AC2:1,999")" "be:$AC2:1,999 (file has"
O=$(sed 's/^Text\.$/Text `AuthController.php:20` and `:5`./' "$W/ok.md" > "$W/cl.md"; bash "$M/check-doc.sh" $RT "$W/cl.md" 2>&1)
expect_contains "check-doc: short citations are a warning" "$O" "WARN  2 citation(s) without the repo cannot be checked"
expect_contains "check-doc: …and do not fail the doc" "$O" "check-doc: PASS"

# ---------------------------------------------------------------- diagrams
section "diagrams: specs from code, deterministic draw.io, checks"
bash "$M/module-facts.sh" $RT auth >/dev/null 2>&1
DS() { bash "$M/diagram-spec.sh" $RT auth "$@" 2>&1; }
ER=$(DS er)
expect_eq "ER: the module's tables" "$(printf '%s' "$ER" | /usr/bin/jq -r '[.nodes[].id] | join(",")')" "otp_logs,users"
expect_eq "ER: columns from migrations; table without migration says so (render)" "$(printf '%s' "$ER" | /usr/bin/jq -r '.nodes[] | select(.id == "users") | .columns | join(",")')" "created_at,id,name,updated_at"
expect_eq "ER: relation to a table outside the module is left out" "$(printf '%s' "$ER" | /usr/bin/jq -r '.edges | length')" "0"
SQ=$(DS sequence --routes "POST login" --name seq-AUTH-R01)
expect_eq "sequence: participants in order screen, clients, route, controller, tables" \
  "$(printf '%s' "$SQ" | /usr/bin/jq -r '[.nodes[] | .type] | join(",")')" "screen,screen,client,client,route,controller,db"
expect_eq "sequence: messages in user order, response with HTTP code from code" \
  "$(printf '%s' "$SQ" | /usr/bin/jq -r '[.edges[].label] | join(" | ")')" \
  "uses loginUser | POST /login | uses ApiController@doLogin | POST /login | AuthController@loginV2 | uses users | response 400"
expect_contains "sequence: every message cites code" "$(printf '%s' "$SQ" | /usr/bin/jq -r '[.edges[] | select(.source == "")] | length')" "0"
expect_contains "sequence: unknown route is refused" "$(DS sequence --routes "POST nope")" "unknown route(s) for this module: POST nope"
expect_eq "sequence: --callers keeps only the named callers" "$(DS sequence --routes "POST login" --callers "loginUser" | /usr/bin/jq -r '[.nodes[] | select(.type == "client") | .label] | join(",")')" "loginUser"
SQO=$(DS sequence --routes "POST login" --callers "loginUser" --name seq-X --title "X: t")
expect_eq "spec records only the options given" "$(printf '%s' "$SQO" | /usr/bin/jq -c '.options')" '{"routes":"POST login","callers":"loginUser","name":"seq-X","title":"X: t"}'
OPTX=(); while IFS=$'\t' read -r k v; do OPTX+=("--$k" "$v"); done < <(printf '%s' "$SQO" | /usr/bin/jq -r '.options | to_entries[] | "\(.key)\t\(.value)"')
expect_eq "options read back from the spec regenerate the same spec" "$(DS sequence "${OPTX[@]}" | shasum)" "$(printf '%s\n' "$SQO" | shasum)"
expect_eq "ER spec records no options when none are given" "$(DS er | /usr/bin/jq -c '.options')" '{}'
FL=$(DS flow --platform app)
expect_eq "flow: navigation with file:line; target outside the module is external" \
  "$(printf '%s' "$FL" | /usr/bin/jq -r '.edges[] | "\(.from)->\(.to) \(.source)"')" "s-loginscreen->x-homescreen ap:lib/login/login_screen.dart:2"
MD=$(bash "$M/make-diagram.sh" $RT auth sequence --routes "POST login" --name seq-AUTH-R01 2>&1)
expect_contains "make-diagram renders and the diagram passes check-doc" "$MD" "check-doc: PASS"
DD="$W2/atreya-docs/nt/auth/diagrams"
expect_eq "make-diagram keeps the spec next to the diagram" "$(ls "$DD" | tr '\n' ' ')" "seq-AUTH-R01.drawio seq-AUTH-R01.spec.json "
expect_contains "drawio: well-formed XML" "$(xmllint --noout "$DD/seq-AUTH-R01.drawio" 2>&1 && echo XMLOK)" "XMLOK"
expect_contains "drawio: stamp with commits" "$(grep -o 'atreya_commits="[^"]*"' "$DD/seq-AUTH-R01.drawio")" "be="
expect_contains "drawio: each box carries its source" "$(cat "$DD/seq-AUTH-R01.drawio")" 'atreya_source="be:routes/api.php:'
H1=$(shasum < "$DD/seq-AUTH-R01.drawio"); bash "$M/drawio.sh" "$DD/seq-AUTH-R01.spec.json" "$DD/again.drawio" >/dev/null
expect_eq "drawio: same spec gives a byte-identical file" "$(shasum < "$DD/again.drawio")" "$H1"
rm -f "$DD/again.drawio"
bash "$M/make-diagram.sh" $RT auth sequence --routes "POST login" --callers "loginUser" --name seq-AUTH-R09 --title "AUTH-R09: t" >/dev/null 2>&1
H9=$(cat "$DD/seq-AUTH-R09.spec.json" "$DD/seq-AUTH-R09.drawio" | shasum)
expect_contains "make-diagram --rerun regenerates from the saved options" "$(bash "$M/make-diagram.sh" $RT auth --rerun seq-AUTH-R09 2>&1)" "check-doc: PASS"
expect_eq "make-diagram --rerun gives byte-identical spec and diagram" "$(cat "$DD/seq-AUTH-R09.spec.json" "$DD/seq-AUTH-R09.drawio" | shasum)" "$H9"
/usr/bin/jq 'del(.options)' "$DD/seq-AUTH-R09.spec.json" > "$W/old.json"; cp "$W/old.json" "$DD/seq-AUTH-R09.spec.json"
expect_contains "make-diagram --rerun refuses a spec without saved options" "$(bash "$M/make-diagram.sh" $RT auth --rerun seq-AUTH-R09 2>&1)" "has no saved options"
expect_contains "make-diagram --rerun refuses a bad name" "$(bash "$M/make-diagram.sh" $RT auth --rerun ../x 2>&1)" "usage: make-diagram.sh --root R MODULE --rerun NAME"
rm -f "$DD/seq-AUTH-R09.spec.json" "$DD/seq-AUTH-R09.drawio"
/usr/bin/jq '.nodes[0].source = ""' "$DD/seq-AUTH-R01.spec.json" > "$W/nosrc.json"; bash "$M/drawio.sh" "$W/nosrc.json" "$W/nosrc.drawio" >/dev/null
expect_contains "check-doc: a box without a source fails" "$(bash "$M/check-doc.sh" $RT "$W/nosrc.drawio" 2>&1)" "FAIL  every box and arrow has a source"
/usr/bin/jq '.nodes[1].source = "be:routes/api.php:999"' "$DD/seq-AUTH-R01.spec.json" > "$W/badsrc.json"; bash "$M/drawio.sh" "$W/badsrc.json" "$W/badsrc.drawio" >/dev/null
expect_contains "check-doc: a diagram citation past the end of the file fails" "$(bash "$M/check-doc.sh" $RT "$W/badsrc.drawio" 2>&1)" "be:routes/api.php:999 (file has"
printf '%s' '{"kind":"flow","module":"auth","nodes":[{"id":"a","label":"A"}],"edges":[{"from":"a","to":"zz"}]}' > "$W/bad.json"
expect_contains "drawio: edge to an unknown box is refused" "$(bash "$M/drawio.sh" "$W/bad.json" "$W/bad.drawio" 2>&1)" "edge a -> zz uses an unknown node"

# ---------------------------------------------------------------- impact + sync
section "impact: seeds → modules, routes, callers, docs, risk, QA"
for r in be fe; do for s in routes models controllers; do bash "$M/$s.sh" $RT $r >/dev/null 2>&1; done; done
for r in be fe ap; do for s in screens externals; do bash "$M/$s.sh" $RT $r >/dev/null 2>&1; done; done
AC=app/Http/Controllers/AuthController.php
LV2=$(grep -n 'function loginV2' "$B2/$AC" | cut -d: -f1); LSO=$(grep -n 'function sendOtp()' "$B2/$AC" | cut -d: -f1)
IF() { bash "$M/impact-facts.sh" $RT "$@" 2>&1; }
IJ() { /usr/bin/jq -r "$2" "$W2/atreya-docs/dev/$1/impact-facts.json" 2>&1; }
IO=$(IF --ticket t-login --file "be:$AC:$((LV2 + 1))")
expect_contains "impact-facts summary line" "$IO" "impact-facts: t-login: 1 direct + 0 related modules, 1 backend routes"
expect_eq "a line widens to its method and the route calling it" "$(IJ t-login '[.backend_routes[] | "\(.key)=\(.controller)"] | join(",")')" "POST login=AuthController@loginV2"
expect_eq "direct module with why" "$(IJ t-login '.direct_modules[0] | "\(.id): \(.why | join("; "))"')" "auth: owns be:$AC; owns route POST login"
expect_eq "every client caller of the changed route" "$(IJ t-login '[.backend_routes[0].callers[] | "\(.client) \(.caller)"] | sort | join(",")')" "ap loginUser,fe ApiController@doLogin"
expect_eq "route called by web and app → Medium" "$(IJ t-login '"\(.risk.level): \(.risk.medium | join(";"))"')" "Medium: route POST login is called by web and app"
expect_eq "tables read by the changed route are context, not changed" "$(IJ t-login '"\(.tables.changed | length) changed; read: \([.tables.read[].name] | join(","))"')" "0 changed; read: users"
expect_eq "QA: auth has web pages → sanity and regression" "$(IJ t-login '"\(.qa.sanity | join(","))|\(.qa.regression | join(","))"')" "auth|auth"
expect_contains "docs citing the changed code (diagram of AUTH-R01)" "$(IJ t-login '[.docs[].doc] | join(",")')" "nt/auth/diagrams/seq-AUTH-R01.drawio"
expect_contains "impact-facts.md written" "$(cat "$W2/atreya-docs/dev/t-login/impact-facts.md")" "## Risk (suggested): Medium"
expect_contains "a doc hit only on the route definition line is marked" "$(IJ t-login '[.docs[] | select(.doc | endswith("seq-AUTH-R01.drawio")) | .where[]] | join(",")')" " (route line only)"
expect_contains "app screens are listed as not covered by QA" "$(IJ t-login '.qa.not_covered | join(",")')" "app screens (QA tests web only): "
IF --ticket t-otp --file "be:$AC:$LSO" >/dev/null
expect_eq "route called by web only, one module: Low" "$(IJ t-otp '"\(.risk.level)|\([.backend_routes[].key] | join(","))|\([.backend_routes[0].callers[].client] | join(","))"')" "Low|POST otp/send|fe"
IF --ticket t-crit --table users --file be:app/Http/Controllers/Admin/ReportController.php >/dev/null
expect_eq "critical module → High" "$(IJ t-crit '"\(.risk.level): \(.risk.high | join(";"))"')" "High: critical module reports"
expect_eq "changed table: modules that use it are related" "$(IJ t-crit '[.related_modules[] | "\(.id): \(.why | join(";"))"] | join(",")')" "auth: uses changed table users"
IF --ticket t-web --file fe:app/Http/Controllers/LoginController.php >/dev/null
expect_eq "client file: its web routes" "$(IJ t-web '[.web_routes[].key] | sort | join(",")')" "GET login,POST register"
expect_contains "unknown seeds are refused" "$(IF --ticket t-bad --route "POST nope" --table nope)" "unknown route POST nope"
expect_absent "nothing written for unknown seeds" "$(ls "$W2/atreya-docs/dev")" "t-bad"
expect_contains "secret file is never a seed" "$(IF --ticket t-sec --file be:app/Http/Controllers/SamvitPaymentBridgeController.php)" "is a secret file"
expect_contains "untracked file is refused" "$(IF --ticket t-x --file be:app/nope.php)" "not a tracked file"
expect_contains "bad ticket slug is refused" "$(IF --ticket ../x --module auth)" "usage: impact-facts.sh"
IST=$(bash "$M/doc-stamp.sh" $RT auth,reports impact t-login 2>&1)
{ printf '%s\n' "$IST"; grep -E '^#' "$PLUGIN/references/impact-template.md"; printf '\nNone.\n'; } > "$W/impact.md"
expect_eq "impact stamp: module list, ticket, repos of all modules" "$(bash "$S/yaml2json.sh" --front-matter "$W/impact.md" | /usr/bin/jq -r '"\(.module) \(.ticket) \(.commits | keys | join(","))"')" "auth,reports t-login ap,be,fe"
expect_contains "impact stamp needs a ticket" "$(bash "$M/doc-stamp.sh" $RT auth impact 2>&1)" "impact needs a TICKET"
expect_contains "check-doc: impact doc with the template headings passes" "$(bash "$M/check-doc.sh" $RT "$W/impact.md" 2>&1)" "PASS  headings match the impact template (12 sections)"
sed 's/^## 9. Risk$/## 9. Risks/' "$W/impact.md" > "$W/impact-bad.md"
expect_contains "check-doc: wrong impact heading fails" "$(bash "$M/check-doc.sh" $RT "$W/impact-bad.md" 2>&1)" "FAIL  headings match the impact template"

section "sync: doc stamps vs git log"
bash "$M/make-diagram.sh" $RT auth sequence --routes "POST login" --name seq-AUTH-R01 >/dev/null 2>&1
SY() { bash "$M/sync.sh" $RT "$@" 2>&1; }
expect_contains "fresh diagram is up to date" "$(SY --module auth)" "OK       nt/auth/diagrams/seq-AUTH-R01.drawio (auth)"
expect_contains "unknown module refused" "$(SY --module nope)" "unknown module nope"
( cd "$B2" && printf '// changed\n' >> "$AC" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m "change login" )
SO=$(SY --module auth)
expect_contains "commit on a cited file → STALE" "$SO" "STALE    nt/auth/diagrams/seq-AUTH-R01.drawio (auth)"
expect_contains "stale doc shows the commit and the file" "$SO" "change login"
expect_contains "stale doc names the refresh command" "$SO" "refresh: make-diagram.sh auth --rerun seq-AUTH-R01"
expect_contains "map behind HEAD is warned" "$SO" "WARNING  _map is behind HEAD for: be"
for s in routes models controllers; do bash "$M/$s.sh" $RT be >/dev/null 2>&1; done
bash "$M/module-facts.sh" $RT auth >/dev/null 2>&1; bash "$M/make-diagram.sh" $RT auth --rerun seq-AUTH-R01 >/dev/null 2>&1
expect_contains "--rerun restamps: up to date again" "$(SY --module auth)" "OK       nt/auth/diagrams/seq-AUTH-R01.drawio (auth)"
( cd "$B2" && printf '// routes note\n' >> routes/api.php && git add -A && git -c user.name=t -c user.email=t@t commit -q -m "routes note" )
expect_contains "only a shared file (routes) changed → CHECK" "$(SY --module auth)" "CHECK    nt/auth/diagrams/seq-AUTH-R01.drawio (auth)"
sed 's/be=[0-9a-f]*/be=0000000000000000000000000000000000000000/' "$W2/atreya-docs/nt/auth/diagrams/seq-AUTH-R01.drawio" > "$W/old.drawio"
expect_contains "stamp not in the history → UNKNOWN" "$(SY "$W/old.drawio")" "stamp 0000000000 is not in the history"
expect_contains "summary line counts each status" "$(SY --module auth)" "stale, 1 check,"
expect_absent "impact docs (dev/) are not checked" "$(SY)" "dev/"

# ---------------------------------------------------------------- pages that trigger calls
section "link-apis: page JS / bloc events → the page or screen that triggers a call"
# Frontend, shaped like auth.login: page JS -> Frontend route -> controller -> backend
mkdir -p "$F2/public/js/auth"
cat >> "$F2/routes/web.php" <<'EOF'
Route::get('/otp', [App\Http\Controllers\OtpController::class, 'show']);
Route::post('/verify-otp', [App\Http\Controllers\OtpController::class, 'verify']);
Route::post('/verify-email-otp', [App\Http\Controllers\OtpController::class, 'verifyEmail']);
Route::post('/ping-otp', [App\Http\Controllers\OtpController::class, 'ping']);
Route::get('/heartbeat', [App\Http\Controllers\OtpController::class, 'beat']);
Route::post('/orphan', [App\Http\Controllers\OtpController::class, 'orphan']);
Route::post('/resend', [App\Http\Controllers\OtpController::class, 'resend'])->name('otp.resend');
Route::get('/profile', [App\Http\Controllers\ProfileController::class, 'show']);
Route::post('/save-profile', [App\Http\Controllers\ProfileController::class, 'save']);
EOF
cat > "$F2/app/Http/Controllers/OtpController.php" <<'EOF'
<?php
namespace App\Http\Controllers;
class OtpController extends Controller
{
    public function show() {
        return view('auth.otp');
    }
    public function verify() {
        $b = config('app.backend_url');
        return Http::asJson()->post("$b/otp/send", []);
    }
    public function verifyEmail() {
        $b = config('app.backend_url');
        return Http::asJson()->post("$b/login", []);
    }
    public function ping() {
        $b = config('app.backend_url');
        return Http::asJson()->get("$b/ping");
    }
    public function beat() {
        $b = config('app.backend_url');
        return Http::asJson()->get("$b/report/1");
    }
    public function orphan() {
        $b = config('app.backend_url');
        return Http::asJson()->post("$b/report-list", []);
    }
    public function resend() {
        $b = config('app.backend_url');
        return Http::asJson()->post("$b/otp/v2/send/1", []);
    }
}
EOF
cat > "$F2/app/Http/Controllers/ProfileController.php" <<'EOF'
<?php
namespace App\Http\Controllers;
class ProfileController extends Controller
{
    public function show() {
        return view('auth.profile');
    }
    public function save() {
        $b = config('app.backend_url');
        return Http::asJson()->post("$b/report-list", []);
    }
}
EOF
cat > "$F2/resources/views/auth/otp.blade.php" <<'EOF'
@extends('layouts.app')
<button id="verify-otp-button">Verify</button>
<a id="only-on-otp">ping</a>
<form method="POST" action="{{ route('otp.resend') }}"></form>
<script src="{{ asset('js/auth/otp.js') }}?v=1"></script>
<script src="{{ asset('js/common.js') }}"></script>
EOF
cat > "$F2/resources/views/auth/profile.blade.php" <<'EOF'
@extends('layouts.app')
<button onclick="saveProfile()">Save</button>
<script src="{{ asset('js/common.js') }}"></script>
EOF
cat > "$F2/public/js/auth/otp.js" <<'EOF'
$('#verify-otp-button').click(function () {
    let url = isPhone ? '/verify-otp' : '/verify-email-otp';
    $.ajax({
        url: url,
        type: 'POST',
    });
});
function resendCode(id) {
    $.ajax({ url: someBase + id, type: 'POST' });
    $.post('/otp/v2/send/' + id);
}
function sendCode(isEmail) {
    let url = '';
    if (isEmail) {
        url = '/verify-email-otp';
    } else {
        url = '/verify-otp';
    }
    $.ajax({ url: url, type: 'POST' });
}
EOF
cat > "$F2/public/js/common.js" <<'EOF'
function saveProfile() {
    $.ajax({ url: '/save-profile', type: 'POST' });
}
$(document).on('click', '#only-on-otp', function () {
    $.post('/ping-otp');
});
$(document).ready(function () {
    $.get('/heartbeat');
});
function orphan() {
    $.post('/orphan');
}
EOF
# App, shaped like the login bloc: event -> handler -> repository call
mkdir -p "$A2/lib/otp/widgets"
cat > "$A2/lib/common_files/constants/strings_const.dart" <<'EOF'
class StringsConst {
  final String loginUrl = "${AppEnvironment.baseUrl}/login";
  final String otpUrl = '${AppEnvironment.baseUrl}/otp/v2/send';
  // final String oldUrl = "${AppEnvironment.baseUrl}/old";
  final String chatbotBaseUrl = "https://chatbot.example-lambda.test";
  final String verifyUrl = "${AppEnvironment.baseUrl}/otp/send";
  final String resendUrl = "${AppEnvironment.baseUrl}/report-list";
  final String autoUrl = "${AppEnvironment.baseUrl}/ping";
  final String loadUrl = "${AppEnvironment.baseUrl}/report/1";
}
EOF
cat > "$A2/lib/otp/otp_repo.dart" <<'EOF'
class OtpRepo {
  Future<void> verifyOtp() async {
    final r = await _http.request(url: StringsConst().verifyUrl, method: MethodType.post);
  }
  Future<void> resendOtp() async {
    final r = await _http.request(url: StringsConst().resendUrl, method: MethodType.post);
  }
  Future<void> autoLogin() async {
    final r = await _http.request(url: StringsConst().autoUrl, method: MethodType.get);
  }
  Future<void> loadOtp() async {
    final r = await _http.request(url: StringsConst().loadUrl, method: MethodType.get);
  }
}
EOF
printf 'class VerifyOtpEvent {}\nclass ResendEvent {}\nclass AutoEvent {}\nclass LoadEvent {}\n' > "$A2/lib/otp/otp_event.dart"
cat > "$A2/lib/otp/otp_bloc.dart" <<'EOF'
class OtpBloc extends Bloc<Object, Object> {
  OtpBloc() : super(0) {
    on<VerifyOtpEvent>(_onVerify);
    on<AutoEvent>(_onAuto);
    on<LoadEvent>(_onLoad);
    on<ResendEvent>((event, emit) async {
      await repo.resendOtp();
    });
  }
  Future<void> _onVerify(VerifyOtpEvent event, Emitter<Object> emit) async {
    await repo.verifyOtp();
    add(AutoEvent());
  }
  Future<void> _onAuto(AutoEvent event, Emitter<Object> emit) async {
    await repo.autoLogin();
  }
  Future<void> _onLoad(LoadEvent event, Emitter<Object> emit) async {
    await repo.loadOtp();
  }
}
EOF
cat > "$A2/lib/otp/otp_screen.dart" <<'EOF'
class OtpScreen extends StatelessWidget {
  Widget build(BuildContext context) {
    return ElevatedButton(onPressed: () {
      context.read<OtpBloc>().add(VerifyOtpEvent());
    }, child: ResendButton());
  }
}
EOF
cat > "$A2/lib/otp/other_screen.dart" <<'EOF'
class OtherScreen extends StatelessWidget {
  Widget build(BuildContext context) {
    return BlocProvider<OtpBloc>(create: (_) => OtpBloc(), child: ResendButton());
  }
}
EOF
cat > "$A2/lib/otp/widgets/resend_button.dart" <<'EOF'
class ResendButton extends StatelessWidget {
  void _tap(BuildContext context) {
    context.read<OtpBloc>().add(ResendEvent());
  }
}
EOF
cat > "$A2/lib/route/router.dart" <<'EOF'
final router = GoRouter(
  routes: [
    GoRoute(
      path: '/login',
      name: 'login',
      pageBuilder: (context, state) => state.withTransition(
        BlocProvider<LoginBloc>(create: (c) => LoginBloc(), child: const LoginScreen()),
      ),
    ),
    GoRoute(
      path: '/home',
      name: 'home',
      builder: (context, state) => const HomeScreen(),
    ),
    GoRoute(
      path: '/otp',
      name: 'otp',
      builder: (context, state) => BlocProvider(create: (_) => OtpBloc()..add(LoadEvent()), child: const OtpScreen()),
    ),
  ],
);
EOF
for d in "$F2" "$A2"; do ( cd "$d" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m pages ); done
for s in routes controllers screens; do bash "$M/$s.sh" $RT fe >/dev/null 2>&1; done
bash "$M/screens.sh" $RT ap >/dev/null 2>&1
for r in fe ap; do bash "$M/calls.sh" $RT $r >/dev/null 2>"$W/err.calls.$r" || bad "calls.sh $r runs (pages)" "$(cat "$W/err.calls.$r")"; done
bash "$M/link-apis.sh" $RT >/dev/null 2>"$W/err.la" || bad "link-apis runs (pages)" "$(cat "$W/err.la")"
JS() { J fe/screens.json "[.js_calls[] | select(.url == \"$1\")] | first | $2"; }
PG() { J "$1/api-links.json" "[.links[] | select(.caller == \"$2\")] | first | $3"; }
expect_eq "page JS: script tag + selector handler, ternary URL gives both routes" "$(J fe/screens.json '[.js_calls[] | select(.file == "public/js/auth/otp.js" and .line == 4) | "\(.method) \(.url) \(.context)"] | join(",")')" "POST /verify-email-otp sel #verify-otp-button,POST /verify-otp sel #verify-otp-button"
expect_eq "page JS loaded by one page → that page" "$(JS /verify-otp '"\(.pages | join(","))|\(.how)"')" "auth.otp|only page that loads it"
expect_eq "URL variable set in if/else branches gives every URL it can hold" "$(J fe/screens.json '[.js_calls[] | select(.file == "public/js/auth/otp.js" and .line == 19) | .url] | sort | join(",")')" "/verify-email-otp,/verify-otp"
expect_eq "shared JS: function credited only to the page that calls it" "$(JS /save-profile '.pages | join(",")')" "auth.profile"
expect_eq "shared JS: handler credited only to the page that has the element" "$(JS /ping-otp '.pages | join(",")')" "auth.otp"
expect_contains "shared JS: code that runs on load is unresolved, not credited to every page" "$(JS /heartbeat '"\(.pages | length)|\(.unresolved)"')" "0|runs on load on every page that loads public/js/common.js (2 pages)"
expect_contains "shared JS: function no page calls is unresolved" "$(JS /orphan '"\(.pages | length)|\(.unresolved)"')" "0|shared by 2 pages; cannot tell which one triggers orphan()"
expect_contains "dynamic URL is listed unresolved with file:line" "$(J fe/api-links.json '.js_unresolved | map("\(.source) \(.reason)") | join(",")')" "public/js/auth/otp.js:9 url built from variable someBase"
expect_eq "JS → Frontend route → controller → backend: page credited" "$(PG fe 'OtpController@verify' '"\(.route)|\(.pages | join(","))"')" "POST otp/send|auth.otp"
expect_eq "form action credits the page holding the form" "$(PG fe 'OtpController@resend' '.pages | join(",")')" "auth.otp"
expect_eq "unresolved trigger: no page, reason kept" "$(PG fe 'OtpController@beat' '"\(.pages | length)|\(.pages_unresolved[0].source)"')" "0|public/js/common.js:8"
expect_eq "page JS calling the backend directly is a link of its own" "$(J fe/api-links.json '[.links[] | select(.via == "js")] | map("\(.route)|\(.pages | join(","))") | join(",")')" "POST otp/v2/send/{id}|auth.otp"
expect_eq "app: screen that sends the handled event (not every screen using the bloc)" "$(PG ap verifyOtp '.pages | join(",")')" "OtpScreen"
expect_eq "app: event re-sent inside the bloc traces back to the first screen" "$(PG ap autoLogin '.pages | join(",")')" "OtpScreen"
expect_eq "app: event sent while the router builds the screen" "$(PG ap loadOtp '.pages | join(",")')" "OtpScreen"
expect_contains "app: event sent from a widget used by 2 screens is unresolved" "$(PG ap resendOtp '"\(.pages | length)|\(.pages_unresolved[0].reason)"')" "0|used by 2 screens (other_screen.dart, otp_screen.dart)"
expect_absent "app: a screen that only provides the bloc is never credited" "$(J ap/api-links.json '[.links[].pages[]] | join(",")')" "OtherScreen"
expect_contains "unresolved calls are listed with the call site to override" "$(cat "$MAP/fe/api-links.md")" "## Calls with no page ("
# overrides.yaml: fixes survive re-runs; stale entries are reported
RS=$(J ap/calls.json '.calls[] | select(.dart_method == "resendOtp") | "\(.file):\(.line)"')
cat > "$W2/atreya-docs/_map/overrides.yaml" <<EOF
links:
  - client: "fe"
    source: "public/js/common.js:8"
    pages:
      - "auth.profile"
    note: "test: heartbeat only matters on the profile page"
  - client: "fe"
    source: "public/js/auth/otp.js:9"
    path: "/verify-otp"
    method: "POST"
    pages:
      - "auth.otp"
  - client: "ap"
    source: "$RS"
    pages:
      - "OtpScreen"
  - client: "fe"
    source: "public/js/nope.js:1"
    pages:
      - "auth.otp"
EOF
LA2=$(bash "$M/link-apis.sh" $RT 2>&1)
expect_contains "overrides: counted in the summary" "$LA2" "link-apis: fe: 13 calls"
expect_contains "overrides: applied and unused counts" "$(printf '%s\n' "$LA2" | grep '^link-apis: fe:')" "overrides 2 applied, 1 unused"
expect_eq "override fixes an unresolved JS call site's page" "$(PG fe 'OtpController@beat' '"\(.pages | join(","))|\(.pages_unresolved | length)"')" "auth.profile|0"
expect_eq "override gives the URL of a dynamic JS call (no longer unresolved)" "$(J fe/api-links.json '.js_unresolved | length')" "0"
expect_eq "override fixes an app call" "$(PG ap resendOtp '"\(.pages | join(","))|\(.pages_override)"')" "OtpScreen|true"
expect_contains "override that matches nothing is reported" "$(cat "$MAP/fe/api-links.md")" '`public/js/nope.js:1`'
bash "$M/screens.sh" $RT fe >/dev/null 2>&1; bash "$M/calls.sh" $RT ap >/dev/null 2>&1; bash "$M/link-apis.sh" $RT >/dev/null 2>&1
expect_eq "overrides survive re-running the map scripts" "$(PG ap resendOtp '.pages | join(",")')" "OtpScreen"
expect_contains "overrides.yaml is never rewritten by the scripts" "$(cat "$W2/atreya-docs/_map/overrides.yaml")" "test: heartbeat only matters on the profile page"
printf 'links:\n  - client: "fe"\n' > "$W/ovbad.yaml"; cp "$W2/atreya-docs/_map/overrides.yaml" "$W/ovgood.yaml"; cp "$W/ovbad.yaml" "$W2/atreya-docs/_map/overrides.yaml"
expect_contains "override without a source is refused" "$(bash "$M/link-apis.sh" $RT 2>&1)" "each entry needs client, source"
cp "$W/ovgood.yaml" "$W2/atreya-docs/_map/overrides.yaml"
# a full page reused as a component does not bring its own layout (and that layout's JS) along
mkdir -p "$F2/resources/views/admin" "$F2/public/js"
printf '<html><script src="{{ asset('"'"'js/admin.js'"'"') }}"></script>@yield("c")</html>\n' > "$F2/resources/views/layouts/admin.blade.php"
printf "@extends('layouts.admin')\n<a id=\"adm-btn\">x</a>\n" > "$F2/resources/views/admin/home.blade.php"
printf "@extends('layouts.app')\n@component('admin.home')\n@endcomponent\n" > "$F2/resources/views/admin/combo.blade.php"
printf "\$('#adm-btn').click(function () {\n    \$.post('/save-profile');\n});\n" > "$F2/public/js/admin.js"
( cd "$F2" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m layout )
bash "$M/screens.sh" $RT fe >/dev/null 2>&1
expect_eq "an included page's own @extends is not followed (its layout JS stays with it)" "$(J fe/screens.json '[.js_calls[] | select(.file == "public/js/admin.js") | .pages[]] | join(",")')" "admin.home"
expect_absent "the page that includes it gets the included view, not its layout" "$(J fe/screens.json '.screens[] | select(.id == "admin.combo") | .parts | join(",")')" "layouts/admin.blade.php"

# ---------------------------------------------------------------- regressions found by the auth doc-checker
section "regressions: false tables, connection migrations, dead callers, citations"
# a model name inside a longer identifier (beginTransaction, getReport) is not that model
cat > "$B2/app/Http/Controllers/TxController.php" <<'EOF'
<?php
namespace App\Http\Controllers;
use App\Models\Report;
use App\Models\Transaction;
class TxController extends Controller
{
    public function a() { DB::beginTransaction(); $this->getReport(); return 1; }
    public function b() { return Report::all(); }
    public function c() { return Transaction::where('x', 1)->first(); }
}
EOF
cat > "$B2/app/Models/Transaction.php" <<'EOF'
<?php
namespace App\Models;
class Transaction extends Model { protected $table = 'transactions'; }
EOF
# migrations through Schema::connection(...)->create / ->table
cat > "$B2/database/migrations/2024_02_01_000000_alter_users.php" <<'EOF'
<?php
return new class extends Migration {
    public function up() {
        Schema::connection('mysql')->table('users', function (Blueprint $table) {
            $table->string('phone')->nullable();
        });
        Schema::connection('mysql')->create('created_logs', function (Blueprint $table) {
            $table->string('msg');
        });
    }
};
EOF
( cd "$B2" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m regress )
for s in models controllers; do bash "$M/$s.sh" $RT be >/dev/null 2>&1; done
TX() { J be/controllers.json ".controllers[] | select(.fqcn | test(\"TxController\")) | .methods[] | select(.name == \"$1\") | .tables | join(\",\")"; }
expect_eq "controllers: DB::beginTransaction() / ->getReport() add no table" "$(TX a)" ""
expect_eq "controllers: Report::all() still gives its table" "$(TX b)" "reports"
expect_eq "controllers: Transaction::where() still gives its table" "$(TX c)" "transactions"
expect_eq "models: Schema::connection()->table adds columns" "$(J be/models.json '.tables[] | select(.name=="users") | .columns | map(.name) | join(",")')" "created_at,id,name,phone,updated_at"
expect_eq "models: Schema::connection()->create is a create (a table name holding 'create' is not)" "$(J be/models.json '.tables[] | select(.name=="created_logs") | "\(.created_in_migrations)|\(.columns | map(.name) | join(","))"')" "true|msg"
# a Frontend controller method with no web route that no code calls is dead code;
# one with no route that live code calls ($this->helper()) is not
cat > "$F2/app/Http/Controllers/OldController.php" <<'EOF'
<?php
namespace App\Http\Controllers;
class OldController extends Controller
{
    public function old() { $backendUrl = config('app.backend_url'); return Http::asJson()->post("$backendUrl/otp/send", []); }
    public function page() { return $this->helper(); }
    public function helper() { $backendUrl = config('app.backend_url'); return Http::asJson()->get("$backendUrl/ping"); }
}
EOF
# a route NAME equal to the method name is not a call to the method
printf '<a href="{{ route('"'"'old'"'"') }}">old</a>\n' > "$F2/resources/views/auth/old_link.blade.php"
cat >> "$F2/routes/web.php" <<'EOF'
// Route::post('/old', [App\Http\Controllers\OldController::class, 'old']);
Route::get('/old-page', [App\Http\Controllers\OldController::class, 'page']);
EOF
( cd "$F2" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m dead )
for s in routes controllers screens calls; do bash "$M/$s.sh" $RT fe >/dev/null 2>&1; done
LA3=$(bash "$M/link-apis.sh" $RT 2>&1)
DEAD() { J fe/api-links.json ".links[] | select(.caller == \"$1\") | \"\\(.dead)|\\(.pages_unresolved | map(.reason) | join(\";\"))\""; }
expect_eq "link-apis: method whose route is commented out is dead code" "$(DEAD OldController@old)" "true|dead code: controller method has no web route and no code calls it"
expect_eq "link-apis: unrouted helper called by live code is not dead" "$(DEAD OldController@helper)" "false|controller method has no web route"
expect_contains "link-apis: dead calls counted in the summary" "$(printf '%s\n' "$LA3" | grep '^link-apis: fe:')" "1 from dead code"
bash "$M/module-facts.sh" $RT auth >/dev/null 2>&1
expect_eq "module-facts: dead calls are left out of the fact pack" "$(/usr/bin/jq -r '[.api_calls[] | select(.caller == "OldController@old")] | length' "$W2/atreya-docs/_map/_modules/auth/facts.json")" "0"
# flow: an external box cites where its target is defined (the GoRoute line)
GL=$(J ap/screens.json '.go_routes[] | select(.path == "/home") | .line')
expect_eq "flow: external box cites the router line of its target" "$(DS flow --platform app | /usr/bin/jq -r '.nodes[] | select(.id == "x-homescreen") | .source')" "ap:lib/route/router.dart:$GL"
# check-doc: every part of a "; "-separated source is checked
/usr/bin/jq '.nodes[1].source = "be:routes/api.php:5; be:routes/api.php:999"' "$DD/seq-AUTH-R01.spec.json" > "$W/multisrc.json"; bash "$M/drawio.sh" "$W/multisrc.json" "$W/multisrc.drawio" >/dev/null
expect_contains "check-doc: each citation of a multi-citation source is checked" "$(bash "$M/check-doc.sh" $RT "$W/multisrc.drawio" 2>&1)" "be:routes/api.php:999 (file has"

printf '\n%d passed, %d failed\n' "$PASSN" "$FAILN"
[ $FAILN = 0 ]
