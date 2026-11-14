## v1.0.2

- 普通模式：操作时显示重合的原窗口，首个补发事件清除镜像路由，减少点击、滚动无反馈；独立桌面仍只读。
- 短暂辅助功能超时不再判定窗口关闭；捕获失败保留置顶并有限重试。
- 普通与独立模式最小化都保留置顶会话，恢复原窗口后继续；不再直接清理独立桌面。
- 保留双击标题栏填充/还原、长按取消；显示 v1.0.2，无括号后缀。

macOS 14+，Apple Silicon。27 项自动测试通过；本机 macOS 26.6.2 验证不替代 MacBook Pro macOS 27.2 实测。

退出旧版后替换应用，确认面板显示 v1.0.2。授权辅助功能、输入监控、屏幕录制。ad-hoc 签名、未公证；确认来源后可在“隐私与安全性”选择“仍要打开”。无需修改 SIP。

[使用说明与边界](https://github.com/flyhu2/CClose-MacOS#readme)。鸣谢 [cclose / Chaohe Shi](https://github.com/chaohershi/cclose)、WindowPin、MoveItHere、Hammerspoon。
