import XCTest

/// Drives the real app with touches: opens a notebook, writes, erases, selects and undoes.
/// Screenshots go to the test report, and to $INKPAD_SHOTS when that is set
/// (pass it to xcodebuild as TEST_RUNNER_INKPAD_SHOTS).
final class EditorUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = true
        app.launchArguments = ["-demo", "-resetPrefs", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["INKPAD_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    func drag(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, hold: TimeInterval = 0) {
        at(x0, y0).press(forDuration: 0.05, thenDragTo: at(x1, y1), withVelocity: .slow, thenHoldForDuration: hold)
    }

    func open(_ name: String) {
        let cover = app.buttons["open-" + name]
        XCTAssertTrue(cover.waitForExistence(timeout: 10))
        cover.tap()
        XCTAssertTrue(app.buttons["橡皮擦"].waitForExistence(timeout: 10))
        sleep(1)
    }

    /// Close a popover by tapping the header, which belongs to nothing underneath.
    func closePopover() {
        at(0.5, 0.985).tap()
        usleep(400_000)
    }

    func testWritingAndEditing() {
        XCTAssertTrue(app.buttons["open-课堂笔记"].waitForExistence(timeout: 10))
        shot("01-library")
        open("课堂笔记")
        shot("02-editor")

        // Pen (already in hand): three strokes, the last one held at its end so that it snaps to a straight line.
        drag(0.25, 0.62, 0.55, 0.66)
        drag(0.25, 0.68, 0.60, 0.64)
        drag(0.30, 0.74, 0.70, 0.76, hold: 1.0)
        shot("03-pen")
        app.buttons["笔设置"].tap()
        sleep(1)
        shot("03b-pen-panel")
        closePopover()

        // Marker over the first of them.
        app.buttons["荧光笔"].tap()
        drag(0.24, 0.64, 0.56, 0.64)
        // A rectangle.
        app.buttons["形状"].tap()
        app.buttons["矩形"].tap()
        drag(0.62, 0.60, 0.80, 0.70)
        shot("04-marker-shape")

        // The eraser cuts the second stroke in two.
        app.buttons["橡皮擦"].tap()
        drag(0.42, 0.60, 0.42, 0.72)
        shot("05-erased")

        // A rectangular lasso around the rectangle selects it; the bar duplicates it.
        app.buttons["套索"].tap()
        app.buttons["套索设置"].tap()
        XCTAssertTrue(app.buttons["长方形"].waitForExistence(timeout: 3))
        app.buttons["长方形"].tap()
        shot("05b-lasso-panel")
        closePopover()
        drag(0.60, 0.585, 0.84, 0.72)
        XCTAssertTrue(app.buttons["复制"].waitForExistence(timeout: 3))
        shot("06-selected")
        app.buttons["复制"].tap()
        // Drag the copy away by its middle.
        drag(0.73, 0.67, 0.55, 0.82)
        shot("07-moved")

        // Undo twice: the move, then the copy.
        app.buttons["撤销"].tap()
        app.buttons["撤销"].tap()
        shot("08-undone")

        // Pages panel, and a new page.
        app.buttons["页面、大纲与书签"].tap()
        app.buttons["添加页面"].firstMatch.tap()
        XCTAssertTrue(app.buttons["当前模板"].waitForExistence(timeout: 3))
        shot("09a-add-panel")
        app.buttons["当前模板"].tap()
        sleep(1)
        shot("09-pages")
        app.buttons["页面与设置"].tap()
        sleep(1)
        shot("09b-page-panel")
        closePopover()

        // Pinch out and write while zoomed in.
        app.buttons["笔"].tap()
        app.buttons["页面、大纲与书签"].tap()
        app.scrollViews["canvas"].pinch(withScale: 3, velocity: 2)
        sleep(1)
        drag(0.3, 0.5, 0.7, 0.55)
        sleep(1)
        shot("10-zoomed")

        app.buttons["文稿库"].tap()
        XCTAssertTrue(app.buttons["open-课堂笔记"].waitForExistence(timeout: 5))
        shot("11-back")
    }

    func testTextBoardAndPDF() {
        // A text box and a sticky note.
        open("草稿")
        app.buttons["文本"].tap()
        at(0.2, 0.3).tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        app.textViews.firstMatch.typeText("Hello Inkpad")
        app.buttons["完成"].tap()
        app.buttons["便签"].tap()
        at(0.5, 0.45).tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 5))
        app.textViews.firstMatch.typeText("Sticky")
        app.buttons["完成"].tap()
        app.buttons["胶带"].tap()
        drag(0.18, 0.31, 0.5, 0.31)
        sleep(1)
        shot("30-text")
        app.buttons["文稿库"].tap()

        // Writing on a PDF and rubbing part of it out again.
        open("讲义")
        app.buttons["笔"].tap()
        drag(0.2, 0.25, 0.8, 0.5)
        drag(0.2, 0.5, 0.8, 0.25)
        app.buttons["橡皮擦"].tap()
        drag(0.5, 0.2, 0.5, 0.6)
        sleep(1)
        shot("31-pdf")
        app.buttons["文稿库"].tap()

        // A whiteboard: no edges, so writing far from the start has to work too.
        XCTAssertTrue(app.buttons["新建"].waitForExistence(timeout: 10))
        app.buttons["新建"].tap()
        app.buttons["白板"].tap()
        XCTAssertTrue(app.buttons["创建白板"].waitForExistence(timeout: 5))
        shot("32a-new-board")
        app.buttons["创建白板"].tap()
        XCTAssertTrue(app.buttons["笔"].waitForExistence(timeout: 10))
        app.buttons["笔"].tap()
        drag(0.3, 0.4, 0.7, 0.5)
        drag(0.1, 0.9, 0.9, 0.95)
        app.buttons["形状"].tap()
        app.buttons["椭圆"].tap()
        drag(0.2, 0.55, 0.5, 0.75)
        sleep(1)
        shot("32-board")
        app.buttons["文稿库"].tap()
        XCTAssertTrue(app.buttons["open-未命名白板"].waitForExistence(timeout: 10))
        shot("33-library")
    }

    func testNewNotebookAndSettings() {
        XCTAssertTrue(app.buttons["新建"].waitForExistence(timeout: 10))
        app.buttons["新建"].tap()
        sleep(1)
        shot("19-new-menu")
        app.buttons["笔记本"].tap()
        XCTAssertTrue(app.buttons["创建笔记本"].waitForExistence(timeout: 5))
        shot("20-new-notebook")
        app.buttons["创建笔记本"].tap()
        XCTAssertTrue(app.buttons["橡皮擦"].waitForExistence(timeout: 10))
        drag(0.3, 0.4, 0.6, 0.5)
        shot("21-new-editor")
        app.buttons["文稿库"].tap()
        XCTAssertTrue(app.buttons["Google Drive 同步"].waitForExistence(timeout: 5))
        app.buttons["Google Drive 同步"].tap()
        sleep(1)
        shot("22a-cloud")
        closePopover()
        // A folder opens on a double tap; the first tap only marks it.
        app.buttons["open-课程"].tap()
        sleep(1)
        XCTAssertTrue(app.buttons["open-课堂笔记"].exists, "one tap does not open it")
        app.buttons["open-课程"].doubleTap()
        sleep(1)
        shot("22b-folder")
        app.buttons["设置"].tap()
        sleep(1)
        shot("22-settings")
    }

    /// Runs last (by name): it changes settings the other tests rely on.
    func testZSideBySidePaging() {
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 10))
        app.buttons["设置"].tap()
        let finger = app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "用手指书写")).firstMatch
        XCTAssertTrue(finger.waitForExistence(timeout: 5))
        finger.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let paging = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "翻页方向")).firstMatch
        for _ in 0..<4 where !(paging.exists && paging.isHittable) { at(0.5, 0.6).press(forDuration: 0.05, thenDragTo: at(0.5, 0.45)) }
        paging.tap()
        XCTAssertTrue(app.buttons["左右"].waitForExistence(timeout: 3))
        app.buttons["左右"].tap()
        sleep(1)
        shot("40-settings-writing")
        let storage = app.buttons["管理储存空间…"]
        for _ in 0..<6 where !(storage.exists && storage.isHittable) { at(0.5, 0.6).press(forDuration: 0.05, thenDragTo: at(0.5, 0.4)) }
        storage.tap()
        sleep(1)
        shot("41-storage")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 3))
        app.buttons["完成"].tap()

        open("课堂笔记")
        shot("42-across-1")
        let canvas = app.scrollViews["canvas"]
        canvas.swipeLeft()
        sleep(1)
        shot("43-across-2")
        // Past the last page: keep pulling and a new page appears.
        at(0.8, 0.5).press(forDuration: 0.1, thenDragTo: at(0.2, 0.5), withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(1)
        shot("44-across-added")
        canvas.swipeRight()
        canvas.swipeRight()
        sleep(1)
        shot("45-across-back")

        // Zoomed in, the view belongs to one page: a finger moves about inside it, and only a
        // long pull past its edge turns to the next one.
        XCTAssertTrue(status().hasPrefix("1 / "), status())
        canvas.pinch(withScale: 2.5, velocity: 2)
        sleep(1)
        shot("46-across-zoomed")
        // Short drags move about inside the page and stop at its edge.
        for _ in 0..<5 { at(0.55, 0.5).press(forDuration: 0.05, thenDragTo: at(0.45, 0.5), withVelocity: .slow, thenHoldForDuration: 0.3) }
        sleep(2)
        XCTAssertTrue(status().hasPrefix("1 / "), "still on the page: " + status())
        shot("47-across-at-edge")
        at(0.9, 0.5).press(forDuration: 0.05, thenDragTo: at(0.3, 0.5), withVelocity: .slow, thenHoldForDuration: 0.3)
        sleep(2)
        XCTAssertTrue(status().hasPrefix("2 / "), "a long pull turns the page: " + status())
        shot("48-across-turned")
        // Zooming in and out is no page turn, wherever the fingers wander meanwhile.
        for scale in [0.4, 3.0, 0.3, 2.0, 0.5] as [CGFloat] {
            canvas.pinch(withScale: scale, velocity: scale < 1 ? -2 : 2)
            sleep(1)
            XCTAssertTrue(status().hasPrefix("2 / "), "zooming by \(scale) kept the page: " + status())
        }
        shot("49-across-pinched")
    }

    /// The status pill's text: page and zoom.
    func status() -> String {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS ' · '")).firstMatch.label
    }

    func testZZLaserRulerFindAndExport() {
        open("课堂笔记")
        let canvas = app.scrollViews["canvas"]
        let middle = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))

        // The laser draws nothing that stays: there is nothing to undo afterwards.
        app.buttons["激光笔"].tap()
        XCTAssertTrue(app.buttons["轨迹：画出的线约一秒后消失"].waitForExistence(timeout: 3))
        middle.withOffset(CGVector(dx: -200, dy: 150)).press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 150, dy: 220)), withVelocity: .fast, thenHoldForDuration: 0)
        shot("30-laser")
        XCTAssertFalse(app.buttons["撤销"].isEnabled)
        app.buttons["点：跟随笔尖的光点"].tap()
        middle.withOffset(CGVector(dx: -100, dy: 200)).press(forDuration: 0.3)
        XCTAssertFalse(app.buttons["撤销"].isEnabled)

        // The ruler: a stroke begun at its edge runs along it, however the hand wobbles.
        app.buttons["笔"].tap()
        app.buttons["尺子"].tap()
        sleep(1)
        middle.withOffset(CGVector(dx: -180, dy: -50)).press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 160, dy: -10)), withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertTrue(app.buttons["撤销"].isEnabled)
        shot("31-ruler-line")
        // A finger on the ruler moves it instead of writing.
        middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 60, dy: 170)), withVelocity: .slow, thenHoldForDuration: 0)
        shot("32-ruler-moved")
        app.buttons["撤销"].tap()
        XCTAssertFalse(app.buttons["撤销"].isEnabled, "moving the ruler added nothing")
        app.buttons["尺子"].tap()

        // Find: the text box on the page.
        app.buttons["在笔记中查找 (Ctrl+F)"].tap()
        let field = app.textFields["find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("inkpad")
        sleep(1)
        shot("33-find")
        XCTAssertEqual(app.staticTexts["find-count"].label, "1 / 1")
        field.typeText("zzz")
        sleep(1)
        XCTAssertEqual(app.staticTexts["find-count"].label, "无结果")
        app.buttons["关闭"].tap()

        // Export asks for pages and layers first; a range it cannot read is refused.
        app.buttons["导出"].tap()
        XCTAssertTrue(app.buttons["导出为 Goodnotes（实验性）…"].waitForExistence(timeout: 3))
        shot("34-export-menu")
        app.buttons["导出为矢量 PDF…"].tap()
        let range = app.textFields["export-range"]
        XCTAssertTrue(range.waitForExistence(timeout: 3))
        shot("35-export-dialog")
        range.tap()
        range.typeText("7-9")
        app.buttons.matching(NSPredicate(format: "label == '导出'")).allElementsBoundByIndex.last?.tap()   // the dialog's, not the header's
        XCTAssertTrue(range.exists, "still open: there is no page 7")
        app.buttons["取消"].tap()

        app.buttons["页面与设置"].tap()
        XCTAssertTrue(app.buttons["关于"].waitForExistence(timeout: 3))
        app.buttons["关于"].tap()
        sleep(1)
        shot("36-about")
        app.buttons["好"].tap()

        // Where it was being looked at is where it opens again.
        canvas.pinch(withScale: 2, velocity: 2)
        sleep(1)
        let before = status()
        app.buttons["文稿库"].tap()
        open("课堂笔记")
        XCTAssertEqual(status(), before)
        shot("37-reopened")
    }

    func testZZLibrarySelectionAndBoard() {
        XCTAssertTrue(app.buttons["open-课堂笔记"].waitForExistence(timeout: 10))
        app.buttons["新建"].tap()
        XCTAssertTrue(app.buttons["导入整个文件夹…"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["导入 PDF 或 Goodnotes…"].exists)
        shot("40-new-menu")
        closePopover()

        // Select two notebooks and duplicate them.
        app.buttons["选择项目"].tap()
        app.buttons["open-课堂笔记"].tap()
        app.buttons["open-草稿"].tap()
        XCTAssertTrue(app.staticTexts["已选择 2 项"].waitForExistence(timeout: 3))
        shot("41-selected")
        app.buttons["复制"].tap()
        XCTAssertTrue(app.buttons["open-课堂笔记 副本"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open-草稿 副本"].exists)
        XCTAssertFalse(app.staticTexts["已选择 0 项"].exists, "selection mode ends after an action")

        // Move the copies into the folder.
        app.buttons["选择项目"].tap()
        app.buttons["open-课堂笔记 副本"].tap()
        app.buttons["open-草稿 副本"].tap()
        app.buttons["移动"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["移动 2 项到"].waitForExistence(timeout: 3))
        // Nothing is chosen to begin with, so that nothing is moved by mistake.
        let moveButton = app.buttons.matching(NSPredicate(format: "label == '移动'")).allElementsBoundByIndex.last!
        XCTAssertFalse(moveButton.isEnabled)
        app.descendants(matching: .any)["folder-课程"].firstMatch.tap()
        shot("42-move-dialog")
        XCTAssertTrue(moveButton.isEnabled)
        moveButton.tap()
        // The move can be taken back from the toast, and done again from beside the items.
        XCTAssertTrue(app.buttons["撤销"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["open-课堂笔记 副本"].exists)
        app.buttons["撤销"].tap()
        XCTAssertTrue(app.buttons["open-课堂笔记 副本"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["open-草稿 副本"].exists)
        at(0.9, 0.92).press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["重做移动"].waitForExistence(timeout: 3))
        shot("42b-redo-menu")
        app.buttons["重做移动"].tap()
        sleep(2)
        XCTAssertFalse(app.buttons["open-课堂笔记 副本"].exists)
        shot("42c-redone")
        app.buttons["open-课程"].doubleTap()
        XCTAssertTrue(app.buttons["open-课堂笔记 副本"].waitForExistence(timeout: 5))

        // Everything in the folder to the trash, and back again from there.
        app.buttons["选择项目"].tap()
        app.buttons["全选"].tap()
        XCTAssertTrue(app.staticTexts["已选择 3 项"].waitForExistence(timeout: 3))
        app.buttons["废纸篓"].firstMatch.tap()
        sleep(1)
        XCTAssertFalse(app.buttons["open-线性代数"].exists)
        app.buttons.matching(NSPredicate(format: "label == '废纸篓'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["open-线性代数"].waitForExistence(timeout: 5))
        app.buttons["选择项目"].tap()
        app.buttons["全选"].tap()
        shot("43-trash-selected")
        app.buttons["恢复"].tap()
        sleep(1)
        XCTAssertFalse(app.buttons["open-线性代数"].exists)
        app.buttons.matching(NSPredicate(format: "label == '文稿'")).firstMatch.tap()

        // The folder that was open is remembered across launches.
        XCTAssertTrue(app.buttons["open-线性代数"].waitForExistence(timeout: 5), "still in the folder")
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["open-线性代数"].waitForExistence(timeout: 10), "opened in the folder it was left in")
        app.buttons["返回上一级"].tap()

        // A whiteboard has a map instead of the page count.
        app.buttons["新建"].tap()
        app.buttons["白板"].tap()
        XCTAssertTrue(app.buttons["创建白板"].waitForExistence(timeout: 5))
        app.buttons["创建白板"].tap()
        XCTAssertTrue(app.buttons["显示全部内容"].waitForExistence(timeout: 10))
        sleep(1)
        drag(0.3, 0.4, 0.6, 0.45)
        drag(0.5, 0.5, 0.8, 0.7)
        sleep(1)
        app.buttons["显示全部内容"].tap()
        sleep(1)
        shot("44-board-map")
        XCTAssertTrue(app.buttons["恢复 100%"].exists)
        app.buttons["恢复 100%"].tap()
        sleep(1)
        XCTAssertEqual(app.buttons["恢复 100%"].label, "恢复 100%")
        shot("45-board-100")
    }

    func testZZPencilPalette() {
        app.terminate()
        app.launchArguments = ["-demo", "-resetPrefs", "-palette", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        open("课堂笔记")
        // The palette a squeezed pencil brings up: the tool in hand is marked on it.
        let fountain = app.buttons["palette-钢笔"]
        XCTAssertTrue(fountain.waitForExistence(timeout: 5))
        XCTAssertTrue(fountain.isSelected)
        shot("50-palette")
        app.buttons["palette-颜色 3"].tap()
        app.buttons["palette-粗细 3"].tap()
        XCTAssertTrue(app.buttons["palette-颜色 3"].isSelected)
        app.buttons["palette-画笔"].tap()
        XCTAssertTrue(app.buttons["palette-画笔"].isSelected)
        // Its tools scroll along the arc: the ones further on come into reach.
        XCTAssertFalse(app.buttons["palette-胶带"].exists)
        let from = app.buttons["palette-橡皮擦"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: app.buttons["palette-重做"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)), withVelocity: .slow, thenHoldForDuration: 0.2)
        shot("51-palette-scrolled")
        XCTAssertTrue(app.buttons["palette-胶带"].waitForExistence(timeout: 3))
        app.buttons["palette-胶带"].tap()
        XCTAssertTrue(app.buttons["palette-胶带"].isSelected)
        shot("52-palette-tape")
        // Writing anywhere else puts it away, and writes.
        let canvas = app.scrollViews["canvas"]
        let middle = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.withOffset(CGVector(dx: -150, dy: 250)).press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 150, dy: 300)), withVelocity: .slow, thenHoldForDuration: 0)
        XCTAssertFalse(app.buttons["palette-胶带"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.buttons["撤销"].isEnabled)
        shot("53-palette-gone")
    }

    func testZZSelectByTapAndPressMenu() {
        open("课堂笔记")
        app.buttons["套索"].tap()
        // A tap picks the note under it; a tap on handwriting or on nothing picks nothing.
        at(0.72, 0.69).tap()
        XCTAssertTrue(app.buttons["剪切"].waitForExistence(timeout: 3))
        shot("60-picked")
        // Holding still on the selection: what can be done with it, and pasting.
        at(0.72, 0.69).press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["拷贝"].waitForExistence(timeout: 3) || app.menuItems["拷贝"].exists)
        shot("61-press-menu")
        let copy = app.menuItems["拷贝"].exists ? app.menuItems["拷贝"] : app.buttons.matching(NSPredicate(format: "label == '拷贝'")).allElementsBoundByIndex.last!
        copy.tap()
        sleep(1)
        // Holding still on the page elsewhere offers to paste there.
        at(0.3, 0.88).press(forDuration: 1.0)
        let paste = app.menuItems["粘贴"].exists ? app.menuItems["粘贴"] : app.buttons["粘贴"]
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        shot("62-paste-menu")
        paste.tap()
        sleep(1)
        shot("63-pasted")
        XCTAssertTrue(app.buttons["撤销"].isEnabled)
        // A finger on the selection carries it.
        at(0.3, 0.88).press(forDuration: 0.05, thenDragTo: at(0.5, 0.8), withVelocity: .slow, thenHoldForDuration: 0.1)
        sleep(1)
        shot("64-carried")
        at(0.2, 0.3).tap()
        XCTAssertFalse(app.buttons["剪切"].waitForExistence(timeout: 1), "a tap on handwriting selects nothing")
    }

    func testZZSettingsWithAccount() {
        app.terminate()
        app.launchArguments = ["-demo", "-resetPrefs", "-fakeAccount", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 10))
        sleep(2)
        app.buttons["设置"].tap()
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 5))
        at(0.5, 0.6).press(forDuration: 0.05, thenDragTo: at(0.5, 0.2), withVelocity: .fast, thenHoldForDuration: 0.3)
        at(0.5, 0.6).press(forDuration: 0.05, thenDragTo: at(0.5, 0.2), withVelocity: .fast, thenHoldForDuration: 0.3)
        shot("70-settings-account")
    }

    /// A menu opened low on the screen goes upwards, and all of it can be reached.
    func testZZMenuLowOnTheScreen() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        sleep(2)
        let names = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '课堂笔记' AND NOT identifier BEGINSWITH 'open-'"))
        XCTAssertTrue(names.firstMatch.waitForExistence(timeout: 10))
        shot("80-landscape")
        names.firstMatch.tap()
        sleep(1)
        shot("81-menu-low")
        let last = app.buttons["移到废纸篓"]
        XCTAssertTrue(app.buttons["重命名"].waitForExistence(timeout: 3))
        if !last.isHittable { app.buttons["复制"].firstMatch.press(forDuration: 0.05, thenDragTo: app.buttons["重命名"]) }
        XCTAssertTrue(last.isHittable, "the end of the menu can be reached")
        XCTAssertTrue(app.buttons["重命名"].exists)
    }
}
