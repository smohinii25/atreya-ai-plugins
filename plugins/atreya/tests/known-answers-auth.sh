#!/bin/bash
# known-answers-auth.sh [WORKSPACE_ROOT]
#
# Checks the REAL workspace's _map output (after /atreya:map + /atreya:link-apis)
# against links verified by reading the code of the auth module. Each answer
# below cites the code that proves it. A failure means the scripts credited the
# wrong page/screen (or none) for a call whose answer is known.
# Skips (exit 0) when the workspace or its _map is missing: it is not a unit
# test (tests/scripts-tests.sh is), it is a regression check on real code.
ROOT="${1:-${ATREYA_ROOT:-$HOME/Mohini/atreya-ai}}"
MAP="$ROOT/atreya-docs/_map"
FE="$MAP/Nadi-Tarangini-Frontend/api-links.json"
AP="$MAP/Nadi-Tarangini-App/api-links.json"
for f in "$FE" "$AP"; do [ -f "$f" ] || { echo "skip: $f not found (run /atreya:map and /atreya:link-apis first)"; exit 0; }; done
PASSN=0; FAILN=0
# check FILE CALLER ROUTE EXPECTED_PAGES (comma-separated, sorted) — every link
# with that caller and route must credit exactly these pages
check() {
  got=$(/usr/bin/jq -r --arg c "$2" --arg r "$3" '[.links[] | select(.caller == $c and .route == $r) | (.pages | sort | join(","))] | unique | join(" / ")' "$1")
  if [ "$got" = "$4" ]; then PASSN=$((PASSN+1)); printf 'PASS  %s %s → %s\n' "$2" "$3" "$4"
  else FAILN=$((FAILN+1)); printf 'FAIL  %s %s\n        expected [%s] got [%s]\n' "$2" "$3" "$4" "${got:-no such link}"; fi
}

echo "== Frontend (page JS → Frontend route → controller → backend)"
# login.js is loaded only by auth.login (resources/views/auth/login.blade.php:356)
check "$FE" "loginController@checkLoginCredentials" "POST v2/loginValidation" "auth.login"        # login.js:302 .login-btn → /checkLoginCredintial
check "$FE" "loginController@sendWhatsappLoginOtp" "POST otp/send-otp" "auth.login"              # login.js:567, :581 #send-otp-button
check "$FE" "loginController@sendEmailLoginOtp" "POST otp/send-email-otp" "auth.login"           # login.js:565, :581 #send-otp-button
check "$FE" "loginController@verifyWhatsappLoginOtp" "POST otp/verify-otp" "auth.login"          # login.js:783, :812 #verify-otp-button
check "$FE" "loginController@verifyEmailLoginOtp" "POST otp/verify-email-otp" "auth.login"       # login.js:783, :812 #verify-otp-button
# forgotpassword.js is loaded only by auth.forgot_password (forgot_password.blade.php:95)
check "$FE" "forgotPasswordController@checkForgotPassword" "POST forgotPassword" "auth.forgot_password"   # forgotpassword.js:87

echo "== App (repository call → bloc handler → event → the screen that sends it)"
check "$AP" "loginUser" "POST v2/loginValidation" "LoginWithUsernameScreen"     # login_bloc.dart:28 on<LoginApi>, :71; LoginApi sent at login_with_username_screen.dart:258
check "$AP" "sendMobileOtp" "POST otp/send-otp" "LoginWithOtpScreen"            # login_bloc.dart:30 on<LoginWithOTPApi>, :237; sent by login_with_otp.dart
check "$AP" "sendEmailOtp" "POST otp/send-email-otp" "LoginWithOtpScreen"       # login_bloc.dart:35 on<LoginWithEmailOTPApi>, :442; sent by login_with_otp.dart
check "$AP" "verifyMobileOtp" "POST otp/verify-otp" "LoginWithOtpScreen"        # login_bloc.dart:31 on<VerifyOtpApi>, :269; sent at login_with_otp.dart:374
check "$AP" "verifyEmailOtp" "POST otp/verify-email-otp" "LoginWithOtpScreen"   # login_bloc.dart:36 on<VerifyEmailOtpApi>, :456; sent at login_with_otp.dart:367
check "$AP" "forgotPassword" "POST forgotPassword" "ForgotPasswordScreen"       # forgot_bloc.dart:14, :25; SubmitForgotPassword sent at forgot_password_screen.dart:287

printf '\n%d passed, %d failed\n' "$PASSN" "$FAILN"
[ $FAILN = 0 ]
