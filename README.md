# Forza Horizon 4/5/6 线上联机修复脚本 / Online Fix

**中文** | [English](#english)

---

## 中文

一键修好 Windows 的 **Teredo 隧道** 和 **Xbox Live 服务**，解决地平线系列提示"无法连接线上"、一直卡在"寻找地平线生活"的问题。改之前会自动备份，随时能还原。

**实测可联机**：地平线 4 / 5 / 6 通用（同属 Xbox Live 联机），Windows 11 已验证。

### 下载

[![Download](https://img.shields.io/badge/Download-Latest%20Release-blue)](https://github.com/CreeperZZD/forza-horizon-netfix/releases/latest)

下载 `ForzaHorizon-NetFix-v1.1.zip`，解压到任意目录（路径别带特殊符号）。也可以直接 clone 仓库。

### 使用步骤

1. 双击 `Run-Fix.bat`，UAC 弹窗点"是"；
2. 等脚本跑完（会自动挑一个能用的 Teredo 服务器并验证状态）；
3. 重启电脑；
4. 联网后双击 `Run-Status.bat`，看到 `Type = enterpriseclient`、`State = qualified` 就是好了。

要用 Multisim / LabVIEW 时，双击 `Run-Restore.bat` 还原；再玩地平线就重新跑 `Run-Fix.bat`，来回切换不会打架。

### 文件

| 文件 | 作用 |
|---|---|
| `Run-Fix.bat` | 一键修复 |
| `Run-Restore.bat` | 一键还原（装回 NI 软件时用） |
| `Run-Status.bat` | 查看联机参数，无需管理员 |
| `ForzaHorizonNetFix.ps1` | 主脚本，支持 `-Action Fix/Restore/Status` 与 `-Lang Auto/zh/en` |
| `ForzaNetBackup.json` | 首次修复自动生成，**别删**，还原靠它 |

> 脚本输出中英双语，默认跟随系统语言；英文系统会自动显示英文，也可强制指定：`ForzaHorizonNetFix.ps1 -Action Status -Lang en`。

### 改了什么

| 步骤 | 动作 |
|---|---|
| 1 | 关闭网卡 IPv6（避免"假 IPv6"让 Teredo 休眠） |
| 2 | 禁用 `NI *` 系列服务（Multisim 等的 mDNS 会抢联机环境） |
| 3 | 启动 7 个 Xbox / 系统服务，关键是 `IP Helper` |
| 4 | 写 Teredo 注册表 + 组策略等效项（家庭版不用 gpedit） |
| 5 | 自动选服务器 → 设为 enterpriseclient → 验证，失败换下一个 |

### 为什么连不上

地平线的联机是 P2P，靠 Teredo 穿过 NAT 直连玩家。最常见的原因是 **`IP Helper` 服务被禁用**（优化软件最爱关它），Teredo 直接 offline；其次是 **服务器域名解析不稳定**——网上流传的那批公共服务器时通时不通，同一台机器换个网络解析结果都不一样，脚本每次运行都会重新校验并跳过解析不到的，再按延迟排序，设置后还会验证状态、不达标就自动换下一个。

如果状态已经是 `qualified` 但还是连不上，看游戏里的 NAT 类型：`严格 / 受限`、`symmetric` 属于运营商大内网，只能开 UPnP、光猫桥接或挂加速器，脚本管不到这一层。

### 注意

- 需要管理员权限，脚本会自动提权。
- 会改服务启动类型、网卡绑定和 `HKLM` 注册表，属于系统级修改，介意请先看完说明。
- 装了新的 NI 软件后要重新跑一次修复。

### 致谢

方法整理自小黑盒 **@金木** 的教程，思路非常完整，本仓库只是把手工步骤自动化：

【地平线4/5】由于网络问题无法连接线上的解决办法
https://api.xiaoheihe.cn/v3/bbs/app/api/web/share?h_camp=link&h_src=YXBwX3NoYXJl&link_id=5e096fa9cff9&new_post_share_style_v2=1

---

## English

One-click network fix for **Forza Horizon 4 / 5 / 6** on Windows. It repairs the **Teredo tunnel** and **Xbox Live services** behind the "Unable to connect online" / stuck on "Looking for Horizon Life" problem. Settings are backed up first, so you can always roll back.

Tested on Windows 11 with Horizon 5; Horizon 4 and 6 use the same Xbox Live networking, so the same fix applies.

### Download

Grab `ForzaHorizon-NetFix-v1.1.zip` from the [latest release](https://github.com/CreeperZZD/forza-horizon-netfix/releases/latest), unzip it anywhere (avoid special characters in the path), or just clone the repo.

### Usage

1. Double-click `Run-Fix.bat`, click **Yes** on the UAC prompt.
2. Let it finish — it picks a live Teredo server and verifies the state.
3. Reboot.
4. Run `Run-Status.bat`; `Type = enterpriseclient` and `State = qualified` means you're good.

Need Multisim / LabVIEW? Run `Run-Restore.bat` to roll back, then `Run-Fix.bat` again for racing. Switching back and forth is safe.

### Files

| File | Purpose |
|---|---|
| `Run-Fix.bat` | Apply the fix |
| `Run-Restore.bat` | Restore previous settings |
| `Run-Status.bat` | Show Teredo state (no admin needed) |
| `ForzaHorizonNetFix.ps1` | Main script (`-Action Fix/Restore/Status`, `-Lang Auto/zh/en`) |
| `ForzaNetBackup.json` | Auto-created backup, **do not delete** |

> Script output is bilingual and follows the system UI language (English UI → English text). Force it with `ForzaHorizonNetFix.ps1 -Action Status -Lang en`.

### What it changes

| Step | Action |
|---|---|
| 1 | Disable IPv6 binding on active adapters |
| 2 | Disable `NI *` services (Multisim's mDNS interferes) |
| 3 | Start 7 Xbox / system services, `IP Helper` above all |
| 4 | Write Teredo registry and policy-equivalent values (no gpedit needed) |
| 5 | Auto-select a server, set enterpriseclient, verify, fall back if needed |

### Why it breaks

Horizon's online play is P2P and relies on Teredo to punch through NAT. The usual culprit is a disabled **`IP Helper`** service — tuning utilities love to turn it off, which takes Teredo offline. Second is flaky server DNS: the public servers in old guides come and go, and the same machine may resolve different ones on different networks. The script re-checks every run, skips unresolvable entries, ranks the rest by latency, then verifies the state and falls back to the next server if needed.

If Teredo is `qualified` but the game still fails, check the in-game NAT type. `Strict` / `symmetric` means carrier-grade NAT — enable UPnP, bridge your modem, or use a gaming accelerator. That layer is out of scope.

### Notes

- Requires administrator rights; the script elevates itself.
- It modifies service startup types, adapter bindings and `HKLM` registry values.
- Re-run the fix after installing new NI software.

### Credits

Method based on the xiaoheihe guide by **@金木**; this repo only automates the manual steps. Original post: <https://api.xiaoheihe.cn/v3/bbs/app/api/web/share?h_camp=link&h_src=YXBwX3NoYXJl&link_id=5e096fa9cff9&new_post_share_style_v2=1>

---

## License

[MIT](LICENSE)
