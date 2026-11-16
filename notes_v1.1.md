## v1.1 更新 / What's new

### 修复 / Fixed

- **修复乱码**：`netsh` 在中文系统的输出是 GBK 字节，之前走管道被当成 UTF-8 解码，状态里全是乱码。现在改为重定向到临时文件后按字节解码（严格 UTF-8 失败则回退 GBK），中英文系统都正常显示。
  *Fixed mojibake:* `netsh` prints GBK on Chinese Windows, which was mis-decoded as UTF-8. Output is now captured to a temp file and decoded by bytes (strict UTF-8, fallback GBK).
- **修复判读失效**：之前按英文标签 `State:` 匹配，中文系统上永远读不到状态，会误报"未读到状态字段"。现在改用值关键字（qualified / dormant / offline / probe）判断，与界面语言无关。
  *Fixed verdict parsing:* it matched the English `State:` label, so Chinese systems always failed. Now it matches the value tokens only, independent of UI language.

### 新增 / Added

- **脚本双语**：所有输出中英双语，默认跟随系统语言，可用 `-Lang zh|en` 强制指定。
  *Bilingual output*, follows system language, override with `-Lang zh|en`.

### 用法不变 / Usage unchanged

1. 解压，双击 `Run-Fix.bat`，UAC 点"是"
2. 跑完重启
3. `Run-Status.bat` 查看，`Type = enterpriseclient` + `State = qualified` 即成功
