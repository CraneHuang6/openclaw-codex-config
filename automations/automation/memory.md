- last_run_at: 2026-02-23 22:09:43 CST
  mode: full
  result: error
  before_version: 2026.2.22-2
  after_version: 2026.2.22-2
  dns_precheck: fail (http api.github.com/registry.npmjs.org resolve failed)
  status_deep: skip (dns/network)
  gateway_probe: skip (dns/network)
  security_audit: pass (0 critical)
  feishu_probe: skip (dns/network)
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-23-daily-auto-update-220924-92667.md
- last_run_at: 2026-02-23 22:43:55 CST
  mode: with-update
  result: error
  before_version: 2026.2.22-2
  after_version: 2026.2.22-2
  dns_precheck: fail
  status_deep: skip
  gateway_probe: skip
  security_audit: pass
  feishu_probe: skip
  first_error_class: 
  result_domain: 
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-23-daily-auto-update-220924-92667.md
- last_run_at: 2026-02-23 22:47:30 CST
  mode: with-update
  result: error
  before_version: 2026.2.22-2
  after_version: 2026.2.22-2
  dns_precheck: fail
  status_deep: skip
  gateway_probe: skip
  security_audit: pass
  feishu_probe: skip
  first_error_class: dns_network
  result_domain: infra
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-23-daily-auto-update-224709-11097.md

# Run summary (2026-02-23 22:47:43 CST)
- Ran full update flow with OPENCLAW_NPM_REGISTRY, failed DNS precheck (api.github.com/registry.npmjs.org HTTP resolve), skipped probes; appended report to memory.
- last_run_at: 2026-02-23 23:12:41 CST
  mode: with-update
  result: error
  before_version: 2026.2.22-2
  after_version: 2026.2.22-2
  dns_precheck: fail
  status_deep: skip
  gateway_probe: skip
  security_audit: pass
  feishu_probe: skip
  first_error_class: dns_network
  result_domain: infra
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-23-daily-auto-update-231149-19478.md

# Run summary (2026-02-23 23:12:52 CST)
- Ran full update flow with OPENCLAW_NPM_REGISTRY; dns_precheck failed on HTTP resolve to api.github.com/registry.npmjs.org; probes skipped; report appended.
- last_run_at: 2026-02-23 23:18:14 CST
  mode: with-update
  result: error
  before_version: 2026.2.22-2
  after_version: 2026.2.22-2
  dns_precheck: fail
  status_deep: skip
  gateway_probe: skip
  security_audit: pass
  feishu_probe: skip
  first_error_class: dns_network
  result_domain: infra
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-23-daily-auto-update-231723-21608.md
- last_run_at: 2026-02-23 23:30:17 CST
  mode: with-update
  result: error
  before_version: 2026.2.22-2
  after_version: 2026.2.22-2
  dns_precheck: fail
  status_deep: skip
  gateway_probe: skip
  security_audit: pass
  feishu_probe: skip
  first_error_class: dns_network
  result_domain: infra
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-23-daily-auto-update-232926-28463.md

[2026-02-23T15:30:22Z] Ran full update flow (OPENCLAW_NPM_REGISTRY set). DNS precheck failed due to local proxy 127.0.0.1:7890 connection refused; update aborted. Appended report to memory; no fixes applied.
- last_run_at: 2026-02-24 04:01:24 CST
  mode: skip-update
  result: error
  before_version: 2026.2.22-2
  after_version: 2026.2.22-2
  dns_precheck: skip
  status_deep: fail
  gateway_probe: skip
  security_audit: pass
  feishu_probe: skip
  first_error_class: status_deep
  result_domain: app
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-24-daily-auto-update-040049-45624.md

# Run note (2026-02-24 04:01:36 CST)
- 运行 monitor，报告出现 EPERM loopback 限制，已跳过 doctor；已追加 memory。
- last_run_at: 2026-02-24 18:15:35 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.22-2
  after_version: 2026.2.22-2
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-24-daily-auto-update-181459-6087.md
- last_run_at: 2026-02-24 18:28:25 CST
  mode: with-update
  result: ok
  before_version: 2026.2.22-2
  after_version: 2026.2.23
  dns_precheck: pass
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-24-daily-auto-update-182114-7406.md

# Run summary (2026-02-24 19:19:09 CST)
- Ran monitor flow with LAN proxy env; precheck failed: proxy unreachable at 192.168.1.2:7890. No report file generated; skipped doctor and memory-append script.
- last_run_at: 2026-02-24 19:24:18 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.23
  after_version: 2026.2.23
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-24-daily-auto-update-192401-61368.md

[2026-02-24T11:26:16Z] Monitor run failed precheck: proxy unreachable at 192.168.1.2:7897; no REPORT_FILE; skipped doctor and memory-append script.
- last_run_at: 2026-02-24 19:28:15 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.23
  after_version: 2026.2.23
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-24-daily-auto-update-192744-63655.md

[2026-02-24T11:32:12Z] monitor failed precheck: proxy unreachable at 192.168.1.2:7897; no REPORT_FILE; skipped doctor and memory-append script.
- last_run_at: 2026-02-24 19:34:28 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.23
  after_version: 2026.2.23
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-24-daily-auto-update-193408-67128.md

[2026-02-24T11:45:17Z] monitor failed precheck: proxy unreachable at 127.0.0.1:7890; LAN_IP empty; no REPORT_FILE; skipped doctor and append script.
- last_run_at: 2026-02-24 21:05:22 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.23
  after_version: 2026.2.23
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-24-daily-auto-update-210510-80089.md
- last_run_at: 2026-02-24 21:09:12 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.23
  after_version: 2026.2.23
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-24-daily-auto-update-210900-81658.md
- last_run_at: 2026-02-25 19:05:34 CST
  mode: skip-update
  result: error
  before_version: 2026.2.23
  after_version: 2026.2.23
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: update_or_patch
  result_domain: app
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-25-daily-auto-update-190419-55249.md
- last_run_at: 2026-02-25 19:09:49 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.24
  after_version: 2026.2.24
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-25-daily-auto-update-190924-71157.md
- last_run_at: 2026-02-25 21:00:35 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.24
  after_version: 2026.2.24
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-25-daily-auto-update-210023-90282.md
- last_run_at: 2026-02-26 17:33:57 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.24
  after_version: 2026.2.24
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-26-daily-auto-update-173334-52715.md
- last_run_at: 2026-02-26 18:23:59 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.24
  after_version: 2026.2.24
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-26-daily-auto-update-182333-56809.md
- last_run_at: 2026-02-26 18:30:24 CST
  mode: with-update
  result: ok
  before_version: 2026.2.24
  after_version: 2026.2.24
  dns_precheck: pass
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-26-daily-auto-update-182925-57593.md
- last_run_at: 2026-02-26 19:09:00 CST
  mode: with-update-no-new-version
  result: ok
  before_version: 2026.2.25
  after_version: 2026.2.25
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-26-daily-auto-update-190824-76727.md
- last_run_at: 2026-02-26 19:09:00 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.25
  after_version: 2026.2.25
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-26-daily-auto-update-190842-77129.md
- last_run_at: 2026-02-26 19:18:19 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.25
  after_version: 2026.2.25
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-26-daily-auto-update-191803-78591.md
- last_run_at: 2026-02-26 19:20:09 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.25
  after_version: 2026.2.25
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-26-daily-auto-update-191951-79367.md
- last_run_at: 2026-02-26 19:26:09 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.25
  after_version: 2026.2.25
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-26-daily-auto-update-192551-81185.md
- last_run_at: 2026-02-26 20:37:56 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.25
  after_version: 2026.2.25
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-26-daily-auto-update-203728-94781.md
- last_run_at: 2026-02-26 20:52:51 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.25
  after_version: 2026.2.25
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-26-daily-auto-update-205218-96908.md
- last_run_at: 2026-02-26 21:05:52 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.25
  after_version: 2026.2.25
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-26-daily-auto-update-210507-98551.md
- last_run_at: 2026-02-26 21:35:24 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.25
  after_version: 2026.2.25
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-26-daily-auto-update-213448-3541.md
- last_run_at: 2026-02-27 10:57:51 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.25
  after_version: 2026.2.25
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-27-daily-auto-update-105722-49517.md
- last_run_at: 2026-02-27 11:12:49 CST
  mode: with-update
  result: error
  before_version: unknown
  after_version: unknown
  dns_precheck: pass
  status_deep: fail
  gateway_probe: fail
  security_audit: fail
  feishu_probe: skip
  first_error_class: security_audit
  result_domain: app
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-27-daily-auto-update-110826-82443.md
- last_run_at: 2026-02-27 11:15:16 CST
  mode: skip-update
  result: error
  before_version: 2026.2.26
  after_version: 2026.2.26
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: update_or_patch
  result_domain: app
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-27-daily-auto-update-111358-14664.md
- last_run_at: 2026-02-27 11:34:51 CST
- last_run_at: 2026-02-27 11:34:51 CST
  mode: with-update-no-new-version
  mode: skip-update
  result: ok
  result: ok
  before_version: 2026.2.26
  before_version: 2026.2.26
  after_version: 2026.2.26
  after_version: 2026.2.26
  dns_precheck: skip
  dns_precheck: skip
  status_deep: pass
  status_deep: pass
  gateway_probe: pass
  gateway_probe: pass
  security_audit: pass
  security_audit: pass
  feishu_probe: skip
  feishu_probe: skip
  first_error_class: none
  first_error_class: none
  result_domain: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-27-daily-auto-update-113409-51407.md
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-27-daily-auto-update-113352-50701.md
- last_run_at: 2026-02-27 21:00:44 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.26
  after_version: 2026.2.26
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-27-daily-auto-update-210026-29574.md
- last_run_at: 2026-02-28 21:00:30 CST
  mode: skip-update
  result: ok
  before_version: 2026.2.26
  after_version: 2026.2.26
  dns_precheck: skip
  status_deep: pass
  gateway_probe: pass
  security_audit: pass
  feishu_probe: skip
  first_error_class: none
  result_domain: none
  report: /Users/crane/.openclaw/workspace/outputs/system-updates/2026-02-28-daily-auto-update-210011-71965.md
