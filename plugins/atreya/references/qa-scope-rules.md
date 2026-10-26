# QA scope rules

- **Web staging only.** Test the web app on the staging URL from the plugin
  setting `staging_url` (default `https://staging-dashboard.naditarangini.com`)
  with the staging login from `staging_username` / `staging_password`.
  Never production, never the mobile app.
- **Test only the given task or bug.** Do not widen scope to nearby features.
- **Nadi Capture:** skip the success flow; it needs a manual step on a physical
  device. Mark it as skipped with that reason.
- **OTP:** never use a real OTP (sent by WhatsApp or email). Do not drop a case
  that needs one: set its Status to `Blocked – OTP (manual)` and say in Remarks
  which step needs the OTP, so the coverage gap stays visible.
- **Accounts:** test only with the staging login from `staging_username` /
  `staging_password`. Never use test accounts found in code (hard-coded mobile
  numbers, emails or fixed OTPs), even on staging. They are listed, without
  values, in `atreya-docs/security/test-accounts.md` for escalation.
- **Reports:** test only report generation and language selection.
- **Chatbot:** basic checks only (opens, accepts a message, replies).
- **Languages:** English, Marathi, Hindi, Czech, German, Spanish, Italian.
