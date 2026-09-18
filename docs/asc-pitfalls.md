# KinetMinutes ASC 送审踩坑(2026-09-19 首提直达 WAITING_FOR_REVIEW)

> 从空目录到 App Store Connect WAITING_FOR_REVIEW 一次跑通。参照 KinetMagicDisk 链路,但把 KMD 当年 4 次提交失败(kmd3-kmd6)的根因一次性挖穿。

## 全链路(全部可复现)

| 步骤 | 动作 | 关键点 |
|---|---|---|
| 1 | Bundle ID 注册 | ASC API `POST /v1/bundleIds` 可用(需 `platform` 属性,值随便填最终变 UNIVERSAL) |
| 2 | App record 创建 | **API 无 CREATE 权限**;走 Safari 免登录态网页 `POST /iris/v1/apps`(asc_create.applescript,`${new-*-id}` 占位符在 /apps/new 页面上下文) |
| 3 | 工程 | xcodegen + 本地包依赖 `../LocalLLMKit`(WhisperKit 转写 + Ollama LLM) |
| 4 | Archive → pkg | `xcodebuild archive` → `-exportArchive -allowProvisioningUpdates`;pkg = 21MB |
| 5 | altool 上传 | 参数是 `--api-key`(不是 --api-key-id,那是 notarytool 的) |
| 6 | 元数据/截图/分级/定价/build 关联/提审 | `build/ascend_km.rb` |

## 提交被拒的隐藏缺项(STATE_ERROR.ENTITY_STATE_INVALID)

「添加以供审核」API/网页都点了没反应、item add 报 `appStoreVersions ... is not in valid state. This resource cannot be reviewed, please check associated errors` 时,**associatedErrors 才是真相**。用网页上下文 fetch iris 接口(带 cookie + X-Csrf-Itc)能看到完整缺项列表:

```js
fetch("/iris/v1/reviewSubmissionItems", {method:"POST", credentials:"include",
  headers:{"X-Csrf-Itc": (document.cookie.match(/itctx=([^;]+)/)||[])[1]},
  body: JSON.stringify({data:{type:"reviewSubmissionItems", relationships:{
    reviewSubmission:{data:{type:"reviewSubmissions", id: RSID}},
    appStoreVersion:{data:{type:"appStoreVersions", id: VID}}}}})})
```

返回 409 的 `meta.associatedErrors` 直接列出所有缺项。本次挖出两个:

### ① App 级 contentRightsDeclaration(版权声明)
- `POST appStoreVersion` 不带它 → version 永远 not reviewable
- API 位置在 **apps 级**(不是 appInfos):`PATCH /v1/apps/{id}` attributes.contentRightsDeclaration
- 枚举值:`DOES_NOT_USE_THIRD_PARTY_CONTENT` / `USES_THIRD_PARTY_CONTENT`(不是版权文本!)
- 版本级 copyright(版权文本)是另一个字段:`PATCH /v1/appStoreVersions/{id}` attributes.copyright

### ② App Privacy 问卷未发布
- API 全死(appDataUsages 404 等),必须网页填
- 流程:App 隐私 → 开始 → 选「否,我们不会从此 App 中收集数据」→ 保存 → **发布**(确认弹窗)
- 「保存」不够,必须再点「发布」才生效

### ③ 年龄分级问卷字段名全变(fastlane 文档过时)
新版字段:boolean 型是 `gambling/contests/messagingAndChat/socialMedia/unrestrictedWebAccess/userGeneratedContent/healthOrWellnessTopics/lootBox/advertising/ageAssurance/parentalControls`;枚举 "NONE" 型是 `alcoholTobaccoOrDrugUseOrReferences/gamblingSimulated/gunsOrOtherWeapons/medicalOrTreatmentInformation/profanityOrCrudeHumor/sexualContent*/horrorOrFearThemes/matureOrSuggestiveThemes/violence*`;**同时给 `ageRatingOverride` 和 `ageRatingOverrideV2` 会报互斥错**,只给 V2。缺 required 字段会逐个报错,要按报错补(最后缺 advertising/ageAssurance)。

## 其它踩坑

- **build 关联**:`api.patch_app_store_version_with_build` 才真正写入;直接 patch appStoreVersions relationships.builds 报 "unknown relationship"(看着成功实际没挂,提交时才炸)
- **whatsNew 时序**:version 没 build 时 `whatsNew` 属性不可编辑("cannot be edited at this time"),build 关联后再补
- **reviewSubmission 并发上限 5**:废 submission 无法 cancel/delete,直接往最新的 add item 提交即可
- **altool 认证**:`--api-key WGY2HCFK9K --api-issuer ...`(key 文件在 ~/.appstoreconnect/private_keys/AuthKey_*.p8)

## 复跑

```bash
# 1. 建 record(网页上下文,Safari 开着 /apps/new)
osascript build/asc_create.applescript
# 2. archive+export+altool(见 release/README.md)
# 3. 全链
GEM_HOME=/opt/homebrew/Cellar/fastlane/2.239.0/libexec GEM_PATH=同 ruby build/ascend_km.rb
```
