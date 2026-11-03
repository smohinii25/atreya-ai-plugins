#!/bin/bash
# make-workspace.sh WS PLUGIN_DIR
#
# FAKE workspace for tests/impact-tests.sh (no real code, no real keys):
#   be  Laravel backend: PayController (payments, critical; writes payments +
#       wallets without a transaction, emits PaymentDone, uses LedgerService),
#       LedgerController + app/Services (ledger), SendReceipt listener (receipts),
#       ReportController (reports, reads ledger), LoginController (auth, no
#       caller), RefundController (refunds: two writes inside DB::transaction),
#       Helper <-> LedgerService (a circular use)
#   fe  Laravel web client: ShopController (shop) calls /api/pay and /api/ledger,
#       and one fully dynamic (unresolved) call in track()
#   ap  Flutter app: PayScreen -> payNow -> POST api/pay (app-pay)
#   module "audit" also claims app/Services/Helper.php (conflicting ownership)
# Runs the real map scripts, build-modules --write and link-apis.
W="$1"; P="$2"; S="$P/scripts"
rm -rf "$W"; mkdir -p "$W/repos" "$W/atreya-docs" "$W/atreya-qa"
gi() { ( cd "$1" && git init -q -b master && git add -A && git -c user.name=t -c user.email=t@t commit -q -m init ); }
B="$W/repos/be"; mkdir -p "$B/routes" "$B/app/Http/Controllers" "$B/app/Services" "$B/app/Events" "$B/app/Listeners" "$B/app/Providers" "$B/app/Models" "$B/database/migrations"
cat > "$B/routes/api.php" <<'EOF'
<?php
use App\Http\Controllers\PayController;
use App\Http\Controllers\LedgerController;
use App\Http\Controllers\ReportController;
use App\Http\Controllers\LoginController;
Route::post('/pay', [PayController::class, 'pay']);
Route::get('/ledger', [LedgerController::class, 'show']);
Route::get('/report', [ReportController::class, 'index']);
Route::post('/login', [LoginController::class, 'login']);
Route::post('/refund', [App\Http\Controllers\RefundController::class, 'refund']);
EOF
cat > "$B/app/Http/Controllers/PayController.php" <<'EOF'
<?php
namespace App\Http\Controllers;
use App\Models\Payment;
use App\Services\LedgerService;
use App\Events\PaymentDone;
class PayController extends Controller
{
    public function __construct(private LedgerService $ledger) {}
    public function pay($r) {
        Payment::create(['amount' => 1]);
        DB::table('wallets')->update(['balance' => 2]);
        $this->ledger->post(1);
        event(new PaymentDone(1));
        return 1;
    }
    public function cancel($id, Payment $old) {
        $p = Payment::find($id);
        $p->delete();
        $old->save();
        $unknown->save();
        return 1;
    }
}
EOF
cat > "$B/app/Http/Controllers/LedgerController.php" <<'EOF'
<?php
namespace App\Http\Controllers;
use App\Services\LedgerService;
class LedgerController extends Controller
{
    public function show(LedgerService $svc) {
        return $svc->post(0);
    }
}
EOF
cat > "$B/app/Http/Controllers/ReportController.php" <<'EOF'
<?php
namespace App\Http\Controllers;
use App\Models\Ledger;
class ReportController extends Controller
{
    public function index() {
        return Ledger::all();
    }
}
EOF
cat > "$B/app/Http/Controllers/LoginController.php" <<'EOF'
<?php
namespace App\Http\Controllers;
class LoginController extends Controller
{
    public function login($r) {
        return 1;
    }
}
EOF
cat > "$B/app/Http/Controllers/RefundController.php" <<'EOF2'
<?php
namespace App\Http\Controllers;
use App\Models\Payment;
class RefundController extends Controller
{
    public function refund($r) {
        DB::transaction(function () {
            Payment::where('id', 1)->update(['amount' => 0]);
            DB::table('wallets')->update(['balance' => 0]);
        });
        return 1;
    }
}
EOF2
cat > "$B/app/Services/LedgerService.php" <<'EOF'
<?php
namespace App\Services;
class LedgerService
{
    public function post($x) {
        DB::table('ledger')->insert(['x' => $x]);
        return Helper::round($x);
    }
}
EOF
cat > "$B/app/Services/Helper.php" <<'EOF'
<?php
namespace App\Services;
class Helper
{
    public static function round($x) {
        return LedgerService::class ? $x : 0;
    }
}
EOF
cat > "$B/app/Events/PaymentDone.php" <<'EOF'
<?php
namespace App\Events;
class PaymentDone
{
    public function __construct($x) {
        $this->x = $x;
    }
}
EOF
cat > "$B/app/Listeners/SendReceipt.php" <<'EOF'
<?php
namespace App\Listeners;
class SendReceipt
{
    public function handle($e) {
        return 1;
    }
}
EOF
cat > "$B/app/Providers/EventServiceProvider.php" <<'EOF'
<?php
namespace App\Providers;
use App\Events\PaymentDone;
use App\Listeners\SendReceipt;
class EventServiceProvider
{
    protected $listen = [
        PaymentDone::class => [
            SendReceipt::class,
        ],
    ];
}
EOF
printf '<?php\nnamespace App\\Models;\nclass Payment extends Model\n{\n    protected $table = "payments";\n}\n' > "$B/app/Models/Payment.php"
printf '<?php\nnamespace App\\Models;\nclass Ledger extends Model\n{\n    protected $table = "ledger";\n}\n' > "$B/app/Models/Ledger.php"
cat > "$B/database/migrations/2024_01_01_000000_create_payments.php" <<'EOF'
<?php
return new class extends Migration {
    public function up() {
        Schema::create('payments', function (Blueprint $table) {
            $table->id();
            $table->integer('amount');
        });
    }
};
EOF
mkdir -p "$B/resources/views/mail"; echo "<p>receipt</p>" > "$B/resources/views/mail/receipt.blade.php"
gi "$B"
F="$W/repos/fe"; mkdir -p "$F/routes" "$F/app/Http/Controllers" "$F/resources/views/shop"
printf "<?php\nuse App\\\\Http\\\\Controllers\\\\ShopController;\nRoute::get('/checkout', [ShopController::class, 'checkout']);\n" > "$F/routes/web.php"
cat > "$F/app/Http/Controllers/ShopController.php" <<'EOF'
<?php
namespace App\Http\Controllers;
class ShopController extends Controller
{
    public function checkout() {
        $backendUrl = config('app.backend_url');
        $r = Http::asJson()->post("$backendUrl/api/pay", []);
        $l = Http::asJson()->get("$backendUrl/api/ledger");
        return view('shop.checkout');
    }
    public function track($id) {
        $backendUrl = config('app.backend_url');
        return Http::asJson()->get("$backendUrl/{$id}");
    }
}
EOF
echo '<h1>checkout</h1>' > "$F/resources/views/shop/checkout.blade.php"
gi "$F"
A="$W/repos/ap"; mkdir -p "$A/lib/route" "$A/lib/pay" "$A/lib/common_files/constants" "$A/lib/common_files/api_services"
cat > "$A/lib/route/router.dart" <<'EOF'
final router = GoRouter(
  routes: [
    GoRoute(
      path: '/pay',
      name: 'pay',
      builder: (context, state) => const PayScreen(),
    ),
  ],
);
EOF
printf "class PayScreen extends StatelessWidget {\n  final bloc = PayBloc();\n}\n" > "$A/lib/pay/pay_screen.dart"
printf "class PayBloc {\n  void go() { repo.payNow(); }\n}\n" > "$A/lib/pay/pay_bloc.dart"
printf 'class StringsConst {\n  final String payUrl = "${AppEnvironment.baseUrl}/api/pay";\n}\n' > "$A/lib/common_files/constants/strings_const.dart"
cat > "$A/lib/common_files/api_services/api_repository.dart" <<'EOF'
class ApiRepository {
  Future<void> payNow() async {
    final r = await _http.request(url: StringsConst().payUrl, method: MethodType.post);
  }
}
EOF
gi "$A"
R="--root $W"
for r in be fe; do for s in routes models controllers; do bash "$S/$s.sh" $R $r >/dev/null || exit 1; done; done
for r in be fe ap; do for s in screens externals; do bash "$S/$s.sh" $R $r >/dev/null || exit 1; done; done
cat > "$W/prop.yaml" <<'EOF'
backend: be
modules:
  - id: payments
    name: "Payments"
    critical: true
    repos:
      - repo: be
        controllers:
          - PayController
  - id: ledger
    name: "Ledger"
    repos:
      - repo: be
        controllers:
          - LedgerController
        paths:
          - app/Services/
  - id: receipts
    name: "Receipts"
    repos:
      - repo: be
        paths:
          - app/Listeners/
  - id: reports
    name: "Reports"
    repos:
      - repo: be
        controllers:
          - ReportController
  - id: refunds
    name: "Refunds"
    repos:
      - repo: be
        controllers:
          - RefundController
  - id: audit
    name: "Audit"
    repos:
      - repo: be
        paths:
          - app/Services/Helper.php
  - id: auth
    name: "Login"
    repos:
      - repo: be
        controllers:
          - LoginController
  - id: shop
    name: "Shop (web)"
    repos:
      - repo: fe
        controllers:
          - ShopController
  - id: app-pay
    name: "Pay (app)"
    repos:
      - repo: ap
        paths:
          - lib/pay/
          - lib/common_files/
EOF
bash "$S/build-modules.sh" $R --from "$W/prop.yaml" --write >/dev/null || { echo "build-modules failed"; bash "$S/build-modules.sh" $R --from "$W/prop.yaml"; exit 1; }
for r in fe ap; do bash "$S/calls.sh" $R $r >/dev/null || exit 1; done
bash "$S/link-apis.sh" $R >/dev/null || exit 1
echo "fake workspace ready: $W"
