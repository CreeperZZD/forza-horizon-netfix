# Forza Horizon 4/5 线上联机修复脚本

一个用来解决 **《极限竞速：地平线 4 / 5》提示"无法连接线上"、卡在"正在寻找地平线生活"** 的一键脚本。

原理是把 Windows 的 **Teredo 隧道** 和 **Xbox Live 相关服务** 修好，让游戏能通过 IPv6 打洞和玩家直连。所有改动都会先备份，随时可以一键还原。

> 已在 Windows 11 实机验证：《地平线 5》可正常进入线上模式。
> 验证时 Teredo 状态为 `Type = enterpriseclient`、`State = qualified`，服务器 `win1710.ipv6.microsoft.com`。Windows 10 同理，仅供参考。

---

## 快速开始

1. 下载本仓库（`git clone` 或直接下载 ZIP 解压）；
2. 双击 **`Run-Fix.bat`**，在 UAC 弹窗点"是"，等待脚本跑完；
3. **重启电脑**；
4. 重启联网后，双击 **`Run-Status.bat`** 确认 Teredo 状态。

看到下面这样的输出就说明配置成功：

```
Type          : enterpriseclient (Group Policy)
Server Name   : teredo.remlab.net (Group Policy)
State         : qualified
Client Type   : teredo client
```

关键字段是 `Type = enterpriseclient`，`State = qualified`（或 `dormant` 也算正常）。

---

## 文件说明

| 文件 | 作用 |
|---|---|
| `Run-Fix.bat` | 双击直接执行修复（会弹 UAC） |
| `Run-Restore.bat` | 双击直接还原，自动恢复 NI 服务和 IPv6 |
| `Run-Status.bat` | 双击直接查看 Teredo 状态，不需要管理员权限 |
| `ForzaHorizonNetFix.ps1` | 核心脚本，由上面三个 bat 调用；不带参数运行则显示交互菜单 |
| `ForzaNetBackup.json` | 首次修复时自动生成的备份，**别删**，还原全靠它 |

也可以直接用命令行：

```powershell
.\ForzaHorizonNetFix.ps1 -Action Fix      # 备份并修复
.\ForzaHorizonNetFix.ps1 -Action Restore  # 还原
.\ForzaHorizonNetFix.ps1 -Action Status   # 只读，查看状态
```

---

## 脚本到底改了什么

| 步骤 | 动作 | 为什么要做 |
|---|---|---|
| 1 | 关闭各在用网卡的 `TCP/IPv6` 绑定 | 宽带拿到"假 IPv6"时，Windows 会让 Teredo 休眠，游戏以为有 IPv6 实则走不通 |
| 2 | 把 `NI *` 系列服务设为禁用 | NI（Multisim / LabVIEW）的 mDNS、Network Discovery 会干扰 Xbox 的服务发现 |
| 3 | 配置并启动 7 个 Xbox / 系统服务 | 这是**最关键的一步**，其中 `IP Helper (iphlpsvc)` 是 Teredo 的宿主服务，被优化软件禁用后必定连不上 |
| 4 | 写 Teredo 注册表与组策略等效项 | 家庭版没有 `gpedit.msc`，脚本直接写注册表达到同样效果 |
| 5 | 自动选服务器 + 设置企业客户端 + 验证 | 先校验域名是否还在、再按延迟排序，**设置后轮询状态，没进入 `qualified` 就自动换下一个** |

具体的服务清单：

| 服务名 | 修复后启动类型 |
|---|---|
| `iphlpsvc`（IP Helper） | 手动 + 运行 |
| `IKEEXT` | 自动 + 运行 |
| `lmhosts` | 自动 + 运行 |
| `XboxGipSvc` | 自动（无手柄时会自动休眠，正常） |
| `XblAuthManager` | 自动 + 运行 |
| `XboxNetApiSvc` | 自动 + 运行 |
| `XblGameSave` | 手动（游戏启动时按需拉起） |

---

## 为什么地平线联不上？（原理说明）

地平线的"地平线生活"是 **P2P 联机**：玩家之间要直连。绝大多数家庭宽带没有原生 IPv6，Windows 就靠 **Teredo** 把 IPv6 数据封装在 UDP 里走 IPv4，穿过 NAT 完成打洞。所以 Teredo 正不正常，直接决定能不能线上。

按常见程度排序，原因通常是：

1. **`IP Helper` 服务被禁用** —— 国内各种"系统优化、Ghost 精简系统"最爱禁它。它是 Teredo 的宿主，一停 Teredo 直接 offline，游戏就永远卡在"正在寻找地平线生活"。这是单机层面最常见的原因，也是本脚本重点修复的对象。
2. **默认 Teredo 服务器在国内不可达 / 公共服务器已失效** —— Windows 默认连微软的 `win1710.ipv6.microsoft.com`，常受 DNS 污染和国际出口影响。更麻烦的是，网上流传的那批公共 Teredo 服务器大部分已经下线。**2026-11 实测结果：**

   | 服务器 | 现状 |
   |---|---|
   | `teredo.trex.fi` | 域名有效（195.140.195.140），但不回 ICMP |
   | `win1710.ipv6.microsoft.com` | 域名有效，延迟约 114 ms，可直接用 |
   | `teredo.remlab.net` / `-debian.remlab.net` | 域名已解析不到 |
   | `teredo.autotrans.consulintel.com` | 域名已解析不到 |
   | `teredo.ipv6.microsoft.com` | 域名已解析不到 |
   | `teredo.ngix.ne.kr` | 域名已解析不到 |
   | `teredo.managemydedi.com` | 域名已解析不到 |

   所以照着老教程填 `teredo.remlab.net` 反而会让 Teredo 一直 `offline`（报 `failed to resolve server name`）。本脚本会先做域名校验再挑选，并在设置后验证状态。
3. **NAT 类型受限** —— 运营商大内网（CGNAT，本机是 `10.x` / `100.64.x`）、对称型 NAT（Symmetric）都会让打洞失败或频繁掉线。这部分**脚本治不了**，只能开路由器 UPnP、光猫改桥接、找运营商要公网 IP，或者挂加速器。
4. **虚拟网卡 / 软件冲突** —— 装了 Multisim、LabVIEW（NI）、Hamachi、部分加速器后，它们的虚拟网卡和服务会抢占 Teredo 的路由与接口优先级。所以对应措施是禁用 `NI *` 服务。
5. **注册表被写死禁用** —— `DisabledComponents = 0x8` 表示 Teredo 被显式关掉，多是优化软件干的，需要改回 `0`。
6. **"假 IPv6"干扰** —— 光猫给了 IPv6 地址但运营商没通路由，Teredo 会因"已有 IPv6"而休眠。这是关闭网卡 IPv6 的真正原因。

补充一句：**如果你家宽带有正常可用的原生 IPv6，不需要关 IPv6**，走原生比 Teredo 稳定。脚本默认按教程关掉了，跑通后可自行把 IPv6 打开测试。

---

## 什么时候需要还原

- **要用 Multisim / LabVIEW 等 NI 软件**：双击 `Run-Restore.bat`。会恢复 NI 服务启动类型、网卡 IPv6 绑定、注册表原值，并把 Teredo 恢复系统默认。
- 装了新网卡、换了网络环境后想重新来一遍：先还原，再重新修复，可避免设置叠加。
- 备份文件 `ForzaNetBackup.json` 首次修复后**不会被覆盖**，始终指向你最初的干净状态。

还原后建议重启。想再玩地平线，重新双击 `Run-Fix.bat` 即可，来回切换很安全。

---

## 注意事项

- 必须 **管理员权限**，脚本会自动弹 UAC。
- 脚本会修改服务启动类型、网卡绑定和 `HKLM` 注册表，属系统级改动。**请先看完上面的说明，了解每一项改的是什么再执行。**
- 本项目不是万能药。如果修复后 Teredo 已是 `qualified` 但游戏仍连不上人，看 `NAT` 那一行：`symmetric` 基本就是运营商/路由器层面的限制，属于脚本能力之外。
- 使用加速器与本脚本并不冲突，加速器通常自带 Teredo 处理，二者可以配合。

---

## 致谢

本项目的方法流程整理自 **小黑盒 @金木** 的教程：

【地平线4/5】由于网络问题无法连接线上的解决办法
https://api.xiaoheihe.cn/v3/bbs/app/api/web/share?h_camp=link&h_src=YXBwX3NoYXJl&link_id=5e096fa9cff9&new_post_share_style_v2=1

原作者的排查思路非常完整，本脚本只是把手工步骤自动化，并补了自动备份 / 一键还原 / 自动选服务器这几项。如果这篇教程帮到了你，请去原帖给作者点个赞。

也感谢所有在小黑盒评论区反馈实测情况的朋友。

---

## License

[MIT](LICENSE)
