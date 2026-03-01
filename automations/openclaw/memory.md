# OpenClaw 每日备份 Memory

- 最近运行时间: 2026-03-01 03:07:05 CST
- 今日日期(本地): 2026-03-01
- 备份目录: /Users/crane/openclaw-backups/2026-03-01
- 备份大小: 9.0G
- 清理阈值: 早于 2026-02-22 的 YYYY-MM-DD 目录
- 已删除旧备份: 2026-02-21
- 备注: `rsync` 和 `cp -a` 分别被 socket 与特殊文件限制阻断，最终使用 `find ! -type s | pax -0 -rw -pe` 完成复制，只跳过运行时 socket。
- 当前运行时间: 2026-03-01 03:07:05 CST
