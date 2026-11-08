# 造梦西游OL · 账号切换工具

给多账号玩家用的小工具：**每个号手动登录一次，之后点一下按钮就换号**，不用反复输账号密码。
原理是把游戏登录后的"登录态数据"（`shared_prefs` / `databases` / `app_webview` 里的 cookie 和 token）
在 root 权限下打包成存档，换号时写回游戏目录并重启游戏。

仓库里有两个版本，功能一致，按使用习惯挑一个：

| 版本 | 位置 | 运行在哪 | 适合 |
|---|---|---|---|
| **安卓 App** | [`apk/`](apk/) | 模拟器 / 手机（需 root） | 平时就在模拟器里玩，点一下按钮换号 |
| **电脑版** | [`desktop/`](desktop/) | Windows（通过 adb 操作模拟器） | 想在电脑上批量管、或配合按键精灵调用 |

## 安卓 App（推荐）

安装包在 [`apk/`](apk/) 目录下（约 20 KB，包名 `com.zsw.switcher`）

```
打开 app → 手动登录一个号 → 填名字 → 点「抓取当前账号」
以后换号：点那个号的「一键登录」
```

界面：包名可改（默认 `org.yjmobile.zmxy`）、账号列表、一键登录 / 重抓 / 删除、诊断日志。
默认登录后 20 秒自动回写最新登录态（服务器会刷新 token，不回写存档会慢慢过期）。

细节、常见问题、重新编译方法见 **[apk/README.md](apk/README.md)**。

## 电脑版

双击 `desktop/启动换号器.bat`，选中模拟器设备 → 检测应用 → 抓取账号，之后点「一键登录」。
也支持命令行：

```powershell
powershell -File desktop/换号器.ps1 -Cli list
powershell -File desktop/换号器.ps1 -Cli capture -Name 大号 -Pkg org.yjmobile.zmxy
powershell -File desktop/换号器.ps1 -Cli login -Name 大号
```

细节见 **[desktop/README.md](desktop/README.md)**。

## 共同前提

- 设备/模拟器必须 **有 root**（雷电9：设置 → 其他设置 → root权限 → 开启 → 重启模拟器）
- 游戏包名要对（造梦西游OL：`org.yjmobile.zmxy`）

## 技术要点

- **存档内容自动发现**：不硬编码目录名，扫 `/data/data/<包名>/` 下除 `cache`、`code_cache`、`app_libs`
  之外的所有条目，换别的游戏也能直接用
- **权限还原**：`tar` 解包后 `chown -R` 回游戏自己的 uid + `restorecon`，避免游戏因权限错乱闪退
- **token 刷新回写**：每次登录服务器可能换发新 token，登录后自动重抓一次存档，防止存档过期
- 安卓版编译不依赖 Gradle：`aapt2 link` → `javac` → `d8` → `zipalign` → `apksigner`，
  脚本见 [`apk/build.ps1`](apk/build.ps1)

## 免责声明 / 风险提示

- 仅用于**你自己拥有的账号**之间快速切换，请勿用于倒卖、代练、共享他人账号等用途。
- 这是**登录凭证复用**：同一个号在两处同时使用会互相顶号；平台风控也可能判定为异常登录。
- 多数游戏的用户协议禁止第三方自动化/多开工具，**存在封号风险**，请先用小号测试。
- 存档等于账号钥匙（`/data/data/com.zsw.switcher/files/profiles/`），不要分享给任何人。
- 仅供学习交流，使用后果自负。

## License

MIT，见 [LICENSE](LICENSE)。
