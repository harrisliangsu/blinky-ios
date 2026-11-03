import XCTest

final class ScreenshotUITests: XCTestCase {
    func testEnglishScreens() {
        capture(language: "en", prefix: "en")
    }

    func testChineseScreens() {
        capture(language: "zh-Hans", prefix: "zh-Hans")
    }

    /// The review set for this pass: usage tiers, one expanded card, one
    /// exhausted card, and the token daily page. The full matrix is what made
    /// the screenshot job die mid-capture.
    private func capture(language: String, prefix: String) {
        for appearance in ["light", "dark"] {
            let name = "\(prefix)-\(appearance)"
            shot(
                language: language,
                appearance: appearance,
                interfaceStyle: "liquidGlass",
                screen: "usage",
                name: "\(name)-liquidGlass-usage"
            )
            if language == "zh-Hans", appearance == "light" {
                shot(
                    language: language,
                    appearance: appearance,
                    interfaceStyle: "classic",
                    screen: "usage",
                    name: "\(name)-classic-usage"
                )
                shot(
                    language: language,
                    appearance: appearance,
                    interfaceStyle: "screenTime",
                    screen: "usage",
                    name: "\(name)-screenTime-usage"
                )
            }
            if appearance == "light" {
                shot(
                    language: language,
                    appearance: appearance,
                    interfaceStyle: "liquidGlass",
                    screen: "usageExpanded",
                    name: "\(name)-usage-expanded"
                )
                shot(
                    language: language,
                    appearance: appearance,
                    interfaceStyle: "liquidGlass",
                    screen: "usageDanger",
                    name: "\(name)-usage-danger"
                )
                shot(
                    language: language,
                    appearance: appearance,
                    interfaceStyle: "liquidGlass",
                    screen: "tokenActivity",
                    name: "\(name)-token-liquidGlass"
                )
            }
        }
    }

    private func shot(
        language: String,
        appearance: String,
        interfaceStyle: String = "liquidGlass",
        screen: String,
        name: String
    ) {
        let app = XCUIApplication()
        app.launchArguments = [
            "-BlinkyScreenshotFixture",
            "-BlinkyScreenshotLanguage", language,
            "-BlinkyScreenshotAppearance", appearance,
            "-BlinkyScreenshotInterfaceStyle", interfaceStyle,
            "-BlinkyScreenshotScreen", screen,
        ]
        app.launch()

        switch screen {
        case "addAccount":
            let connect = app.staticTexts["Connect an account"].exists
                || app.staticTexts["连接账号"].waitForExistence(timeout: 8)
                || app.staticTexts["Connect an account"].waitForExistence(timeout: 8)
            XCTAssertTrue(connect)
            let zhipu = app.descendants(matching: .any)["provider-zhipu"]
            var swipes = 0
            while !zhipu.isHittable && swipes < 14 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(zhipu.waitForExistence(timeout: 5))
            app.swipeUp(velocity: .slow)
        case "deviceCode":
            XCTAssertTrue(app.staticTexts["K3M9-PQ2R"].waitForExistence(timeout: 15))
        case "settings":
            let appearanceRow = app.staticTexts["Appearance"]
            let chineseAppearanceRow = app.staticTexts["外观"]
            XCTAssertTrue(appearanceRow.waitForExistence(timeout: 12) || chineseAppearanceRow.waitForExistence(timeout: 4))
            if appearanceRow.exists {
                appearanceRow.tap()
            } else {
                chineseAppearanceRow.tap()
            }
            let label = app.staticTexts["Interface appearance"]
            let chinese = app.staticTexts["界面外观"]
            XCTAssertTrue(label.waitForExistence(timeout: 8) || chinese.waitForExistence(timeout: 4))
            let style = app.staticTexts["Interface style"]
            let chineseStyle = app.staticTexts["界面风格"]
            XCTAssertTrue(style.exists || chineseStyle.waitForExistence(timeout: 4))
            let selected = selectedInterfaceStyleTitle(language: language, interfaceStyle: interfaceStyle)
            XCTAssertTrue(app.staticTexts[selected].waitForExistence(timeout: 4))
            let bars = app.staticTexts["Progress bars"]
            let chineseBars = app.staticTexts["进度条"]
            XCTAssertTrue(bars.exists || chineseBars.exists)
        case "forecasts":
            let forecastsRow = app.staticTexts["Forecasts"]
            let chineseForecastsRow = app.staticTexts["预测"]
            XCTAssertTrue(forecastsRow.waitForExistence(timeout: 12) || chineseForecastsRow.waitForExistence(timeout: 4))
            if forecastsRow.exists {
                forecastsRow.tap()
            } else {
                chineseForecastsRow.tap()
            }
            let estimate = language == "zh-Hans" ? "显示预估" : "Show the estimate"
            let predicted = language == "zh-Hans" ? "显示预测重置" : "Show predicted reset"
            XCTAssertTrue(app.staticTexts[estimate].waitForExistence(timeout: 8))
            let predictedSwitch = app.switches["forecasts-show-predicted"]
            var swipes = 0
            while !predictedSwitch.exists && swipes < 4 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(predictedSwitch.waitForExistence(timeout: 4))
            XCTAssertTrue(app.staticTexts[predicted].exists)
            XCTAssertTrue(app.switches["forecasts-show-estimate"].exists)
        case "settingsRoot":
            let appearanceRow = app.staticTexts["Appearance"]
            let chineseAppearanceRow = app.staticTexts["外观"]
            XCTAssertTrue(appearanceRow.waitForExistence(timeout: 12) || chineseAppearanceRow.waitForExistence(timeout: 4))
            let token = app.staticTexts["Token activity"]
            let chineseToken = app.staticTexts["Token 活动"]
            XCTAssertTrue(token.exists || chineseToken.waitForExistence(timeout: 4))
            let about = app.staticTexts["About"]
            let chineseAbout = app.staticTexts["关于"]
            var swipes = 0
            while !about.exists && !chineseAbout.exists && swipes < 4 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(about.exists || chineseAbout.exists)
            swipes = 0
            while !appearanceRow.exists && !chineseAppearanceRow.exists && swipes < 4 {
                app.swipeDown()
                swipes += 1
            }
        case "about":
            openIdentifier(app, "settings-module-about")
            XCTAssertTrue(app.descendants(matching: .any)["about-check-updates"].waitForExistence(timeout: 12))
        case "notifications":
            openSettingsModule(app, english: "Notifications", chinese: "通知")
            let allow = app.staticTexts["Allow Notifications"]
            let chineseAllow = app.staticTexts["允许通知"]
            let unexpected = app.staticTexts["Unexpected or early resets"]
            let chineseUnexpected = app.staticTexts["意外或提前的重置"]
            XCTAssertTrue(
                allow.waitForExistence(timeout: 8)
                    || chineseAllow.waitForExistence(timeout: 4)
                    || unexpected.exists
                    || chineseUnexpected.exists
            )
        case "tokenActivity":
            openTokenActivity(app)
            XCTAssertTrue(app.descendants(matching: .any)["token-activity-daily"].waitForExistence(timeout: 12))
            XCTAssertTrue(app.descendants(matching: .any)["token-performance"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.staticTexts["gpt-5.4"].waitForExistence(timeout: 4))
        case "tokenActivityWeekly":
            openTokenActivity(app)
            XCTAssertTrue(app.descendants(matching: .any)["token-activity-weekly"].waitForExistence(timeout: 12))
        case "tokenActivityCumulative":
            openTokenActivity(app)
            XCTAssertTrue(app.descendants(matching: .any)["token-activity-cumulative"].waitForExistence(timeout: 12))
        case "tokenActivityEmpty":
            openTokenActivity(app)
            XCTAssertTrue(app.descendants(matching: .any)["token-activity-empty"].waitForExistence(timeout: 12))
            let empty = app.staticTexts["No local transcripts"]
            let chineseEmpty = app.staticTexts["没有本地记录"]
            XCTAssertTrue(empty.exists || chineseEmpty.exists)
        case "tokenActivityExpanded":
            openTokenActivity(app)
            let missingCache = app.staticTexts["—"]
            var swipes = 0
            while !missingCache.isHittable && swipes < 5 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(missingCache.waitForExistence(timeout: 8))
        case "usageExpanded":
            let disclosure = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@", "forecasts-disclosure"))
                .element(boundBy: 0)
            XCTAssertTrue(disclosure.waitForExistence(timeout: 12))
            disclosure.tap()
            let detail = language == "zh-Hans" ? "按当前速度" : "At the current pace"
            XCTAssertTrue(app.staticTexts[detail].waitForExistence(timeout: 4)
                || app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", language == "zh-Hans" ? "用尽" : "pace")).firstMatch.waitForExistence(timeout: 4))
        case "usageDanger":
            let exhausted = language == "zh-Hans" ? "剩余 0%" : "0% left"
            var swipes = 0
            while !app.staticTexts[exhausted].isHittable && swipes < 4 {
                app.swipeUp()
                swipes += 1
            }
            XCTAssertTrue(app.staticTexts[exhausted].waitForExistence(timeout: 8))
        case "reorder":
            let done = app.buttons["Done"]
            let chineseDone = app.buttons["完成"]
            XCTAssertTrue(done.waitForExistence(timeout: 12) || chineseDone.waitForExistence(timeout: 4))
        default:
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15))
            XCTAssertTrue(
                app.descendants(matching: .any)["usage-style-\(interfaceStyle)"].waitForExistence(timeout: 8)
            )
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    private func openIdentifier(_ app: XCUIApplication, _ identifier: String) {
        let row = app.descendants(matching: .any)[identifier]
        var swipes = 0
        while !row.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
    }

    private func openTokenActivity(_ app: XCUIApplication) {
        openSettingsModule(app, english: "Token activity", chinese: "Token 活动")
    }

    private func openSettingsModule(_ app: XCUIApplication, english: String, chinese: String) {
        let row = app.staticTexts[english]
        let chineseRow = app.staticTexts[chinese]
        var swipes = 0
        while !row.exists && !chineseRow.exists && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.waitForExistence(timeout: 8) || chineseRow.waitForExistence(timeout: 4))
        if row.exists {
            row.tap()
        } else {
            chineseRow.tap()
        }
    }

    /// The appearance picker shows only the selected style until it is opened.
    private func selectedInterfaceStyleTitle(language: String, interfaceStyle: String) -> String {
        let chinese = language == "zh-Hans"
        switch interfaceStyle {
        case "classic":
            return chinese ? "经典" : "Classic"
        case "screenTime":
            return chinese ? "屏幕使用时间" : "Screen Time"
        default:
            return chinese ? "液态玻璃" : "Liquid Glass"
        }
    }
}
