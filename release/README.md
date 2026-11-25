# Release — KinetMinutes 1.4 (build 9)

> 全部上架材料。目标:Mac App Store,Productivity 分类,4+ 分级,付费下载 + 一次性 Pro。
> Bundle ID `com.kinet.minutes.app` · Team M92UKS6NA2 · macOS 14+ · Apple Silicon

## 材料清单

| 项 | 路径 | 状态 |
|---|---|---|
| ASC 元数据(八语 name/subtitle/promo/description/keywords/whatsnew) | `metadata-1.4/{en,ja,zh-Hans,zh-Hant,ko,fr,de,es}/` | ✓ 字符数全部达标 |
| 截图(八语 ×6,2560×1600 sRGB) | `screenshots-1.4/{lang}/01-hero … 06-settings.png` | ✓ 48 张已生成 |
| Review Notes(60-90 秒复测路径 + 分级问卷) | `review-notes.md` | ✓ |
| 隐私政策(八语,切换条 + 按浏览器语言自动选中) | `docs/privacy.html` → https://phinn.github.io/KinetMinutes/privacy.html | ✓ 200 |
| 营销页(八语) | `docs/index.html` → https://phinn.github.io/KinetMinutes/ | ✓ 首图已换 1.4 界面 |
| PrivacyInfo.xcprivacy | `Resources/PrivacyInfo.xcprivacy` | ✓ 打包进 bundle root |

## ASC App 信息

| 字段 | 值 |
|---|---|
| Name(八语) | en "KinetMinutes: Meeting Notes" · ja/zh 品牌 + 品类词 · ko/fr/de/es 见 `metadata-1.4/*/name.txt` |
| Subtitle | en "Record, transcribe, summarize"(29)· 其余八语见 `metadata-1.4/*/subtitle.txt` |
| Primary Category | Productivity(`public.app-category.productivity`) |
| 分级 | 4+(问卷答案见 review-notes.md) |
| 出口合规 | ITSAppUsesNonExemptEncryption=false |
| 价格 | $9.99 付费下载 + Pro 一次性内购($27.99);免费含录音/转写不限次 + 每月 5 次 AI 纪要 |
| SKU | kinetminutes100 |
| 版权 | Copyright © 2026 Kinet |

## 打包链路(照 KinetMagicDisk)

```bash
# 1. Archive
xcodebuild archive -project KinetMinutes.xcodeproj -scheme KinetMinutes \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath /tmp/km_archive.xcarchive \
  DEVELOPMENT_TEAM=M92UKS6NA2 CODE_SIGN_STYLE=Automatic

# 2. Export → pkg(ASC 要 pkg 不是 archive)
xcodebuild -exportArchive -archivePath /tmp/km_archive.xcarchive \
  -exportOptionsPlist release/dist/ExportOptions-appstore.plist \
  -exportPath /tmp/km_export -allowProvisioningUpdates

# 3. 上传(新 altool 用 --api-key,旧 --api-key-id 已废弃会报 29 错)
xcrun altool --store-type onboarded \
  --upload-package /tmp/km_export/KinetMinutes.pkg \
  --api-key WGY2HCFK9K --api-issuer d4da77ce-6781-4aef-acdd-c7480df892d5
```

## 注意
- LocalLLMKit 是本地包依赖(`../LocalLLMKit`),archive 前确认路径存在
- FTS5 migrate 需幂等;demo 会议数据随首启种子(见 review-notes「demo meeting」)
- 截图重摄:`app 内 KM_SNAPSHOT` 钩子出 `/tmp/km_shots/<lang>/01..06.png`,再跑
  `/usr/bin/python3 tools/gen_store_shots.py [locale...]` 合成 2560×1600 商店图
- 旧版材料(`metadata/`、`screenshots/`、`screenshots/raw-*`)保留作 1.3 存档
