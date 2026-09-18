# Release — KinetMinutes 1.0.0 (build 1)

> 全部上架材料。目标:Mac App Store,Productivity 分类,4+ 分级,免费+IAP。
> Bundle ID `com.kinet.minutes.app` · Team M92UKS6NA2 · macOS 14+ · Apple Silicon

## 材料清单

| 项 | 路径 | 状态 |
|---|---|---|
| ASC 元数据(四语 name/subtitle/promo/description/keywords/whatsnew) | `metadata/{en,ja,zh-Hans,zh-Hant}/` | ✓ 字符数全部达标 |
| 截图(四语 ×1,2560×1600 sRGB) | `screenshots/{lang}/01-library.png` | ✓ 合法 16:10 档 |
| Review Notes(60-90 秒复测路径 + 分级问卷) | `review-notes.md` | ✓ |
| 隐私政策(四语,GitHub Pages 已上线) | `website/privacy.html` → https://phinn.github.io/KinetMinutes/privacy.html | ✓ 200 |
| 营销页 | `website/index.html` → https://phinn.github.io/KinetMinutes/ | ✓ |
| PrivacyInfo.xcprivacy | `Resources/PrivacyInfo.xcprivacy` | ✓ 打包进 bundle root |

## ASC App 信息

| 字段 | 值 |
|---|---|
| Name(四语) | KinetMinutes(12 字符,品牌不译) |
| Subtitle | en "Local AI notes, zero upload"(27)· zh "本地AI会议纪要,零上传" |
| Primary Category | Productivity(`public.app-category.productivity`) |
| 分级 | 4+(问卷答案见 review-notes.md) |
| 出口合规 | ITSAppUsesNonExemptEncryption=false |
| 价格 | 免费 + IAP Pro(1.0 首发免 IAP,免费档月 5 次;IAP 随 1.1 上) |
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

# 3. 上传
xcrun altool --store-type onboarded \
  --upload-package /tmp/km_export/KinetMinutes.pkg \
  --api-key-id WGY2HCFK9K --api-issuer d4da77ce-6781-4aef-acdd-c7480df892d5
```

## 注意
- LocalLLMKit 是本地包依赖(`../LocalLLMKit`),archive 前确认路径存在
- FTS5 migrate 需幂等;demo 会议数据随首启种子(见 review-notes「demo meeting」)
- 截图重摄:`release/screenshots/shoot_all.sh`(需 /tmp/KinetMinutes.app Debug 包 + demo 数据)
