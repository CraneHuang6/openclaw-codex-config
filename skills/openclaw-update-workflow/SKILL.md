---
name: openclaw-update-workflow
description: Use when maintaining OpenClaw on this machine after version updates, including reapplying local patches, running daily health checks, and diagnosing update-related regressions such as Feishu no-reply.
---

# OpenClaw Update Workflow

## Overview

把本机 OpenClaw 的“更新 + 重打补丁 + 自检”流程统一成一套可重复执行的操作。
优先调用本技能脚本，不重复手工拼命令。

## When to Use

- 升级 OpenClaw 到新版本后，需要自动重打本地补丁。
- 每日巡检，默认先检查最新版和本机健康状态；若显示有新版本则自动进入 `full` 升级链路。
- 更新后出现 Feishu 无回复、gateway timeout、model 回退等问题。
- Feishu 能收到文本但看不到语音/附件（常见日志：`Local media path is not under an allowed directory`）。
- Feishu 对话里出现异常短回复 `NO`（尤其在 `dispatch complete (queuedFinal=false, replies=0)` 附近）。
- 需要刷新 launchd 每日 4 点自动更新任务。

## Quick Start

默认入口脚本：

```bash
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh <mode> [-- extra args]
```

模式：

- `monitor`：巡检监控（先 `--skip-update` + 检查 `latest_version` + 生成报告；若 `latest_version > before_version` 则自动执行 `full`）。
- `stable`：日常稳定维护（`--skip-update`）。
- `full`：真实升级（`--with-update`，含三阶段自愈/回滚链路）。可人工手动强制触发。
  - 升级链路会先尝试安装 OpenClaw 最新 `.dmg`（GUI），再执行 CLI 更新与补丁。
- `patch`：仅重打统一补丁链（不执行 `openclaw update`）。
- `launchd-refresh`：刷新系统级每日自动更新任务。
- `doctor`：快速健康检查（`status --deep` + `gateway probe` + `security audit --deep`）。
- `voice-doctor`：语音链路专检（默认只检查，可加 `--apply` 自动修复默认音色与情绪路由）。
- `feishu-no-reply`：飞书“收到消息但无回复”快速预检（通道健康 + 最近入站/派发标记 + 致命插件报错 + gateway launchd 代理环境/可达性快照）。
- `feishu-single-card`：飞书单卡流式配置（`apply|verify|rollback`，避免流式回复被切成 20+ 条）。
- `feishu-single-card-accept`：飞书单卡流式验收（按唯一标记抓取同一窗口，判定 `Started + Closed + replies=1`）。
- `selfie-key-precheck`：自拍链路 Gemini Key 优先级预检（强制注入无效 `GEMINI_API_KEY`，验证仍可成功出图）。
- `cron-partial-precheck`：Cron“状态显示成功但只输出中间进度”回归预检（检查 run 状态、session stopReason、runtime patch marker 覆盖率；支持 `--all-jobs` 全量扫描）。

## Proxy (Clash LAN)

- 当 Codex 自动化环境无法访问本机 loopback（`127.0.0.1:7897`）时，使用 LAN 变量注入：
  - `OPENCLAW_SKILL_HTTP_PROXY_HOST`（例如 `192.168.1.2`）
  - `OPENCLAW_SKILL_HTTP_PROXY_PORT`（默认 `7897`）
  - `OPENCLAW_SKILL_SOCKS_PROXY_PORT`（默认 `7897`）
- 预检开关：
  - `OPENCLAW_SKILL_PROXY_PRECHECK_ENABLED`（默认 `1`）
  - `OPENCLAW_SKILL_PROXY_PRECHECK_URL`（默认 `https://registry.npmjs.org`）
  - `OPENCLAW_SKILL_PROXY_PRECHECK_TIMEOUT`（默认 `5` 秒）
  - `OPENCLAW_SKILL_PROXY_PRECHECK_ATTEMPTS`（默认 `2`，失败后短重试）
  - `OPENCLAW_SKILL_PROXY_PRECHECK_RETRY_DELAY`（默认 `1` 秒）
- monitor 自动升级开关：
  - `OPENCLAW_SKILL_MONITOR_AUTO_FULL_ON_NEW_VERSION`（默认 `1`；设为 `0` 时仅巡检不自动执行 `full`）

```bash
OPENCLAW_SKILL_HTTP_PROXY_HOST=192.168.1.2 \
OPENCLAW_SKILL_HTTP_PROXY_PORT=7897 \
OPENCLAW_SKILL_SOCKS_PROXY_PORT=7897 \
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor
```

## Standard Workflow

1. 先选模式：Codex 自动化默认用 `monitor`（检测到新版本会自动进入 `full`）；日常手工维护可用 `stable`；需要无条件升级时可手动用 `full`。
2. 执行封装脚本，并把额外参数透传给底层脚本（例如 `--feishu-target`、`--skip-launchd-check`）。
   - 统一更新脚本会校验 media-path 补丁 marker（`/tmp -> state/workspace/tmp-media` 桥接 + `uploadDurationCandidates` + `msgTypeCandidates(audio/media/file)`），缺失即失败，避免“看似成功但语音/附件发送回退”。
   - 统一更新脚本会校验 dedup 持久化导出 marker（`tryRecordMessagePersistent`），缺失即失败，避免“飞书能收消息但处理阶段崩溃无回复”（常见报错：`TypeError: ...tryRecordMessagePersistent is not a function`）。
   - 统一更新脚本会校验 reply-media 文本兜底解析 marker（`Saved: ./...png` / 裸路径 / Markdown `![...](...)`）与语音模式文本抑制 marker（`!params.forceVoiceModeTts` + `suppressTextDelivery`），防止飞书只回显文件路径文本或“先发文字再发语音”。
   - 统一更新脚本会校验 reply-voice 快路径 marker（回复消息 + `生成语音`，500 分段，失败即中断），并校验“缺脚本提示文案 + checked paths + 默认 `--voice-id wakaba_mutsumi` + `OPENCLAW_REPLY_VOICE_TTS_TIMEOUT_MS` + `reply voice script execution failed (timeoutMs=`”标记，防止升级后回退到普通文本回复、弱化报错、60 秒硬超时或音色漂移（如 `metis`）。
  - 统一更新脚本在关键路径启用锚点区间结构校验（例如 `finally { ... } -> onError:` 的 dispatcher mirror 写回区间，和 `if (voiceQueuedButNoDeliveryDelayFallbackState) { ... }` 的 no-delivery 分支区间），避免“仅伪造 marker 文本”误判为已修复。
  - reply-voice 补丁需兼容 dispatch options 锚点顺序漂移（`replyOptions`/`timeoutOverrideSeconds`/`thinking` 的顺序变化）与 `replyOptions` 键值写法漂移（如 `replyOptions: replyOptions` / 临时缺失），并强制保留 `forceVoiceModeTts: voiceModeEnabled`；同时要求 `createFeishuReplyDispatcher(...)` 调用内也注入 `forceVoiceModeTts: voiceModeEnabled`，避免升级后出现“语音模式已开启但仍走文本发送”。
   - 统一更新脚本会额外校验语音模式状态链路 marker（`voiceModeStateCache` + `handled voice mode command locally` + `forceVoiceModeTts: voiceModeEnabled` + `voice mode enabled for session`），防止升级后“语音模式开关看似生效但仍按文本路径下发”。
   - `full` 模式会强制执行 `openclaw gateway install --force`，并自动守卫/补装 `@larksuiteoapi/node-sdk`（缺失时自动安装）。
  - 日更脚本对 `status --deep` 的 `gateway closed (1006 ...)` 增加一次短重试（常见于 gateway 重启窗口），避免误报失败。
  - 日更脚本内置并发锁、`openclaw.json` 权限自修复、DNS/HTTP 预检、以及 `gateway probe` 的 `EPERM(127.0.0.1)` 环境限制降级。
  - 日更脚本写报告前会自动 `mkdir -p workspace/outputs/system-updates`，避免首次迁移或目录被清理后因 `REPORT_FILE` 路径不存在直接失败。
  - 若 DidaAPI 子任务补丁命中 `target file missing:`，统一补丁脚本会记录并跳过，不再触发整条更新流程回滚；其他 DidaAPI 错误仍按失败处理。
3. 读取输出里的 `REPORT_FILE=...`，按报告字段判定：
   - `dns_precheck`
   - `status_deep`
   - `gateway_probe`
   - `security_audit`
   - `gateway_self_heal` / `gateway_self_heal_actions`
   - `feishu_probe`
   - `first_error_class` / `result_domain`
   - `known_bug_fix` / `known_bug_fix_signature`
   - 若出现 `pairing required`，优先确认报告里是否已触发 `approve-pairing-repair` 自动自愈；仅当请求非 `cli`/`gateway-client` repair 或 approve 失败时再人工介入
4. 若失败，优先按 `references/update-flow-cheatsheet.md` 里的“单项补丁/排障命令”执行，不要直接改核心脚本。

## Gate D2 自动提交（白名单）

- 默认开启：`OPENCLAW_SKILL_AUTO_COMMIT_ENABLED=1`。
- 仅当 `OPENCLAW_SKILL_GATE_D2_VERDICT=PASS` 时才会触发自动提交。
- 自动提交固定在 `/Users/crane/.codex` 仓库执行，且仅允许以下路径：
  - `AGENTS.md`
  - `skills/openclaw-update-workflow/**`
- 若存在白名单外脏改动，自动提交会直接跳过（fail-closed），不会强行提交。
- 自动提交只做 `git commit`，不会 `git push`。

可选变量：

- `OPENCLAW_SKILL_AUTO_COMMIT_ENABLED=0`：关闭自动提交。
- `OPENCLAW_SKILL_GATE_D2_VERDICT=PASS|FAIL|UNKNOWN`：门禁结论（默认 `UNKNOWN`）。

运行后可在输出中检索以下字段：

- `AUTO_COMMIT_RESULT=committed|skipped|failed`
- `AUTO_COMMIT_REASON=ok|gate_d2_not_pass|dirty_outside_allowlist|no_changes|sensitive_file_detected|...`
- `AUTO_COMMIT_HASH=<short_sha>`
- `AUTO_COMMIT_FILES=<comma-separated paths>`

## Known Fixes Only

- 自动修复仅允许命中已登记 signature（例如 `gateway_1006`、`missing_reply_voice_script`、`missing_dedup_persistent_export`、`didaapi_target_missing`、`dns_network`）。
- `gateway_1006` 的 apply 动作为分层自愈：`openclaw gateway restart`，若仍不健康则补做 `openclaw gateway install --force` + `openclaw gateway start`，最后 `openclaw gateway probe` 并以 `gateway status --json` 同时满足 `runtime.status=running` 且 `rpc.ok=true` 作为通过标准。
- `dns_network` 属于基础设施问题，只允许跳过/汇报，不自动改代码或改配置。
- 未知错误（`unsupported`）必须停止自动修复，写 inbox，并保留报告供人工排查。
- 运行已知修复脚本前建议先 `--dry-run`，确认 signature 判断正确后再 `--apply`。

## Automation Memory (经验沉淀)

- 日更报告会输出 `REPORT_FILE=...`；可用本地脚本提取摘要并追加到 Codex 自动化 memory：
  - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/append-openclaw-update-memory.sh --report <REPORT_FILE>`
- 摘要字段包含：`mode/result`、版本前后、`dns_precheck`、`status_deep`、`gateway_probe`、`security_audit`、`feishu_probe`、`first_error_class`、`result_domain`。
- 目的：沉淀“这次自动化真实发生了什么”，避免下次重复误判为功能 bug。

## 2026.3.1 经验沉淀（monitor/helper anchor）

- `monitor` 不是纯只读巡检：会执行统一补丁链（`--skip-update --no-restart`），所以补丁锚点漂移会在 `monitor` 暴露。
- `helper anchor not found` 的典型根因：`media.ts` 注释锚点文本漂移（例如句号/说明行变化）导致单锚点匹配失效。
- 快速判定命令（先 A 再 B）：
  - A: `bash /Users/crane/.openclaw/scripts/repatch-openclaw-feishu-media-path.sh --dry-run`
  - B: `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor`
- 固定验收口径：
  - A 输出不包含 `helper anchor not found`
  - B 输出包含 `STATUS=ok`

## 2026.3.5 经验沉淀（monitor/onModelSelected 误报）

- 现象：`monitor` 报 `reply dispatcher onModelSelected anchor not found`，但 `status_deep/gateway/security` 本体可能仍健康。
- 根因：Codex 技能副本 patcher 与运行时源码结构漂移（旧锚点 `onModelSelected: prefixContext.onModelSelected,` 不再匹配回调块写法）。
- 固化策略（已落地）：
  - `run_openclaw_update_flow.sh` 默认走 `OPENCLAW_HOME/scripts`（单一来源），不再默认走技能目录副本脚本。
  - 仅 `skip-update` 下，若 `first_error_class=update_or_patch` 且 `status_deep/gateway_probe/security_audit=pass`，降级 `status=warning`（退出码 0）。
  - `openclaw-daily-inspect-cron.sh` 将 `status=warning` 视为健康，不触发“系统异常”通知。
- 验收命令（固定）：
  - `bash /Users/crane/.openclaw/scripts/tests/daily-auto-update-local.test.sh`
  - `bash /Users/crane/.openclaw/scripts/tests/openclaw-daily-inspect-cron.test.sh`
  - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/tests/run_openclaw_update_flow.monitor-auto-full.test.sh`
- 判定补充：
  - 若 `monitor` 失败分类是 `gateway_probe` 或 `fallback availability check failed`，按运行态故障处理，不归因于本条锚点误报。

## Feishu Media Quick Fix

当出现“文本能发、语音/附件看不到”时，按这个最短链路处理：

1. 检查错误日志：
   - `rg -n "Local media path is not under an allowed directory" /Users/crane/.openclaw/logs/gateway.err.log -S | tail -20`
   - `rg -n "voice fallback send failed|media send failed" /tmp/openclaw/openclaw-*.log /Users/crane/.openclaw/logs/gateway.err.log -S | tail -20`
2. 重打媒体路径补丁（含 `/tmp` 媒体桥接）：
   - `bash /Users/crane/.openclaw/scripts/repatch-openclaw-feishu-media-path.sh --apply`
3. 重启并探测 gateway：
   - `openclaw gateway restart`
   - `openclaw gateway probe`
4. 再次重试业务消息。
5. 若“飞书能收到 `.opus` 但无法播放”：
   - 先用 `ffprobe` 校验文件封装/时长，再确认 `media.ts` 存在 `uploadDurationCandidates` 与 `msgTypeCandidates(audio/media/file)` 重试逻辑。

## Voice ID 快速定位（默认音色异常）

当“语音模式确认文本正常，但听到的不是默认音色”时，先抓当次请求的 `voice_id`，不要只看推断：

1. 暂停情绪路由后重试一次同样问题消息。
2. 在日志里按时间窗检索 TTS 请求参数（重点看 `voice_id`）。
3. 期望默认值为 `wakaba_mutsumi`；若仍是其他值（如 `metis`），按该次请求链路继续排查配置覆盖来源。

## Feishu 默认音色异常一键修复（metis -> wakaba）

当“开启语音模式后仍听到 metis”时，优先走语音专检：

1. 只检查（不改配置）：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh voice-doctor`
2. 自动修复（推荐）：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh voice-doctor -- --apply`
3. 修复动作包括：
   - `openclaw` 技能配置默认音色固定为 `wakaba_mutsumi`
   - `openclaw` 技能配置 `OPENCLAW_TTS_API_MODE=auto`（优先走 gateway，失败可回落 legacy）
   - `openclaw` 技能配置 `OPENCLAW_TTS_ALLOW_LEGACY_FALLBACK=1`、`OPENCLAW_TTS_LEGACY_API_URL=http://127.0.0.1:9880/tts`
   - `openclaw` 技能配置 `OPENCLAW_TTS_GATEWAY_MAX_TIME=45`、`OPENCLAW_TTS_GATEWAY_DYNAMIC_TIMEOUT=1`（避免 20s 误超时）
   - `openclaw` 技能配置 `OPENCLAW_TTS_MAX_CHARS=120`、`OPENCLAW_TTS_SELF_HEAL_ON_TIMEOUT=1`（限制长文本卡死并在超时后自动拉起 TTS 服务）
   - `opclaw_tts_service` 的 `emotion_routing.enabled` 强制设为 `false`
   - `generate_tts_media.sh` 保持 gateway 主通道；通过 `openclaw` 配置开启 auto+fallback 兜底（降低“语音模式只回文字”概率）
   - `generate_tts_media.sh` 的 gateway 超时默认改为 `45s`，并按文本长度动态扩到上限（默认 `85s`），失败日志包含 `max_time`；当超时或 HTTP 500 时自动 `kickstart` `com.openclaw.gptsovits.backend/tts` 并等待健康检查恢复，默认再重试 1 次（重试文本默认压缩到 `80` 字）
   - 即使进入 legacy，默认参考音也固定为若叶睦（不再使用 metis 默认参考音）
   - 自动重启 `openclaw gateway`（以及已加载时的 `com.openclaw.gptsovits.tts`）

## Voice Fallback 预检（语音模式只回文字）

当“语音模式开启后只收到文字回复”时，先跑下面三条可判定预检：

1. 配置预检（A）：
   - `jq -r '.skills.entries["xiaoke-voice-mode"].env | [.OPENCLAW_TTS_API_MODE,.OPENCLAW_TTS_ALLOW_LEGACY_FALLBACK,.OPENCLAW_TTS_LEGACY_API_URL] | @tsv' /Users/crane/.openclaw/openclaw.json`
2. 回落能力预检（B，故意坏端口，关闭 self-heal 避免重启干扰）：
   - `OPENCLAW_TTS_API_MODE=auto OPENCLAW_TTS_ALLOW_LEGACY_FALLBACK=1 OPENCLAW_TTS_API_URL=http://127.0.0.1:1/tts OPENCLAW_TTS_LEGACY_API_URL=http://127.0.0.1:9880/tts OPENCLAW_TTS_SELF_HEAL_ON_TIMEOUT=0 bash /Users/crane/.openclaw/workspace/skills/xiaoke-voice-mode/scripts/generate_tts_media.sh --text "voice-fallback-precheck-B"`
3. 主通道预检（C，9890）：
   - `OPENCLAW_TTS_API_MODE=auto OPENCLAW_TTS_ALLOW_LEGACY_FALLBACK=1 OPENCLAW_TTS_API_URL=http://127.0.0.1:9890/tts OPENCLAW_TTS_LEGACY_API_URL=http://127.0.0.1:9880/tts bash /Users/crane/.openclaw/workspace/skills/xiaoke-voice-mode/scripts/generate_tts_media.sh --text "voice-fallback-precheck-C"`

通过标准：

- A 输出必须为：`auto<TAB>1<TAB>http://127.0.0.1:9880/tts`
- B 必须满足：退出码 `0`、`stdout` 含 `MEDIA:`、`stderr` 含 `fallback to legacy`
- C 必须满足：退出码 `0`、`stdout` 含 `MEDIA:`

## Feishu No-Reply Quick Fix (消息已收到但无回复)

当飞书显示“消息发出成功”但小可不回复、Mac App 正常时，优先排查 dedup 导出缺失：

1. 检查处理阶段异常日志：
   - `rg -n "tryRecordMessagePersistent|error handling message: TypeError" /Users/crane/.openclaw/logs/gateway.err.log -S | tail -20`
2. 重打 dedup 补丁（确保 `dedup.ts` 导出 `tryRecordMessagePersistent`）：
   - `bash /Users/crane/.openclaw/scripts/repatch-openclaw-feishu-dedup-hardening.sh --apply`
3. 重启并探测：
   - `openclaw gateway restart`
   - `openclaw channels status --probe --json`
4. 再次发送飞书测试消息（群聊需 `@小可`）。

快速预检命令（先看是否是通道卡住/插件加载异常）：

- `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh feishu-no-reply`
- 可选加窗口：`bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh feishu-no-reply -- --lines 200`
- 若预检出现 `REASON=gateway launchd proxy env detected but proxy endpoint is unreachable`，优先执行无代理重装/重启：
  - `openclaw gateway stop`
  - `env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY -u http_proxy -u https_proxy -u all_proxy -u no_proxy openclaw gateway install --force`
  - `openclaw gateway probe`

### 2026-03-07 经验沉淀：共享 DM 主会话竞争会伪装成 replies=0

1. 先按“共享主会话竞争”识别，不要直接归因给发送层：
   - 同一条消息窗口若同时出现 `dispatching to agent (session=agent:main:main)`、`dispatch complete (queuedFinal=false, replies=0)`，且 session transcript 后续仍能看到 assistant `provider=openclaw, model=delivery-mirror`，优先按“Feishu DM 与其他入口共享主会话，派发窗口先结束、答案后到”处理。
2. 最小修复动作：
   - live 运行态改 `/Users/crane/.openclaw/openclaw.json`：`session.dmScope="per-channel-peer"`
   - `openclaw gateway restart`
   - 飞书实测一条 DM，确认日志从 `dispatching to agent (session=agent:main:main)` 变成 `dispatching to agent (session=agent:main:feishu:direct:...)`
3. 配置文件边界要分清：
   - `/Users/crane/.openclaw/openclaw.json` 是 live 运行态配置，通常被 `.gitignore` 忽略
   - `/Users/crane/.openclaw/openclaw_codex.json` 才是仓库跟踪配置
   - 所以 live 修完不代表当前 repo 一定有可 merge 的 diff，要单独用 `git ls-files` / `git diff` 确认
4. 预检新口径：
   - 当 `feishu-no-reply` 输出 `RESULT=pass` + `REASON=inbound observed with async session delivery marker`，且同时附带 `LIKELY_ROOT_CAUSE=shared-main-dm-session-contention` 时，优先修 `dmScope`，不要先回退纯文本或重打无关补丁。

### 经验补充：预检误报与实时状态冲突

1. `feishu-no-reply` 可能因窗口内历史 `ParseError` 命中而误报 `RESULT=fail`（历史日志污染，不一定代表当前仍故障）。
2. 实时状态判定优先级高于历史窗口命中：当 `openclaw status --deep` + `openclaw gateway probe` + `openclaw channels status --probe --json` 全绿时，按“当前已恢复”判定。
3. 最近日志二次确认（仅检查近 400 行，避免历史污染）：
   - `tail -n 400 /tmp/openclaw/openclaw-$(date +%F).log | rg -n "ParseError|failed to load plugin" -S`
4. 该误报不阻断业务验证，直接在飞书实测一条消息（群聊需 `@小可`）。

### 2026-03-06 经验沉淀：6 步修复后以实时派发结果为准

1. 固定执行顺序（不要跳步）：
   - `patch -> restart -> probe -> channels status -> feishu-no-reply -> 飞书实测`
2. 判定口径：
   - 即使 `feishu-no-reply` 返回 `fail`，只要同时间窗真实消息满足 `received -> dispatching -> dispatch complete (queuedFinal=true, replies>=1)`，且未出现 `queuedFinal=false,replies=0`，按“当前已恢复”处理。
3. 最小验收命令：
   - `openclaw channels logs --channel feishu --lines 180`
   - `rg -n "dispatch complete|queuedFinal=false|replies=0|no final reply queued|sent no-final fallback text" /tmp/openclaw/openclaw-$(date +%F).log -S | tail -n 60`
   - 可选（按 messageId 精确定位）：`rg -n "<messageId>|dispatch complete|queuedFinal=false|replies=0" /tmp/openclaw/openclaw-$(date +%F).log -S`
4. 风险说明：
   - `feishu-no-reply` 的 `fail` 可能来自历史窗口命中旧 `ParseError`/`SyntaxError`，不应单独作为阻断条件。

### 2026-03-05 经验沉淀：No-Reply 按固定顺序修（观测先行）

1. 固定修复顺序（不要跳步）：
   - 先补可观测性：恢复 per-message `dispatch/reply metrics`，补齐 `runId` 全链路关联。
   - 再收敛模型回退：移除不可用 fallback，并把“默认值 + 日更脚本 + guard 脚本”一起改，避免被后续更新加回。
   - 最后才做策略修复：仅在 `queuedFinal=false && finalCount=0` 时做一次受控 retry；retry 失败再走兜底文本。
2. 必看日志字段（新口径）：
   - `messageId,eventId,sessionKey,runId,provider,model,thinkLevel,queuedFinal,repliesFinal,repliesBlock,repliesTool,dispatchMs,totalMs,firstDeliverMs,firstFinalDeliverMs,fallbackTextSent`
3. 模型路由收敛标准：
   - `agents.defaults.model.fallbacks` 只保留 `qmcode/gpt-5.2`。
   - `openrouter/arcee-ai/trinity-large-preview:free` 不参与 fallback（auth profile 可保留，不删）。
4. fallback 可用性守卫（fail-closed）：
   - `enforce-openclaw-kimi-model.sh` 在 `--verify-fallback-availability` 下必须执行 probe，并对 fallback 非 `ok` 直接失败。
   - 解析 `openclaw models status --json` 时，禁止“pipe + here-doc 读 stdin”写法；统一改为 argv 传入完整 probe 输出再解析，避免误报 `probe output missing JSON payload`。
5. 最小验收命令（与本次 RCA 对齐）：
   - `jq -r '.agents.defaults.model.fallbacks' /Users/crane/.openclaw/openclaw.json`
   - `openclaw models status --probe --probe-timeout 12000 --probe-concurrency 2 --json`
   - `bash /Users/crane/.openclaw/scripts/tests/enforce-openclaw-kimi-model.test.sh`
   - `bash /Users/crane/.openclaw/scripts/tests/daily-auto-update-local.test.sh`
   - `bash /Users/crane/.openclaw/scripts/tests/update-openclaw-with-feishu-repatch.test.sh`
6. Feishu 扩展定向单测注意项：
   - 全局 `vitest` 命令不可用时，用 `pnpm dlx vitest ...`。
   - `bot.test.ts` 定向回归前建议设置临时 dedup 文件，避免历史状态污染：
   - `OPENCLAW_FEISHU_DEDUP_STATE_FILE="$(mktemp /tmp/openclaw-feishu-dedup-test.XXXXXX.json)" pnpm dlx vitest run extensions/feishu/src/bot.test.ts -t "single-agent dispatch metrics and retry"`

### Thinking 占位文案回归（收到消息时显示 Thinking）

1. 现象：收到消息后占位文案回退为 `⏳ Thinking...`。
2. 根因定位：`/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/streaming-card.ts` 默认文案回退。
3. 修复目标：占位文案统一为 `让小可想一想...`，并重启 `openclaw gateway` 生效。
4. 验收命令：
   - `rg -n "让小可想一想\\.\\.\\.|⏳ Thinking\\.\\.\\." /opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/streaming-card.ts`

### 经验补充：飞书出现异常短回复 `NO`（静默前缀泄漏）

1. 先按“静默前缀泄漏”判定，不要直接当作文本兜底：
   - 关键特征是同一时间窗出现：
   - `dispatch complete (queuedFinal=false, replies=0)`
   - `streaming partial update #1`
   - 且没有 `sent no-final fallback text`
2. 先确认 runtime token 判定是否支持无下划线前缀碎片（`N` / `NO`）：
   - `rg -n "function isSilentReplyPrefixText" /opt/homebrew/lib/node_modules/openclaw/dist/tokens-*.js -S`
3. 若判定函数未覆盖 `N|NO`，按最小改动修复 `isSilentReplyPrefixText`：
   - 仅对 `^[A-Z_]+$` 形态判定前缀，避免误伤自然语言。
   - 明确完整 token（`NO_REPLY`）不走 prefix 分支（交给精确静默逻辑）。
   - 允许无下划线短前缀（`N` / `NO`）命中 `NO_REPLY` 前缀。
4. 修后立即回归（两份 chunk 都要过）：
   - `node --input-type=module` 导入 `tokens-*.js`，校验：
   - `N`/`NO` => `true`
   - `NO_REPLY` => `false`
   - 普通文本（如 `Hello`）=> `false`
5. 若重启 gateway 时报 `Identifier 'deriveCronOutcomeFromRunResult' has already been declared`：
   - 先在 `gateway-cli-*.js` 去重重复函数定义，并统一调用到同一签名。
   - 再重启验证：`openclaw gateway restart` + `openclaw gateway status` + `nc -zv 127.0.0.1 18789`
6. 若 gateway 恢复但 Feishu 仍无回复，继续查插件编译：
   - `tail -n 200 /Users/crane/.openclaw/logs/gateway.err.log | rg -n "ParseError|SyntaxError|Unexpected token|Missing semicolon" -S`
   - 优先修复 `extensions/feishu/src/*.ts` 语法错误，再重启。
7. 最终验收口径：
   - gateway `running` 且 `RPC probe: ok`
   - Feishu 插件成功加载（日志可见 `feishu[default]: WebSocket client started`）
   - 复现场景不再出现可见 `NO` 短回复

## Feishu 长文本重复放大 + 人设漂移 联合排障

适用现象：

- 飞书长文本回复出现“段落循环放大”，`streaming partial update` 数量异常高（常见 >300）。
- 重复问题修复后，回复又偏离 `IDENTITY/SOUL`（日常语气过技术化、缺少动作/喵收束）。

关键实现面（运行时源码）：

- `/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/reply-dispatcher.ts`
- `/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/streaming-card.ts`
- `/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/bot.ts`

建议校验 marker（先判“补丁是否在位”）：

```bash
rg -n "trimRunawayRepeatedSuffix|normalizeStreamingPartial|mergeStreamingText|applyPersonaGuard|personaMode" \
  /opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/reply-dispatcher.ts \
  /opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/streaming-card.ts \
  /opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/bot.ts -S
```

重启与健康：

```bash
openclaw gateway restart
openclaw status --deep
```

日志验收（先看链路收敛，不先看主观感受）：

```bash
rg -n "received message from|Started streaming|streaming partial update #|dispatch complete|Closed streaming|persona guard applied" \
  /Users/crane/.openclaw/logs/gateway.log -S | tail -n 120
```

判定口径：

1. 不再出现“持续放大不收敛”（例如 partial 计数异常冲高后仍无 close）。
2. 同一会话能看到 `Closed streaming`，且时间上接近 `dispatch complete`。
3. 回复文本不再暴露控制标记（如 `[[reply_to_current]]`）。
4. 日常消息符合人设（动作开头 + 结尾喵收束 + 轻量陪伴句），技术消息保持技术风格不过度人设化。

人工回归矩阵（建议一次性做完）：

1. 日常闲聊 2 条：检查人设稳定性。
2. 技术排障 2 条：检查技术例外是否生效。
3. 长文本总结 1 条：检查“无循环放大 + 风格不漂移”。

## Feishu 单卡流式防分片（20+ 条）

适用现象：

- 飞书在流式回复时被切成很多条（常见 20+）。
- 重启/中断窗口里 `dispatch complete ... replies=<N>` 持续偏大。

核心结论：

- 在飞书卡片流式场景下，优先“单卡持续更新”，不需要块级分片。
- 关键是关闭 `blockStreaming`，保留 `streaming=true` + `renderMode=card`。

目标配置（`~/.openclaw/openclaw.json`）：

- `channels.feishu.streaming=true`
- `channels.feishu.blockStreaming=false`
- `channels.feishu.renderMode="card"`
- `channels.feishu.textChunkLimit=2000`
- `channels.feishu.chunkMode="newline"`
- `agents.defaults.blockStreamingDefault="off"`
- `agents.defaults.blockStreamingBreak="message_end"`

一键命令：

1. 先校验当前状态：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh feishu-single-card -- verify`
2. 应用单卡流式配置：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh feishu-single-card -- apply`
3. 需要回滚时：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh feishu-single-card -- rollback`
   - 或指定备份：`... -- rollback --backup <backup_path>`

日志验收口径（固定）：

```bash
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh \
  feishu-single-card-accept -- --marker "[A2-23:59]" --chat-id oc_4f9389b28a8b716d80b16ad3de07be3d
```

通过标准：

1. 验收脚本返回 `RESULT=pass` 且 `VERDICT=PASS`。
2. 同一窗口内有 `Started streaming` + `Closed streaming`，且 `REPLIES=1`。
3. 飞书界面表现为同一条卡片持续更新，而不是连续多条分片。

补充说明（避免误判）：

1. 必须先发送带唯一标记的长消息（建议 `>3000` 字，前缀如 `[A2-时分秒]`），再执行验收命令。
2. 日志中本地探测 `action=send` 与 `health-monitor stale-socket` 重启噪声不计入验收。
3. 若结果是 `REASON=replies_not_one`，先执行：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh feishu-single-card -- verify`
   - 再确认 `gateway.log` 存在 `config hot reload applied (channels.feishu.blockStreaming, channels.feishu.chunkMode, channels.feishu.textChunkLimit)`。

## Cron Partial-Report Quick Precheck (只发第一批资料/无最终报告)

当定时任务看起来“执行成功”，但只发了“第一批资料/等待继续搜索”等中间进度时，先跑预检确认是否命中 runtime 回归：

1. 执行预检（默认只检查 AI 自主学习 job）：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck`
2. 推荐执行全量扫描（覆盖全部 cron job）：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck -- --all-jobs`
3. 关键判定字段：
   - `RESULT=pass`：最近一次没有“半截成功”信号。
   - `RESULT=fail` + `REASON=ok status with interim summary marker`：run 被误标为 `ok`，但 summary 仍是中间进度。
   - `RESULT=fail` + `REASON=ok status but assistant stopReason indicates incomplete/error end`：session 末状态异常（如 `toolUse` / `tool_calls` / `error`）。
   - `RESULT=warn` + `REASON=ok status but session file missing`：run 标记 `ok` 但 session 丢失，按阻断处理（非 0 退出）。
   - `RESULT=fail` + `REASON=runtime patch marker coverage incomplete`：`gateway-cli-*.js` 未全量命中补丁 marker，需重打 runtime hardening。
4. 指定 job 检查：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck -- --job-id <job-id>`
5. 回看历史问题 session：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck -- --session-id <session-id>`
6. 覆盖范围说明：
   - 不带 `--all-jobs` 时只检查单个 job（默认 `AI自主学习` 或 `--job-id` 指定）。

## Mail Cron Workspace Path Precheck

当“检查邮箱”cron 任务出现 `/tmp/qq_mail_1.scpt` 相关写入失败，或需要防止 message 回退到 `/tmp` 路径时，先跑这条预检：

- `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/mail-cron-workspace-path-precheck.sh`

判定标准：

- `RESULT=pass`：message 同时满足三条约束（包含 `workspace/tmp/mail-check` 绝对路径、包含“严禁/禁止 /tmp /var/tmp /private/tmp”语义、并明确 `osascript -e/heredoc + 不落盘 .scpt`）。
- `RESULT=fail`：至少一条约束不满足；`REASON` 会给出具体违反项（如 `workspace_tmp_path`、`ban_tmp_statement`、`osascript_or_heredoc_no_scpt`）。

失败后的修复方向：

- 把 cron `payload.message` 中所有临时脚本/临时文件路径限制到 `workspace/tmp`（例如 `/Users/crane/.openclaw/workspace/tmp`）。
- 在 message 中明确写出“禁止 /tmp”或等价禁止语句。
- 在 QQ AppleScript 规则中补充：优先 `osascript -e` 或 heredoc，且写明“不落盘 .scpt”；若必须落盘，固定到 `workspace/tmp/mail-check`。

## Voice Mode No-Final Quick Fix (语音模式无语音回复)

当飞书收到消息但“无语音、无文本且无明显报错”时，先判定是否是 agent 无 final：

1. 抓关键日志：
   - `rg -n "embedded run agent end|dispatch complete \\(queuedFinal=.*replies=.*\\)" /tmp/openclaw/openclaw-*.log -S | tail -40`
   - `rg -n "SLOW_REPLY_NOTICE_TEXT|slow-reply notice|HARD_TIMEOUT_FALLBACK_TEXT|dispatch complete \\(queuedFinal=false, replies=0\\)" /tmp/openclaw/openclaw-*.log /Users/crane/.openclaw/logs/gateway.log -S | tail -60`
2. 分类判断：
   - 若同一条消息出现 `embedded run agent end ... isError=false` 且随后 `dispatch complete (queuedFinal=false, replies=0)`：属于无 final（不是 TTS 失败）。
   - 若出现 `Local media path is not under an allowed directory`：属于媒体路径问题，走 `Feishu Media Quick Fix`。
3. 重打 reply-voice + reply-media 补丁（含 no-final 文字兜底 + 错误文案文字优先）：
   - `bash /Users/crane/.openclaw/scripts/repatch-openclaw-feishu-reply-voice.sh --apply`
4. 重启并探测：
   - `openclaw gateway restart`
   - `openclaw gateway probe`
5. 再次发送飞书测试消息（群聊需 `@小可`）。

## Selfie API Key Invalid Quick Fix

当飞书提示 `API key not valid`，且日志存在 `Blocked skill env overrides for xiaoke-selfie: GEMINI_API_KEY` 时，优先执行以下预检：

1. 执行 Gemini key 优先级预检（脚本会临时注入无效环境变量）：
   - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh selfie-key-precheck`
2. 预期输出：`PASS: xiaoke-selfie ignored invalid env key...`
3. 若失败，检查：
   - `~/.openclaw/openclaw.json` 中 `skills.entries.xiaoke-selfie.env.GEMINI_API_KEY` 是否存在且有效；
   - `xiaoke-selfie/scripts/xiaoke_selfie.py` 是否已包含“优先读 openclaw.json + 无效 key 自动重试备用 key”逻辑。

## Feishu Reaction No-Reply Quick Fix（点赞后一直 thinking）

当“点赞 reaction 能触发入站，但飞书侧一直 thinking 或最终无回复”时，按下面流程处理。

### 症状与根因（本地已验证）

1. 典型症状：
   - 同一 reaction 事件出现 `dispatch complete (queuedFinal=false, replies=0)`。
2. 历史伴随错误（已修复）：
   - `streaming start failed ... 400`
   - `Invalid ids: [om_xxx:reaction:THUMBSUP:...]`
3. 根因拆分：
   - `replyToMessageId` 错把 synthetic reaction message_id 当 open_message_id（无效）。
   - reaction 语义文本过弱时，模型可能走 `NO_REPLY`（会表现成无 final）。

### 固化修复基线（最小改动）

1. synthetic event 必须补齐：
   - `message.root_id = 被 reaction 的原始 messageId`
   - 保留 `message.message_id = ...:reaction:...`（不改 dedup/日志语义）。
2. 回复目标保持：
   - `replyTargetMessageId = ctx.rootId ?? ctx.messageId`
3. reaction 路径禁用 streaming + thinking：
   - `disableStreaming: true`
   - `thinking: "off"`
4. partial 流中继续抑制 `NO_REPLY` 前缀碎片（避免出现 `NO`）。
5. reaction synthetic 文本建议带明确指令：
   - `Please acknowledge this reaction with a brief reply.`

### 验收命令（固定）

1. 抓最新 reaction 窗口（精确到单条事件）：
   - `L=$(rg -n "messageId=.*:reaction:" /Users/crane/.openclaw/logs/gateway.log | tail -n 1 | cut -d: -f1)`
   - `nl -ba /Users/crane/.openclaw/logs/gateway.log | sed -n "$((L-20)),$((L+30))p"`
2. 核对三项通过标准：
   - 有 `received message ...:reaction:... -> dispatching to agent -> dispatch complete (queuedFinal=true, replies=1)`。
   - 无 `Invalid ids: [...:reaction:...]` 新增命中。
   - 无 `streaming start failed ... 400` 新增命中。
3. 错误日志回看：
   - `rg -n "streaming start failed|Invalid ids" /Users/crane/.openclaw/logs/gateway.err.log /Users/crane/.openclaw/logs/gateway.log | tail -n 30`

### 仍失败时的分流

1. 若 `replies=0` 且无 `400`：
   - 优先判为模型 `NO_REPLY` 路径，先增强 reaction synthetic 文本指令，再复测。
2. 若仍出现 `400/Invalid ids`：
   - 先检查运行时是否命中实际打包产物（`/tmp/openclaw/openclaw-*.log` 的 `_meta.path.fullFilePath`），避免只改 `src` 未生效。
3. 若 `replies=1` 但 UI 仍显示 thinking：
   - 转查 typing indicator 清理链路（`added/removed typing indicator reaction` 是否成对）。

## Common Commands

```bash
# 每日巡检（自动化推荐；检测到新版本会自动 full）
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor

# 每日巡检但禁用自动 full（仅巡检）
OPENCLAW_SKILL_MONITOR_AUTO_FULL_ON_NEW_VERSION=0 \
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor

# 日常稳定维护
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh stable

# 真实升级（人工触发）
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh full

# 真实升级但跳过 .dmg 安装
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh full -- --skip-dmg-install

# 仅重打补丁
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh patch

# 刷新 launchd 定时
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh launchd-refresh

# 语音链路专检（检查/修复默认音色）
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh voice-doctor
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh voice-doctor -- --apply

# 飞书无回复快速预检
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh feishu-no-reply

# 飞书单卡流式（先校验，再应用）
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh feishu-single-card -- verify
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh feishu-single-card -- apply

# 自拍 Gemini Key 优先级预检
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh selfie-key-precheck

# Cron 半截报告回归预检
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh cron-partial-precheck
```

## Sync (Self-Contained Scripts)

- 本技能包含本地自包含脚本副本（`scripts/`），默认优先调用同目录脚本。
- 当 `~/.openclaw/scripts` 有更新时，先执行同步脚本再使用本技能：
  - `bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/sync-from-openclaw.sh --apply`
- 同步脚本会包含 `repatch-openclaw-nano-banana-model.sh`，避免 `full/monitor` 在“脚本不可执行/缺失”前置校验阶段直接失败。
- 同步脚本会从 `~/.openclaw/scripts` 复制更新/补丁脚本，并重写为同目录脚本优先；技能文档默认可从 Codex 技能目录自身读取（兼容已删除旧 OpenClaw 技能目录的场景）。

## Guardrails

- 不在技能内写入或回显密钥；认证信息仍通过既有环境变量流程注入。
- model/fallback 优先通过 guard 脚本收敛；若紧急止血临时手改 `openclaw.json`，必须在同批次同步 guard 默认与脚本测试，避免后续日更回灌。
- 发生失败时先用已有 repatch/guard 脚本，不引入新的网络依赖或临时黑魔法。
- 自动化只执行 `Known Fixes Only`；未知 bug 立即停止并转 inbox，不盲修。
- 回滚一致性依赖 snapshot 覆盖 `redact-*.js` + `run-main-*.js`，不要在更新后单独替换 `entry.js` 而不重打 runtime 补丁。

## References

- 完整命令清单：`references/update-flow-cheatsheet.md`
- 主流程 runbook：`/Users/crane/.openclaw/docs/runbooks/openclaw-update-local-patch-flow.md`
