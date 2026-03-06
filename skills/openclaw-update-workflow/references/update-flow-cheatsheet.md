# OpenClaw Update Flow Cheatsheet

本清单对应本机现有脚本，不替代脚本逻辑。

## 主入口

```bash
# 每日巡检（自动化推荐；先巡检，若有新版本则自动执行 full）
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor

# 每日巡检但禁用自动 full（仅巡检）
OPENCLAW_SKILL_MONITOR_AUTO_FULL_ON_NEW_VERSION=0 \
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor

# 稳定维护（默认推荐）
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh stable

# 真实升级（人工触发）
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh full

# 仅重打补丁
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh patch

# Cron 半截报告回归预检
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck

# Cron 半截报告全量预检（推荐，扫描全部 cron job）
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck -- --all-jobs
```

说明：
- `monitor` 本质是 `daily-auto-update-local.sh --skip-update` + `OPENCLAW_DAILY_UPDATE_CHECK_LATEST_ON_SKIP=1`，会输出 `REPORT_FILE=...` 并在报告里写入 `latest_version`。
- 默认会在 `monitor` 成功后判断 `latest_version` 与 `before_version`；当 `latest_version > before_version` 时自动衔接 `full`（真实升级 + 补丁链 + 自检）。
- 可通过 `OPENCLAW_SKILL_MONITOR_AUTO_FULL_ON_NEW_VERSION=0` 关闭自动升级，仅保留巡检。

## Gate D2 自动提交（白名单）

```bash
# 开启 Gate D2 通过后的自动提交（默认 OPENCLAW_SKILL_AUTO_COMMIT_ENABLED=1）
OPENCLAW_SKILL_GATE_D2_VERDICT=PASS \
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh stable

# 显式关闭自动提交
OPENCLAW_SKILL_AUTO_COMMIT_ENABLED=0 \
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh stable
```

说明：
- 自动提交仅在 `OPENCLAW_SKILL_GATE_D2_VERDICT=PASS` 时触发。
- 提交范围仅限 `AGENTS.md` 与 `skills/openclaw-update-workflow/**`。
- 若存在白名单外改动，会输出 `AUTO_COMMIT_RESULT=skipped` + `AUTO_COMMIT_REASON=dirty_outside_allowlist`。
- 常见日志键：`AUTO_COMMIT_RESULT`、`AUTO_COMMIT_REASON`、`AUTO_COMMIT_HASH`、`AUTO_COMMIT_FILES`。

## Clash LAN 代理（自动化环境）

- 入口脚本支持按 `OPENCLAW_SKILL_HTTP_PROXY_HOST/PORT` 和 `OPENCLAW_SKILL_SOCKS_PROXY_PORT` 组装代理地址。
- 默认会在 `stable/monitor/full` 进入主流程前做 `curl --proxy` 预检；可用 `OPENCLAW_SKILL_PROXY_PRECHECK_ENABLED=0` 暂时关闭。
- 预检目标可通过 `OPENCLAW_SKILL_PROXY_PRECHECK_URL` 覆盖。
- 预检重试可通过 `OPENCLAW_SKILL_PROXY_PRECHECK_ATTEMPTS`（默认 `2`）和 `OPENCLAW_SKILL_PROXY_PRECHECK_RETRY_DELAY`（默认 `1` 秒）调整。

```bash
OPENCLAW_SKILL_HTTP_PROXY_HOST=192.168.1.2 \
OPENCLAW_SKILL_HTTP_PROXY_PORT=7897 \
OPENCLAW_SKILL_SOCKS_PROXY_PORT=7897 \
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor
```

## 关键底层脚本

```bash
# 日更主流程（版本门控 + 自愈 + 报告）
bash /Users/crane/.openclaw/scripts/daily-auto-update-local.sh --skip-update
bash /Users/crane/.openclaw/scripts/daily-auto-update-local.sh --skip-update --check-latest-on-skip
bash /Users/crane/.openclaw/scripts/daily-auto-update-local.sh --with-update

# 统一更新+补丁链
bash /Users/crane/.openclaw/scripts/update-openclaw-with-feishu-repatch.sh --skip-update --no-restart
bash /Users/crane/.openclaw/scripts/update-openclaw-with-feishu-repatch.sh --npm-registry https://registry.npmjs.org -- --yes
bash /Users/crane/.openclaw/scripts/update-openclaw-with-feishu-repatch.sh --skip-dmg-install --npm-registry https://registry.npmjs.org -- --yes
bash /Users/crane/.openclaw/scripts/update-openclaw-with-feishu-repatch.sh --dmg-path /path/to/OpenClaw.dmg -- --yes
```

说明：
- `--with-update` 路径会自动执行 `openclaw gateway install --force`
- 若检测到缺失 `@larksuiteoapi/node-sdk`，会自动补装到 `/opt/homebrew/lib/node_modules/openclaw`
- `media-path` 补丁会注入音频兼容重试：上传 `duration` 有值先试、失败再无 `duration` 重试；发送对 `.opus` 依次尝试 `audio -> media -> file`
- `reply-media` 补丁会在语音模式下抑制文本分发（`!forceVoiceModeTts` + `suppressTextDelivery`），避免“先发文字再发语音”
- `reply-voice` 补丁会恢复“回复消息 + 生成语音”本地快路径（500 分段，失败即中断），并在脚本缺失时给出固定提示（含 checked paths），默认 `voice_id=wakaba_mutsumi`
- `status --deep` 若偶发 `gateway closed (1006 ...)`（重启窗口竞态），日更脚本会先短重试一次再判失败
- 日更脚本会在 `--with-update` 前执行 DNS/HTTP 预检，并在 Codex 自动化环境下将 `gateway probe` 的 `EPERM(127.0.0.1)` 降级为 `skip`
- DidaAPI 子任务补丁若报 `target file missing:` 会自动 `skip`（不触发回滚）；其他错误仍会失败

## 同步 Codex 自包含脚本

```bash
# 从 ~/.openclaw 同步技能文档 + 更新/补丁脚本，并重写为同目录优先
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/sync-from-openclaw.sh --apply
```

说明：
- 会同步 `daily-auto-update-local.sh`、统一补丁链脚本、Feishu/DidaAPI repatch、以及经验沉淀/Known Fixes 脚本（`extract-openclaw-update-report-summary.py`、`append-openclaw-update-memory.sh`、`openclaw-update-known-bug-fix.sh`）。

## 单独安装最新 OpenClaw dmg

```bash
bash /Users/crane/.openclaw/scripts/install-openclaw-latest-dmg.sh --apply
```

## 单项补丁/修复

```bash
# Feishu 入站去重
bash /Users/crane/.openclaw/scripts/repatch-openclaw-feishu-dedup-hardening.sh --apply

# Feishu 回复媒体分发
bash /Users/crane/.openclaw/scripts/repatch-openclaw-feishu-reply-media.sh --apply

# Feishu 回复消息定向语音（回复 + 生成语音）
bash /Users/crane/.openclaw/scripts/repatch-openclaw-feishu-reply-voice.sh --apply

# Feishu 媒体路径 + 音频兼容重试（MEDIA:./workspace/... + duration/msg_type retries）
bash /Users/crane/.openclaw/scripts/repatch-openclaw-feishu-media-path.sh --apply

# DidaAPI 子任务补丁
bash /Users/crane/.openclaw/scripts/repatch-didaapi-subtasks.sh --apply
```

## 健康检查

```bash
openclaw status --deep
openclaw gateway probe
openclaw security audit --deep
```

## Known Fixes Only（自动修复边界）

```bash
# 先 dry-run 判断是否命中已知 signature
bash /Users/crane/.openclaw/scripts/openclaw-update-known-bug-fix.sh --signature gateway_1006 --dry-run

# 确认后再 apply（仅限已知 case）
bash /Users/crane/.openclaw/scripts/openclaw-update-known-bug-fix.sh --signature gateway_1006 --apply

# reply-voice 脚本缺失时的已知修复
bash /Users/crane/.openclaw/scripts/openclaw-update-known-bug-fix.sh --signature missing_reply_voice_script --apply

# dedup 持久化导出缺失（飞书能收消息但不回复）已知修复
bash /Users/crane/.openclaw/scripts/openclaw-update-known-bug-fix.sh --signature missing_dedup_persistent_export --apply
```

规则：
- `dns_network` 仅允许 skip/汇报，不自动改代码。
- 未知 signature（`unsupported`）立即停止自动修复，写 inbox，转人工排查。

## 报告摘要提取 / 自动化 memory 追加

```bash
# 从单次日更报告提取标准摘要（kv/json）
python3 /Users/crane/.openclaw/scripts/extract-openclaw-update-report-summary.py --report /path/to/report.md --format kv
python3 /Users/crane/.openclaw/scripts/extract-openclaw-update-report-summary.py --report /path/to/report.md --format json

# 追加到 Codex 自动化 memory（供后续运行参考经验）
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/append-openclaw-update-memory.sh --report /path/to/report.md
```

## Feishu 语音/附件看不到（文本正常）排障

```bash
# 1) 先确认是否命中本地媒体路径拦截
rg -n "Local media path is not under an allowed directory" /Users/crane/.openclaw/logs/gateway.err.log -S | tail -20

# 2) 重打媒体路径补丁（包含 /tmp -> state/workspace/tmp-media 桥接 + 音频兼容重试）
bash /Users/crane/.openclaw/scripts/repatch-openclaw-feishu-media-path.sh --apply

# 3) 重启并探测
openclaw gateway restart
openclaw gateway probe

# 4) 若收到 opus 但无法播放，检查封装/时长与重试 marker
latest_opus="$(ls -t /Users/crane/.openclaw/workspace/tmp-media/*.opus 2>/dev/null | head -n1)"
file "$latest_opus"
ffprobe -hide_banner -show_streams -show_format "$latest_opus" | sed -n '1,80p'
rg -n 'uploadDurationCandidates|msgTypeCandidates: Array<"audio" \| "media" \| "file">|resolveUploadDurationMs' /opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/media.ts -S
```

建议：业务侧仍优先使用 `MEDIA:./workspace/...`；`/tmp` 桥接用于兜底与兼容。若报 `voice fallback send failed`（Feishu 400），优先确认已命中上述重试 marker。

## monitor 报 `helper anchor not found` 快速处理

```bash
# 1) 先确认 media-path 补丁是否还能命中锚点
bash /Users/crane/.openclaw/scripts/repatch-openclaw-feishu-media-path.sh --dry-run

# 2) 再跑 monitor 验证整链
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor

# 3) 验收口径
# A: 输出中无 "helper anchor not found"
# B: monitor 最终为 "STATUS=ok"
```

## monitor 报 `onModelSelected anchor not found` 快速处理（2026-03-05）

```bash
# 1) 确认 wrapper 默认是否已指向 ~/.openclaw/scripts（单一来源）
rg -n 'DAILY_SCRIPT=.*OPENCLAW_HOME/scripts/daily-auto-update-local.sh|UNIFIED_PATCH_SCRIPT=.*OPENCLAW_HOME/scripts/update-openclaw-with-feishu-repatch.sh' \
  /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh -S

# 2) 跑 monitor，并读取最新 REPORT_FILE
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor

# 3) 若报告为：
#    first_error_class=update_or_patch 且 status_deep/gateway_probe/security_audit=pass
#    期望 status=warning（非致命，不触发系统异常通知）

# 4) 若 first_error_class=gateway_probe 或出现 fallback availability check failed，
#    转运行态故障路径，不按锚点误报处理
```

## Feishu 能收到消息但无回复（Mac App 正常）排障

```bash
# 1) 检查是否命中 dedup 导出缺失
rg -n "tryRecordMessagePersistent|error handling message: TypeError" /Users/crane/.openclaw/logs/gateway.err.log -S | tail -20

# 2) 重打 dedup 补丁（恢复 tryRecordMessagePersistent 导出）
bash /Users/crane/.openclaw/scripts/repatch-openclaw-feishu-dedup-hardening.sh --apply

# 3) 重启并探测
openclaw gateway restart
openclaw channels status --probe --json
```

说明：
- 若日志出现 `TypeError: (0 , _dedup.tryRecordMessagePersistent) is not a function`，说明消息已入站但处理阶段崩溃。
- 群聊场景仍需满足现有策略（默认 `requireMention=true`，需 `@小可`）。

### No-Reply RCA 固化顺序（2026-03-05）

```bash
# 1) 先确认 fallback 链只剩 qmcode/gpt-5.2
jq -r '.agents.defaults.model.fallbacks' /Users/crane/.openclaw/openclaw.json

# 2) 实时 probe（确认 fallback provider/model 可用性）
openclaw models status --probe --probe-timeout 12000 --probe-concurrency 2 --json

# 3) 守卫与日更脚本回归（防止 fallback 被更新脚本加回）
bash /Users/crane/.openclaw/scripts/tests/enforce-openclaw-kimi-model.test.sh
bash /Users/crane/.openclaw/scripts/tests/daily-auto-update-local.test.sh
bash /Users/crane/.openclaw/scripts/tests/update-openclaw-with-feishu-repatch.test.sh

# 4) Feishu 指标日志验收（发一条真实飞书消息后）
rg -n "dispatch metrics|fallback metrics|no final reply queued|sent no-final fallback text" \
  /Users/crane/.openclaw/logs/gateway.log | tail -n 50
```

要点：
- 顺序固定为：`观测 -> fallback 收敛 -> retry/failover`，避免盲修。
- fallback 可用性检查必须 fail-closed（非 `ok` 直接失败，不静默降级）。
- 若定向跑 Feishu 单测，建议用：
  - `OPENCLAW_FEISHU_DEDUP_STATE_FILE="$(mktemp /tmp/openclaw-feishu-dedup-test.XXXXXX.json)" pnpm dlx vitest run extensions/feishu/src/bot.test.ts -t "single-agent dispatch metrics and retry"`

## Feishu 长文本重复放大 + 人设漂移（联合排障）

```bash
# 1) 检查关键补丁 marker 是否在位
rg -n "trimRunawayRepeatedSuffix|normalizeStreamingPartial|mergeStreamingText|applyPersonaGuard|personaMode" \
  /opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/reply-dispatcher.ts \
  /opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/streaming-card.ts \
  /opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/bot.ts -S

# 2) 重启 + 健康
openclaw gateway restart
openclaw status --deep

# 3) 日志收敛验收
rg -n "received message from|Started streaming|streaming partial update #|dispatch complete|Closed streaming|persona guard applied" \
  /Users/crane/.openclaw/logs/gateway.log -S | tail -n 120
```

通过标准：
- 不再出现 partial 持续放大且无 close。
- 同一会话出现 `Closed streaming`。
- 日常消息满足人设，技术消息保持技术例外。

## Cron 显示成功但只发第一批资料（半截报告）排障

```bash
# 1) 跑统一预检（默认仅检查 AI 自主学习 job）
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck

# 1.1) 推荐跑全量预检（扫描全部 cron job）
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck -- --all-jobs

# 2) 指定 job 检查
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck -- --job-id <job-id>

# 3) 回看指定历史 session
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck -- --session-id <session-id>

# 4) 预期关键输出
# RESULT=pass
# REASON=no partial-success signal detected
```

判定：
- `REASON=ok status with interim summary marker`：已命中“中间进度被误标成功”。
- `REASON=ok status but assistant stopReason indicates incomplete/error end`：session 结束态异常（toolUse/tool_calls/error）。
- `REASON=ok status but session file missing`：run 为 `ok` 但 session 文件丢失，输出 `RESULT=warn` 且退出码非 0（阻断）。
- `REASON=runtime patch marker coverage incomplete`：`gateway-cli-*.js` 未全量命中 marker，先重打 runtime hardening。

覆盖范围：
- 不带 `--all-jobs` 时，只检查单个 job（默认 `AI 自主学习`，可通过 `--job-id` 指定）。

## pairing required 快速排障

```bash
# 查看 pending repair 请求（自动流程已内置，仅用于人工确认）
openclaw devices list --json

# 仅在确认是本机 CLI/gateway-client 的 repair 请求时执行
openclaw devices approve --latest --json
```

## launchd 定时任务（可选，当前推荐改用 Codex 自动化）

```bash
# 安装/刷新每天 04:00 任务
bash /Users/crane/.openclaw/scripts/install-daily-auto-update-launchd.sh

# 查看状态
launchctl print gui/$(id -u)/ai.openclaw.daily-auto-update.local
```
