# QA scope rules

- **Web staging only.** Test the web app on the staging URL from the plugin
  setting `staging_url` (default `https://staging-dashboard.naditarangini.com`)
  with the staging login from `staging_username` / `staging_password`.
  Never production, never the mobile app.
- **Test only the given task or bug.** Do not widen scope to nearby features.
- **Nadi Capture:** skip the success flow; it needs a manual step on a physical
  device. Mark it as skipped with that reason.
- **OTP:** do not use real OTP codes. Skip steps that need one and note it.
- **Reports:** test only report generation and language selection.
- **Chatbot:** basic checks only (opens, accepts a message, replies).
- **Languages:** English, Marathi, Hindi, Czech, German, Spanish, Italian.
