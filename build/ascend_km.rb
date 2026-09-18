#!/usr/bin/env ruby
# frozen_string_literal: true
# KinetMinutes — ASC 最后一公里(照 KinetMagicDisk ascend_kmd.rb 全部实跑路径)
# 4语元数据 → 分类/版权/隐私URL → Review Info(notes) → 截图 → 年龄分级 → 定价 → build 关联 → 提审
# 终态:AppStoreVersion state = WAITING_FOR_REVIEW
# 用法: GEM_HOME=/opt/homebrew/Cellar/fastlane/2.239.0/libexec GEM_PATH=同 ruby build/ascend_km.rb [--verbose]
require "spaceship"
require "openssl"
require "json"

KEY_ID  = "WGY2HCFK9K"
ISSUER  = "d4da77ce-6781-4aef-acdd-c7480df892d5"
BUNDLE  = "com.kinet.minutes.app"
VERBOSE = ARGV.include?("--verbose")
ROOT    = File.expand_path("..", __dir__)
META    = File.join(ROOT, "release/metadata")
SHOTS   = File.join(ROOT, "release/screenshots")
PRIVACY_URL = "https://phinn.github.io/KinetMinutes/privacy.html"
MARKETING_URL = "https://phinn.github.io/KinetMinutes/"
SUPPORT_URL = "https://phinn.github.io/KinetMinutes/"
LOCALES = { "en" => "en-US", "ja" => "ja", "zh-Hans" => "zh-Hans", "zh-Hant" => "zh-Hant" }
CATEGORY = "PRODUCTIVITY"

def v(msg)
  puts(msg) if VERBOSE
end

ec_key = OpenSSL::PKey::EC.new(File.read(File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{KEY_ID}.p8")))
Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.new(key_id: KEY_ID, issuer_id: ISSUER, key: ec_key)
client = Spaceship::ConnectAPI.client
tclient = Spaceship::ConnectAPI::Tunes::Client.new(token: Spaceship::ConnectAPI.token)

# ---------- 0. app record ----------
app = Spaceship::ConnectAPI::App.all.find { |a| a.bundleId == BUNDLE }
abort("❌ 找不到 app record #{BUNDLE}") unless app
puts "① app #{app.id} #{app.name}"

app_info = nil
app_info_id = nil
8.times do |i|
  app_info = (app.fetch_edit_app_info rescue nil)
  app_info_id = app_info&.id
  break if app_info_id
  puts "  app_info 未就绪,重试 #{i+1}/8…"
  sleep 10
end
abort("❌ app_info 缺失") unless app_info_id

# ---------- 1. 取/建 1.0 版本 ----------
version = app.get_edit_app_store_version rescue nil
unless version
  version = client.get_app_store_versions(app_id: app.id, filter: { versionString: "1.0", appStoreState: "READY_FOR_SALE,PREPARE_FOR_SUBMISSION,IN_REVIEW,WAITING_FOR_REVIEW,DEVELOPER_REJECTED,REJECTED,METADATA_REJECTED" }).first
end
unless version
  version = client.post_app_store_version(app_id: app.id, attributes: { versionString: "1.0", platform: "MAC_OS" })
end
version_id = version.id
puts "② version 1.0 (#{version_id})"

# ---------- 2. 版本级本地化 ----------
LOCALES.each do |dir, locale|
  d = File.join(META, dir)
  attrs = {
    description: File.read(File.join(d, "description.txt")).strip,
    keywords: File.read(File.join(d, "keywords.txt")).strip,
    promotionalText: File.read(File.join(d, "promo.txt")).strip,
    supportUrl: SUPPORT_URL,
    marketingUrl: MARKETING_URL
  }
  loc = client.get_app_store_version_localizations(app_store_version_id: version_id).find { |l| l.locale == locale }
  if loc
    begin
      client.patch_app_store_version_localization(app_store_version_localization_id: loc.id, attributes: attrs)
    rescue Spaceship::UnexpectedResponse => e
      v("  patch #{locale} 失败,去 whatsNew 重试: #{e.message[0,80]}")
      client.patch_app_store_version_localization(app_store_version_localization_id: loc.id, attributes: attrs.reject { |k, _| k == :whatsNew })
    end
  else
    client.post_app_store_version_localization(app_store_version_id: version_id, attributes: attrs.merge(locale: locale))
    v("  created #{locale}")
  end
  puts "③ #{locale} 版本级元数据 ✓"
end

# ---------- 3. appInfo 级 name/subtitle/privacyURL ----------
LOCALES.each do |dir, locale|
  d = File.join(META, dir)
  ail = app_info.get_app_info_localizations.find { |l| l.locale == locale }
  attrs = {
    name: File.read(File.join(d, "name.txt")).strip,
    subtitle: File.read(File.join(d, "subtitle.txt")).strip,
    privacyPolicyUrl: PRIVACY_URL
  }
  if ail
    client.patch_app_info_localization(app_info_localization_id: ail.id, attributes: attrs)
  else
    client.post_app_info_localization(app_info_id: app_info_id, attributes: attrs.merge(locale: locale))
  end
  puts "④ appInfo #{locale} name/subtitle/privacyURL ✓"
end

begin
  client.patch_app_info_categories(app_info_id: app_info_id, category_id_map: { primary_category_id: CATEGORY })
  puts "⑤ 分类 #{CATEGORY} ✓"
rescue StandardError => e
  v("  分类: #{e.message[0,120]}")
  puts "⑤ 分类失败(非致命)"
end

begin
  client.patch_app_info(app_info_id: app_info_id, attributes: { contentRightsDeclaration: "Copyright © 2026 Kinet. All rights reserved." })
  puts "⑤b 版权声明 ✓"
rescue StandardError => e
  v("  版权: #{e.message[0,120]}")
end

# ---------- 4. 年龄分级(KMD 同款字段)----------
begin
  api = Spaceship::ConnectAPI::Tunes::Client.new(token: Spaceship::ConnectAPI.token)
  raw = api.get_age_rating_declaration(app_info_id: app_info_id)
  decl_id = raw.body&.dig("data", "id")
  attrs = {
    alchoholTobaccoOrDrugUseOrReferences: "NONE",
    gamblingSimulated: "NONE",
    gambling: false,
    gamblingContests: false,
    gamblingRealMoney: false,
    horrorOrFearThemes: "NONE",
    matureOrSuggestiveThemes: "NONE",
    medicalOrTreatmentInformation: "NONE",
    profanityOrCrudeHumor: "NONE",
    sexualContentGraphicAndNudity: "NONE",
    sexualContentOrNudity: "NONE",
    violenceCartoonOrFantasy: "NONE",
    violenceRealistic: "NONE",
    violenceRealisticProlongedGraphicOrSadistic: "NONE",
    kidsAgeBand: nil,
    ageRatingOverrideV2: "NONE"
  }
  if decl_id
    api.patch_age_rating_declaration(age_rating_declaration_id: decl_id, attributes: attrs)
  else
    Spaceship::ConnectAPI.client.post("appInfos/#{app_info_id}/ageRatingDeclaration", { data: { type: "ageRatingDeclarations", attributes: attrs } })
  end
  puts "⑥ 年龄分级 4+ ✓"
rescue StandardError => e
  v("  年龄分级: #{e.message[0,200]}")
  puts "⑥ 年龄分级 API 失败(非致命,网页可补)"
end

# ---------- 5. App Review Info(含 review notes)----------
review_detail = Spaceship::ConnectAPI::AppStoreReviewDetail.all(app_store_version_id: version_id) rescue []
review_detail = review_detail.is_a?(Array) ? review_detail.first : review_detail
notes = File.read(File.join(ROOT, "release/review-notes.md"))
rd_attrs = {
  contactFirstName: "Phinn",
  contactLastName: "Shen",
  contactPhone: "+86 138 0000 0000",
  contactEmail: "phinn@outlook.com",
  demoAccountName: nil,
  demoAccountPassword: nil,
  notes: notes
}
if review_detail
  client.patch_app_store_review_detail(app_store_review_detail_id: review_detail.id, attributes: rd_attrs)
else
  begin
    client.post_app_store_review_detail(app_store_version_id: version_id, attributes: rd_attrs)
  rescue StandardError => e
    v("  post review detail: #{e.message[0,80]} → 改为查已有再 patch")
    rd = client.get_app_store_review_detail(app_store_version_id: version_id).first
    client.patch_app_store_review_detail(app_store_review_detail_id: rd.id, attributes: rd_attrs)
  end
end
puts "⑦ App Review Info ✓"

# ---------- 6. 截图(四语,APP_DESKTOP 2560x1600)----------
LOCALES.each do |dir, locale|
  loc = version.get_app_store_version_localizations.find { |l| l.locale == locale }
  abort("❌ #{locale} localization 缺失") unless loc
  sets = loc.get_app_screenshot_sets rescue []
  set = sets.find { |s| s.screenshot_display_type == "APP_DESKTOP" }
  unless set
    raw_set = client.post_app_screenshot_set(
      app_store_version_localization_id: loc.id,
      attributes: { screenshotDisplayType: "APP_DESKTOP" }
    ).first
    set = Spaceship::ConnectAPI::AppScreenshotSet.new(raw_set.id, {})
  end
  existing = set.app_screenshots || []
  existing.each { |s| client.delete_app_screenshot(app_screenshot_id: s.id) }
  path = File.join(SHOTS, dir, "01-library.png")
  Spaceship::ConnectAPI::AppScreenshot.create(client: client, app_screenshot_set_id: set.id, path: path, wait_for_processing: true)
  puts "⑧ 截图 #{locale} ✓"
end

# ---------- 7. 定价(免费 tier 0,${price1} 内联)----------
begin
  existing = tclient.get("v1/appPriceSchedules/#{app.id}", nil)
  prices_rel = existing.body.dig("data", "relationships", "manualPrices", "data") || []
  if prices_rel.any?
    puts "⑨ 定价已存在,跳过"
  else
    pp = tclient.get("v1/apps/#{app.id}/appPricePoints?filter%5Bterritory%5D=USA&limit=10", nil)
    tier0 = pp.body["data"].find { |p| p.dig("attributes", "customerPrice") == "0.0" }
    abort("❌ 找不到 USA tier0 pricePoint") unless tier0
    body = {
      data: {
        type: "appPriceSchedules",
        attributes: {},
        relationships: {
          app: { data: { type: "apps", id: app.id } },
          baseTerritory: { data: { type: "territories", id: "USA" } },
          manualPrices: { data: [{ type: "appPrices", id: "${price1}" }] }
        }
      },
      included: [
        {
          type: "appPrices",
          id: "${price1}",
          attributes: { startDate: nil, endDate: nil, manual: true },
          relationships: {
            appPricePoint: { data: { type: "appPricePoints", id: tier0["id"] } },
            territory: { data: { type: "territories", id: "USA" } }
          }
        }
      ]
    }
    tclient.post("v1/appPriceSchedules", body)
    puts "⑨ 定价创建(tier 0 免费, USA base)✓"
  end
rescue StandardError => e
  v("  定价: #{e.message[0,150]}")
end

# ---------- 8. build 关联(patch_app_store_version_with_build 才真正写入;patch relationships 'builds' 会报 unknown relationship)----------
build = Spaceship::ConnectAPI::Build.all(app_id: app.id, version: "1.0", sort: "-uploadedDate").first
abort("❌ 无可用 build —— 先 upload") unless build
puts "⑩ build #{build.version} id=#{build.id} state=#{build.processing_state}"
api = Spaceship::ConnectAPI::Tunes::Client.new(token: Spaceship::ConnectAPI.token)
api.patch_app_store_version_with_build(app_store_version_id: version_id, build_id: build.id)
puts "  build 已关联到 version"

# build 关联后补 whatsNew
LOCALES.each do |dir, loc_|
  begin
    loc = client.get_app_store_version_localizations(app_store_version_id: version_id).find { |l| l.locale == loc_ }
    client.patch_app_store_version_localization(app_store_version_localization_id: loc.id, attributes: { whatsNew: File.read(File.join(META, dir, "whatsnew.txt")).strip })
  rescue StandardError => e
    v("  whatsNew #{dir}: #{e.message[0,80]}")
  end
end
puts "⑩b whatsNew 四语 ✓"

# ---------- 9. reviewSubmission 提交 ----------
rs = app.get_in_progress_review_submission(platform: "MAC_OS") rescue nil
if rs
  review_submission_id = rs.id
  puts "⑪ 复用 reviewSubmission #{review_submission_id}"
else
  rs = client.post_review_submission(app_id: app.id, platform: "MAC_OS")
  review_submission_id = rs.body["data"]["id"]
  puts "⑪ 新建 reviewSubmission #{review_submission_id}"
end
begin
  client.post_review_submission_item(review_submission_id: review_submission_id, app_store_version_id: version_id)
rescue StandardError => e
  v("  item add: #{e.message[0,80]}(可能已存在)")
end
begin
  api.patch_review_submission(review_submission_id: review_submission_id, attributes: { submitted: true })
rescue StandardError => e
  v("  submit: #{e.message[0,120]}")
end

# ---------- 10. 终态查询 ----------
sleep 8
raw = api.get_app_store_version(app_store_version_id: version_id)
state = raw.body&.dig("data", "attributes", "appStoreState")
rs_state = begin
  api.get_review_submission(review_submission_id: review_submission_id).body&.dig("data", "attributes", "state")
rescue StandardError
  nil
end
puts ""
puts "================ ASC 终态 ================"
puts JSON.pretty_generate({ appStoreState: state, reviewSubmissionState: rs_state, version: raw.body&.dig("data", "attributes", "versionString") })
puts "=========================================="
state == "WAITING_FOR_REVIEW" ? (puts "🎉 WAITING_FOR_REVIEW 达成") : (puts "⚠️ 终态非 WAITING_FOR_REVIEW,查上面 JSON")
