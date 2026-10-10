import Foundation

/// Interface language. Source strings are Simplified Chinese, as in the desktop app, and
/// its English and Japanese tables are reused; strings only this app has are added below.
enum L10n {
    /// Fixed when the app starts: the language chosen in the settings, or the system's.
    static let lang: String = {
        if let data = UserDefaults.standard.data(forKey: "prefs.v1"),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choice = saved["language"] as? String, ["zh", "en", "ja"].contains(choice) {
            return choice
        }
        let code = (Locale.preferredLanguages.first ?? "en").lowercased()
        return code.hasPrefix("zh") ? "zh" : code.hasPrefix("ja") ? "ja" : "en"
    }()

    private static func load(_ name: String) -> [String: String] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return table
    }

    static let table: [String: String] = {
        switch lang {
        case "ja": return load("ja").merging(extraJA) { a, _ in a }
        case "en": return load("en").merging(extraEN) { a, _ in a }
        default: return [:]
        }
    }()

    static let extraEN: [String: String] = [
        "5 秒": "5 seconds",
        "10 秒": "10 seconds",
        "15 秒": "15 seconds",
        "30 秒": "30 seconds",
        "1 分钟": "1 minute",
        "2 分钟": "2 minutes",
        "5 分钟": "5 minutes",
        "打开的笔记本多久同步一次": "How often the open notebook is synced",
        "每隔这么久查看一次其它设备写了什么；自己写的内容在停笔几秒后就会同步，与这里无关": "How often to look for what other devices wrote. What you write here is synced a few seconds after you pause, whatever this says",
        "“%s”缺少它的 PDF 或图片，暂时无法补全：%s": "“%s” is missing its PDFs or pictures and could not be completed for now: %s",
        "从云端下载的 PDF 或图片（%s）内容不对，没有使用它。请再同步一次。": "A PDF or picture downloaded from the cloud (%s) did not have the right content and was not used. Please sync again.",
        "上传的 PDF 或图片在云端的校验值不对，请再同步一次": "A PDF or picture arrived in the cloud with the wrong checksum; please sync again",
        "上传的笔记本在云端的校验值不对，请再同步一次": "The notebook arrived in the cloud with the wrong checksum; please sync again",
        "云端缺少这本笔记里的一个 PDF 或图片（%s）。请在仍有这本笔记的设备上同步一次。": "A PDF or picture of this notebook is missing from the cloud (%s). Please sync once on a device that still has the notebook.",
        "云端的笔记是由更新版本的 Inkpad 同步的，请先更新这台设备上的 Inkpad": "The notes in the cloud were synced by a newer version of Inkpad; please update Inkpad on this device first",
        "“%s”在同步时一直被其它设备更改，请稍后再同步": "“%s” kept being changed by another device during the sync; please sync again later",
        "回到文稿库时自动同步。删除的笔记会进入废纸篓，两边都改过的会逐笔合并。":
            "Syncs whenever you return to the library. Deleted notes go to the trash; notes edited on both sides are merged stroke by stroke.",
        "重做": "Redo", "撤销": "Undo", "拖动移动 · 右下角手柄缩放": "Drag to move · corner handle to resize", "导入 PDF…": "Import PDF…",
        "画完停住片刻，笔迹变成直线、矩形或椭圆": "Pause at the end of a stroke and it becomes a line, rectangle or ellipse",
        "笔离开屏幕后的这段时间内忽略手指触摸；页面在写字时乱跳就调大，手指反应迟钝就调小":
            "Finger touches are ignored for this long after the pencil lifts; raise it if the page jumps while writing, lower it if fingers feel sluggish",
        "同步使用你自己的 Google Cloud OAuth 客户端。在 Google Cloud 控制台创建“桌面应用”类型的 OAuth 客户端并启用 Google Drive API，然后把客户端 ID 和密钥填在这里（与桌面版用同一个）。应用只申请访问它自己创建的文件。":
            "Sync uses your own Google Cloud OAuth client. Create a “Desktop app” OAuth client in the Google Cloud console, enable the Google Drive API, and enter its ID and secret here (the same one as on the desktop). The app only asks for access to files it created itself.",
        "显示滚动条": "Show scroll indicators", "关掉不用的工具，让工具栏更清爽。": "Turn off the tools you do not use for a tidier toolbar.",
        "永久删除的笔记仍保留在本机，共 %s。清理只影响本机，不会删除云端的任何内容。":
            "Permanently deleted notes are still kept on this device: %s. Clearing affects this device only; nothing in the cloud is deleted.",
        "在本机删除的笔记，云端的文件仍然保留，但不会自动下载回来。先读取云端目录，再选择要还原的笔记。":
            "Notes deleted on this device are still kept in the cloud but are not downloaded again by themselves. Read the cloud index, then choose the notes to restore.",
        "本机上已永久删除的笔记将无法再恢复。云端的内容不受影响。": "Notes deleted for good on this device can no longer be restored. The cloud is not affected.",
        "导出文件夹…": "Export folder…", "导出全部页面为图片": "Export all pages as images",
        "“文件”App › 我的 iPad › Inkpad": "Files app › On My iPad › Inkpad",
        "同步": "Sync", "Google Drive 同步": "Google Drive sync", "尚未连接 Google Drive": "Not connected to Google Drive",
        "从未同步": "Never synced", "同步完成": "Sync finished", "上传 %d，下载 %d，合并 %d": "%d up, %d down, %d merged",
        "手指书写": "Draw with finger", "打开后单指书写，双指滚动和缩放": "One finger draws; two fingers scroll and zoom",
        "页面": "Pages", "更多颜色": "More colours", "纸张大小": "Paper size", "纸张颜色": "Paper colour",
        "无封面": "No cover", "新建": "New", "排序": "Sort", "按名称": "By name", "按日期": "By date",
        "凭据": "Credentials", "使用与桌面版相同的“桌面应用”OAuth 客户端，两边看到的就是同一批文件。":
            "Use the same “Desktop app” OAuth client as on the desktop, so both sides see the same files.",
        "账号": "Account", "连接 Google Drive": "Connect Google Drive", "已断开连接": "Disconnected",
        "导出为 PDF": "Export as PDF", "分享笔记本文件": "Share notebook file", "导出当前页为图片": "Export this page as an image",
        "在最后添加页面": "Add page at the end", "页面已删除": "Page deleted", "粘贴": "Paste",
        "此笔记本已在其他设备上更改，已重新载入": "This notebook changed on another device and was reloaded",
        "版本": "Version", "文件": "Files", "笔记本保存在“文件”App 的“我的 iPad › Inkpad”中。":
            "Notebooks are kept in the Files app under On My iPad › Inkpad.",
        "捏一下 Apple Pencil Pro 弹出工具盘": "Squeeze Apple Pencil Pro for the tool palette",
        "工具盘出现在笔尖旁边，中间一段工具可以沿弧线滑动；再捏一下或在别处落笔即收起":
            "The palette appears by the pencil tip, and its tools scroll along the arc; squeeze again or write elsewhere to put it away",
        "本机钥匙串": "This device’s keychain", "“文件”App › 我的 iPhone › Inkpad": "Files app › On My iPhone › Inkpad", "收起": "Collapse", "展开": "Expand",
        "双击 Apple Pencil 切换橡皮擦": "Double-tap Apple Pencil for the eraser", "方向": "Orientation",
        "删除后可在废纸篓中恢复。": "Deleted items can be restored from the trash.", "打开": "Open",
        "输入文字": "Enter text", "置顶": "Bring to front", "置底": "Send to back", "尺寸": "Size",
        "无法保存": "Could not save", "页": "Pages", "白板没有页面": "A whiteboard has no pages",
        "缩放": "Zoom", "已是最新": "Up to date", "移到此处": "Move here", "文稿库（根目录）": "Library (top level)",
    ]

    static let extraJA: [String: String] = [
        "5 秒": "5 秒",
        "10 秒": "10 秒",
        "15 秒": "15 秒",
        "30 秒": "30 秒",
        "1 分钟": "1 分",
        "2 分钟": "2 分",
        "5 分钟": "5 分",
        "打开的笔记本多久同步一次": "開いているノートを同期する間隔",
        "每隔这么久查看一次其它设备写了什么；自己写的内容在停笔几秒后就会同步，与这里无关": "他のデバイスで書かれた内容をこの間隔で確認します。このデバイスで書いた内容は、この設定に関係なく、ペンを止めて数秒後に同期されます",
        "“%s”缺少它的 PDF 或图片，暂时无法补全：%s": "「%s」の PDF または画像が欠けており、今は補えません：%s",
        "从云端下载的 PDF 或图片（%s）内容不对，没有使用它。请再同步一次。": "クラウドからダウンロードした PDF または画像（%s）の内容が正しくないため、使用しませんでした。もう一度同期してください。",
        "上传的 PDF 或图片在云端的校验值不对，请再同步一次": "アップロードした PDF または画像のクラウド上のチェックサムが一致しません。もう一度同期してください",
        "上传的笔记本在云端的校验值不对，请再同步一次": "アップロードしたノートのクラウド上のチェックサムが一致しません。もう一度同期してください",
        "云端缺少这本笔记里的一个 PDF 或图片（%s）。请在仍有这本笔记的设备上同步一次。": "このノートの PDF または画像がクラウドにありません（%s）。このノートが残っているデバイスで一度同期してください。",
        "云端的笔记是由更新版本的 Inkpad 同步的，请先更新这台设备上的 Inkpad": "クラウドのノートは新しいバージョンの Inkpad で同期されています。先にこのデバイスの Inkpad を更新してください",
        "“%s”在同步时一直被其它设备更改，请稍后再同步": "「%s」は同期中に他のデバイスで変更され続けました。後でもう一度同期してください",
        "本机钥匙串": "このデバイスのキーチェーン", "“文件”App › 我的 iPhone › Inkpad": "「ファイル」App › この iPhone 内 › Inkpad", "收起": "折りたたむ", "展开": "展開",
        "捏一下 Apple Pencil Pro 弹出工具盘": "Apple Pencil Pro をスクイーズしてツールパレットを表示",
        "工具盘出现在笔尖旁边，中间一段工具可以沿弧线滑动；再捏一下或在别处落笔即收起":
            "パレットはペン先のそばに現れ、ツールは弧に沿ってスクロールできます。もう一度スクイーズするか、ほかの場所に書くと閉じます",
        "同步": "同期", "Google Drive 同步": "Google Drive 同期", "尚未连接 Google Drive": "Google Drive に未接続",
        "手指书写": "指で書く", "页面": "ページ", "新建": "新規", "排序": "並べ替え", "按名称": "名前順", "按日期": "日付順",
        "导出全部页面为图片": "すべてのページを画像として書き出す", "“文件”App › 我的 iPad › Inkpad": "「ファイル」App › この iPad 内 › Inkpad",
        "粘贴": "ペースト", "打开": "開く", "版本": "バージョン", "文件": "ファイル", "尺寸": "サイズ", "缩放": "ズーム",
    ]
}

func tr(_ text: String) -> String {
    L10n.table[text] ?? text
}

/// tr() for strings with %d / %s placeholders, as the desktop app writes them.
func trf(_ text: String, _ args: CVarArg...) -> String {
    String(format: tr(text).replacingOccurrences(of: "%s", with: "%@"), arguments: args)
}
