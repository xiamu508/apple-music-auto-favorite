# Apple Music 自动收藏正在播放的歌曲

> **English summary**: A macOS automation that reads the currently playing song (Music.app or Spotify), verifies it against the Apple Music catalog via the iTunes Search API (with Simplified/Traditional Chinese conversion), opens the song's album page in Music.app, and clicks "Favorite" (喜爱) in the track row's "More" (更多) menu — fully automatically via the Accessibility API. No screen recording, no private frameworks. Tested on macOS 26. Typical run: 3–6 seconds.

在 Mac 上一键把**正在播放的歌**（Music.app 或 Spotify）添加到 Apple Music 的"喜爱"。专为配合 **快捷指令 (Shortcuts)** 使用设计，也可直接双击运行。

## 效果

播放中的歌曲 → 运行脚本 → **3~6 秒**后歌曲已出现在 Apple Music 的"喜爱歌曲"里，并有系统通知确认。重复运行会提示"已经在喜爱中"，不会误取消。

## 工作原理

```
① 读取正在播放          read-now-playing.applescript
   Music/Spotify 直接询问（优先播放中，其次暂停中）
        ↓
② 目录匹配核验          match_apple_music_track.py
   iTunes Search API 多地区并行搜索，简繁体互转匹配，
   歌名+歌手双重核对通过才继续（防止收藏错歌）
        ↓
③ 打开歌曲页            music:// 深链接打开专辑页（不会自动播放）
        ↓
④ 自动点击收藏          favorite-track.applescript
   辅助功能 API 定位歌曲行 → 点"更多(…)"→ 点"喜爱"
```

几个可靠性设计：

- **不依赖私有框架**：macOS 15.4+ 已封锁 MediaRemote 的 `NowPlaying` 接口，本项目全部使用公开的 AppleScript / Accessibility API
- **不依赖截屏 OCR**：辅助功能树直接定位控件，比图像识别快两个数量级也稳定得多
- **核验优先**：歌名得分 ≥0.88、歌手得分 ≥0.78 才自动收藏，否则打开搜索页让你手动确认；Spotify 的 `歌名 - 副标题` 与 Apple Music 的 `歌名 (副标题)` 格式差异已做归一化
- **跨区商店检测**：歌曲只在其他地区商店（如香港店的 Live 版）时，会明确提示而不是傻等失败
- **页面加载失败自愈**：Music 偶发"出错了"页面时自动重开链接重试

## 系统要求

- macOS（在 **macOS 26** 上开发测试；理论兼容 macOS 14+，未逐一验证）
- Apple Music 订阅、Music.app 已登录
- 播放源：Music.app 或 Spotify（可扩展其他支持 AppleScript 的播放器）
- `python3`（macOS 自带即可，无需 pip 安装任何东西——简繁转换库已内置在 `vendor/`）

## 安装

```bash
git clone https://github.com/<你的用户名>/apple-music-auto-favorite.git
cd apple-music-auto-favorite
chmod +x add-current-song-to-apple-music-search.command match_apple_music_track.py
```

### 授权（只需一项）

**系统设置 → 隐私与安全性 → 辅助功能**：允许运行脚本的 App（终端，或快捷指令）。

> 不需要屏幕录制权限。首次运行时 macOS 也可能弹窗请求"控制 Music/System Events"，点允许即可。

### 接入快捷指令

新建快捷指令 → 添加"运行 Shell 脚本"操作：

```bash
/path/to/apple-music-auto-favorite/add-current-song-to-apple-music-search.command
```

Shell 选 `zsh` 或 `bash` 均可。然后可绑定到菜单栏、键盘快捷键或 Siri。

## 使用

放着歌，运行脚本即可。结果通过系统通知/弹窗反馈：

| 反馈 | 含义 |
|---|---|
| 通知"已核对并收藏" | 成功 |
| 通知"已经在喜爱中" | 之前收藏过，无操作 |
| 弹窗"需要手动验证" | 核验分数不够（歌名/歌手对不上），已打开搜索页供手动确认 |
| 弹窗"歌曲不在本区商店" | 该版本只在其他地区商店提供，无法自动收藏 |
| 弹窗"需要辅助功能授权" | 按上文完成授权后重试 |

### 配置

搜索地区顺序可用环境变量覆盖（第一项视为你的账户所在商店）：

```bash
APPLE_MUSIC_COUNTRIES="CN,HK,TW,US,JP" ./add-current-song-to-apple-music-search.command
```

## 已知限制

- 自动点击的 1~2 秒内不要点击其他窗口（弹出菜单会被 Music 自动关闭，虽有重试机制）
- Spotify 播放广告/播客时无歌手信息，会走手动验证分支
- Apple Music 界面大改版可能导致控件定位失效（脚本内置了通用兜底遍历，且界面文案同时匹配中英文）
- 歌曲在你所在地区商店未上架时无法自动收藏（这是账户限制，不是 bug）

## 文件说明

| 文件 | 说明 |
|---|---|
| `add-current-song-to-apple-music-search.command` | 主入口（bash），编排全流程与用户反馈 |
| `read-now-playing.applescript` | 读取正在播放的歌名/歌手/来源 |
| `match_apple_music_track.py` | iTunes Search API 匹配核验（无第三方网络依赖，标准库实现） |
| `favorite-track.applescript` | 辅助功能自动收藏（固定路径快速定位 + 递归兜底） |
| `vendor/opencc/` | [opencc-python-reimplemented](https://github.com/yichen0831/opencc-python)（Apache 2.0），简繁转换 |

## 第三方许可

`vendor/opencc/` 为 [yichen0831/opencc-python](https://github.com/yichen0831/opencc-python) 的原样内置（Apache License 2.0，许可文件见 `vendor/opencc_python_reimplemented-0.1.7.dist-info/LICENSE.txt`）。

## License

本项目代码采用 [MIT License](LICENSE)。
