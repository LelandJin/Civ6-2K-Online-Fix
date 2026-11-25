# Civilization VI 2K 在线修复工具

这是一个面向 Windows Steam 版《文明 VI》的非官方社区工具，用于处理一种特定情况：电脑网络正常，但游戏启动后 2K 服务一直显示离线。

> 本项目与 2K、Firaxis Games、Take-Two Interactive 或 Valve 无隶属或背书关系。工具只支持源码中明确列出的游戏构建，无法确认安全时不会处理游戏进程。

> **本仓库地址（2.x 扩展维护版）：** [github.com/LelandJin/Civ6-2K-Online-Fix](https://github.com/LelandJin/Civ6-2K-Online-Fix)。从其他渠道获得本工具时，请以本仓库的 [Releases](https://github.com/LelandJin/Civ6-2K-Online-Fix/releases)、源码标签和 SHA-256 校验值为准。普通问题可提交到 [GitHub Issues](https://github.com/LelandJin/Civ6-2K-Online-Fix/issues)，安全问题请按 [`SECURITY.md`](SECURITY.md) 私下报告。

## 开源致谢与上游项目（Upstream Attribution）

- 本项目基于 **[yeeesy/Civ6-2K-Online-Fix](https://github.com/yeeesy/Civ6-2K-Online-Fix)**（MIT License，`v1.0.0` – `v1.2.0`）二次开发扩展而来。核心的 `_Mtx_unlock` Guard、运行时身份核验与 Fail-Closed 安全边界、脱敏诊断报告以及签名自动更新架构均源于上游作者 **yeeesy** 及贡献者（包括 PR #2 贡献 `1.0.12.72` 配置的 **TUcookie**）的卓越工作。
- `v2.1.0` – `v2.2.0` 在保留上游完整安全模型与构建支持的基础上，新增了对游戏 `1.0.12.74`（DX11/DX12）的支持，并集成了 `NO_PROXY`/`ProxyOverride` 代理绕行、失效 `hosts` / 失效 DoH / 虚拟网卡 DNS 清理以及创意工坊模组自动下载开关修复。

## 当前版本

**2.2.0** 已适配 Windows Steam 版《文明 VI》`1.0.12.74`、`1.0.12.72` 与 `1.0.12.68` 的 DX11 和 DX12，并持续完善 **2K 网络全链路修复** 与 **创意工坊模组自动下载/缓存修复**。
- 启动预检自动写入兼容游戏内置 `libCurl` 的 `NO_PROXY` 白名单（`*.2kcoretech.online`、`*.my.2k.com`、`*.firaxislive.com`、`172.16.0.0/12`），并在存在系统代理 `ProxyOverride` 时自动补齐 2K 域名直连，同时自动开启 `UserOptions.txt` 的 `AutoModDownload 1`。
- 点击界面右上角 **「网络/模组修复」**（或使用 `--repair-net-mods` 参数）可一键清除 `hosts` 中过期的 2K/FiraxisLive 静态 AWS IP（防止节点轮换后证书错误/超时）与遗留 `/32` 路由，清理 `ZeroTier` / `UU Lanplay` / `WireGuard` 等虚拟网卡上的死链 DNS 与 `fec0:0:0:ffff::1` IPv6 DNS，配置物理网卡公共 DNS，并备份重置 `Mods.sqlite` 与 `Cache` 目录。

| 渲染器 | 状态 | 工具行为 |
| --- | --- | --- |
| 1.0.12.68 DX11 / DX12 | 已验证 | 精确匹配并通过运行时校验后可修复 |
| 1.0.12.72 DX11 / DX12 | 已验证 | 精确匹配并通过运行时校验后可修复 |
| 1.0.12.74 DX11 / DX12 | 已验证 | 精确匹配并通过运行时校验后可修复 |
| 未知或更新后的游戏构建 | 不支持 | 拒绝处理 |

## 原理

在受影响的游戏构建中，2K 在线模块可能在本机初始化时遇到线程同步错误，使后续初始化无法继续，因此即使网络正常，游戏也会显示 2K 离线。

本工具会等待游戏启动，确认实际运行的是受支持的 DX11 或 DX12 构建，并核对进程、游戏文件和系统运行库。全部检查一致后，它只纠正这一次已确认的本地同步错误，让游戏原有的 2K 初始化流程继续执行。

工具不会伪造登录结果，也不会绕过 Steam/2K 的账号、游戏所有权或服务器认证。不同电脑、系统运行库和启动时序会影响故障是否出现，所以并非每位玩家都会遇到该问题。

## 使用方法

1. 完全退出《文明 VI》。
2. 从官方 Releases 下载 ZIP，核对 SHA-256 后解压。
3. 运行 `Civ6_2K_Online_Fix.exe`，无需管理员权限。
4. 工具进入监听后，在 Steam 中点击“开始游戏”并选择 DX11 或 DX12。
5. 等待工具显示最终结果。成功后可以关闭工具窗口；本次保护会随游戏进程退出而结束。

GUI 默认只监听，不会自行启动游戏。这是推荐方式，因为你可以在 Steam 中明确选择 DX11 或 DX12，工具会按实际启动的游戏自动识别。也可以点击“用 Steam 默认项启动”或使用 `--auto-launch-steam`，但该方式使用 Steam 当前的默认启动项，不能保证渲染器。

常用命令：

```text
Civ6_2K_Online_Fix.exe                      图形界面；默认只监听
Civ6_2K_Online_Fix.exe --watch-only         显式只监听
Civ6_2K_Online_Fix.exe --auto-launch-steam  请求 Steam 使用默认启动项
Civ6_2K_Online_Fix.exe --no-gui             无图形界面
Civ6_2K_Online_Fix.exe --diagnose           只读诊断
Civ6_2K_Online_Fix.exe --self-test          纯离线自检
```

如需让无参数启动也自动请求 Steam，可将 `Civ6_2K_Online_Fix.ini.example` 复制为同目录下的 `Civ6_2K_Online_Fix.ini`，再把 `auto_launch_steam` 改为 `1`。默认值为 `0`。

从 1.2 起，检测结束后点击 **反馈问题**，会打开本次完整的脱敏 TXT，可直接作为附件发送。重新打开工具后可从 **报告文件夹** 找到以前的报告；1.1 用户仍可用“复制脱敏诊断”。

**检查更新**只比较工具版本。发现新的正式版后，选择“是”即可下载、验证并更新工具。正在监控时，更新会在本轮会话结束后安装，配置和反馈文件保留。首次从旧版升级到带此功能的版本，仍需下载一次 ZIP。

`1.1.0` 的增强诊断提供读取质量、相对时间线和超时分类，详见 [脱敏诊断与超时反馈](docs/DIAGNOSTICS.md)。旧版 `1.0.0` 仍采用简要报告格式，请以报告中的诊断格式为准。超时只表示未在期限内确认同时就绪，不等于数据库损坏；不要因此直接删除 SQLite 文件。

## 安全与隐私

- 不修改游戏文件、存档、Mod、Steam 配置或账号数据。
- 不安装服务、驱动、计划任务、启动项或后台常驻程序。
- 只有精确匹配的受支持构建能够进入处理流程；未知构建会失败关闭。
- 处理前会重新确认目标进程、游戏映像、系统运行库及目标位置仍与预期一致。
- 遇到身份变化、所有权冲突、写入不完整或恢复结果不确定时，会停止并明确报告失败。
- 日志只保存在本机且不会自动发送；公开反馈请使用脱敏摘要。

## 局限性

- 仅支持源码中列出的 Windows Steam 构建；游戏更新后可能需要新增兼容配置。
- 只处理上述本地初始化故障，不能修复 2K/Steam 服务中断、网络封锁、账号问题、Mod 冲突或多人数据不同步。
- 当前发布未做商业 Authenticode 代码签名，Windows SmartScreen 或安全软件可能显示“未知发布者”。请只从官方 Releases 下载并核对 SHA-256，不要因此关闭安全软件。
- 任何进程内修复都无法完全消除并发风险；本项目通过严格识别和失败关闭来限制风险。

## 从源码构建

优先使用 Visual Studio 2022 C++ x64 工具链（`/analyze` 与可复现链接，GitHub Actions CI 默认使用该工具链）；本机未安装 Visual Studio 时，`build.ps1` 会自动回退到 MinGW-w64 (`g++` + `windres` + `.NET Framework 4.x csc.exe`)：

```powershell
& '.\build.ps1' -Analyze
& '.\build\Civ6_2K_Online_Fix.exe' --self-test
```

产品版本的唯一来源是根目录 `version.json`。开发和发布规则见 [`docs/MAINTAINER.md`](docs/MAINTAINER.md)，安全报告见 [`SECURITY.md`](SECURITY.md)，贡献方式见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。项目继续沿用 [MIT 许可证](LICENSE)。

## English summary

Civ6 2K Online Fix is an unofficial Windows helper for a local OpenSSL `_Mtx_unlock` initialization failure and 2K/Mod network blockers in the Steam version of Civilization VI. Forked from and crediting **[yeeesy/Civ6-2K-Online-Fix](https://github.com/yeeesy/Civ6-2K-Online-Fix)** (and **TUcookie** for `1.0.12.72` profiles), version `2.2.0` supports verified DX11 and DX12 builds of `1.0.12.68`, `1.0.12.72`, and `1.0.12.74`, automatically configures `libCurl`-compatible `NO_PROXY`/`ProxyOverride` bypasses and `AutoModDownload 1`, cleans stale `hosts`/DoH/virtual-adapter DNS stalls, exports shareable diagnostics, and builds cleanly under both MSVC and MinGW-w64. See [github.com/LelandJin/Civ6-2K-Online-Fix](https://github.com/LelandJin/Civ6-2K-Online-Fix).
