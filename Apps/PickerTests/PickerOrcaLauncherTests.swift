import Foundation
import XCTest

final class PickerOrcaLauncherTests: XCTestCase {
    private var tempDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("picker-orca-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirectoryURL = dir
    }

    override func tearDownWithError() throws {
        if let tempDirectoryURL {
            try? FileManager.default.removeItem(at: tempDirectoryURL)
        }
        tempDirectoryURL = nil
        try super.tearDownWithError()
    }

    private func makeExecutableScript(named name: String = "orca", body: String = "#!/bin/sh\nexit 0\n") throws -> URL {
        let binDir = tempDirectoryURL.appendingPathComponent("fake-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let scriptURL = binDir.appendingPathComponent(name)
        try Data(body.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func encodeJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    func testResolverSelectsFakeExecutableInTempDirectory() throws {
        let missingPath = tempDirectoryURL.appendingPathComponent("missing/orca").path
        let nonExecutableURL = tempDirectoryURL.appendingPathComponent("nonexec-orca")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: nonExecutableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nonExecutableURL.path)

        let directoryNamedOrca = tempDirectoryURL.appendingPathComponent("dir-orca", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryNamedOrca, withIntermediateDirectories: true)

        let fakeBinDir = tempDirectoryURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBinDir, withIntermediateDirectories: true)
        let fakeOrcaURL = fakeBinDir.appendingPathComponent("orca")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeOrcaURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOrcaURL.path)

        let resolved = PickerOrcaLauncher.resolveOrcaExecutable(
            candidatePaths: [missingPath, nonExecutableURL.path, directoryNamedOrca.path, fakeOrcaURL.path],
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: tempDirectoryURL.path,
            includeLoginShellPATH: false
        )

        XCTAssertEqual(resolved, fakeOrcaURL.path)
    }

    func testResolverReturnsNilWhenExecutableIsMissing() {
        let missingFirst = tempDirectoryURL.appendingPathComponent("none/orca").path
        let missingSecond = tempDirectoryURL.appendingPathComponent("also-missing/orca").path
        let emptyBinDir = tempDirectoryURL.appendingPathComponent("empty-bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyBinDir, withIntermediateDirectories: true)

        let resolved = PickerOrcaLauncher.resolveOrcaExecutable(
            candidatePaths: [missingFirst, missingSecond],
            environment: ["PATH": emptyBinDir.path],
            homeDirectory: tempDirectoryURL.path,
            includeLoginShellPATH: false,
            loginShellPATHProvider: { nil }
        )

        XCTAssertNil(resolved)
    }

    func testDefaultCandidateOrderAndLastResortPATHFallback() throws {
        let fakeHome = tempDirectoryURL.appendingPathComponent("home", isDirectory: true)
        let candidates = PickerOrcaLauncher.defaultCandidatePaths(homeDirectory: fakeHome.path)

        XCTAssertGreaterThanOrEqual(candidates.count, 4)
        XCTAssertEqual(candidates[0], "/Applications/Orca.app/Contents/Resources/bin/orca")
        XCTAssertEqual(candidates[1], "/opt/homebrew/bin/orca")
        XCTAssertEqual(candidates[2], "/usr/local/bin/orca")
        XCTAssertEqual(candidates[3], fakeHome.appendingPathComponent(".local/bin/orca").path)

        let loginBinDir = tempDirectoryURL.appendingPathComponent("login-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: loginBinDir, withIntermediateDirectories: true)
        let loginOrca = loginBinDir.appendingPathComponent("orca")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: loginOrca)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loginOrca.path)

        let resolvedViaLoginPATH = PickerOrcaLauncher.resolveOrcaExecutable(
            candidatePaths: [tempDirectoryURL.appendingPathComponent("absent/orca").path],
            environment: ["PATH": tempDirectoryURL.path],
            homeDirectory: fakeHome.path,
            includeLoginShellPATH: true,
            loginShellPATHProvider: { loginBinDir.path }
        )

        XCTAssertEqual(resolvedViaLoginPATH, loginOrca.path)
    }

    func testPrepareCommandUsesAbsoluteOrcaPathWithoutEnvAndPreservesChineseNote() throws {
        let workspaceDir = tempDirectoryURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let standardizedWorkspace = workspaceDir.standardizedFileURL.path

        let script = """
        #!/bin/sh
        if [ "$1" = "worktree" ] && [ "$2" = "list" ]; then
          printf '{"ok":true,"result":{"worktrees":[{"id":"repo::%s","hostId":"local","path":"%s"}]}}\n' "\(standardizedWorkspace)" "\(standardizedWorkspace)"
          exit 0
        fi
        exit 0
        """
        let fakeOrcaURL = try makeExecutableScript(body: script)

        let chineseSelection = "X 上被推荐最多的是下面这几个站，全部是第三方做的，不是 Anthropic 官方工具。"
        let chineseNote = "看下是真的吗？"

        let result = PickerOrcaLauncher.prepareCommand(
            agent: .grok,
            selection: chineseSelection,
            note: chineseNote,
            frontDocumentPath: workspaceDir.path,
            candidatePaths: [fakeOrcaURL.path],
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: tempDirectoryURL.path,
            includeLoginShellPATH: false,
            temporaryDirectory: tempDirectoryURL.path
        )

        guard case .ready(let command) = result else {
            XCTFail("Expected ready launch command, got \(result)")
            return
        }

        XCTAssertEqual(command.executablePath, fakeOrcaURL.path)
        XCTAssertNotEqual(command.executablePath, PickerOrcaLauncher.envExecutablePath)
        XCTAssertEqual(command.currentDirectoryPath, standardizedWorkspace)
        XCTAssertEqual(command.worktreeSelector, "path:\(standardizedWorkspace)")
        XCTAssertEqual(
            command.arguments,
            [
                "agent",
                "launch",
                "--agent", "grok",
                "--surface", "terminal",
                "--focus",
                "--json",
                "--prompt", command.promptText,
                "--worktree", "path:\(standardizedWorkspace)"
            ]
        )
        XCTAssertTrue(command.promptText.contains(chineseSelection))
        XCTAssertTrue(command.promptText.contains("看下是真的吗？"))

        let missingResult = PickerOrcaLauncher.prepareCommand(
            agent: .antigravity,
            selection: chineseSelection,
            note: chineseNote,
            frontDocumentPath: nil,
            candidatePaths: [tempDirectoryURL.appendingPathComponent("missing-orca").path],
            environment: [:],
            homeDirectory: tempDirectoryURL.path,
            includeLoginShellPATH: false,
            temporaryDirectory: tempDirectoryURL.path
        )
        XCTAssertEqual(missingResult, .rejected(.missingOrca))
        XCTAssertEqual(PickerOrcaStrings.missingOrcaMessage, "找不到 orca")
    }

    func testChoice1NestedDocumentUsesEnclosingWorkspaceRootNotFileDirectory() throws {
        let fakeOrcaURL = try makeExecutableScript()
        let fakeHome = tempDirectoryURL.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)

        let outerWorkspace = tempDirectoryURL.appendingPathComponent("orca", isDirectory: true)
        let innerWorkspace = outerWorkspace.appendingPathComponent("workspaces/picker-workspace", isDirectory: true)
        let nestedSourceDir = innerWorkspace.appendingPathComponent("Apps/Picker/Orca", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSourceDir, withIntermediateDirectories: true)
        let nestedFile = nestedSourceDir.appendingPathComponent("PickerOrcaLauncher.swift")
        try Data("// swift\n".utf8).write(to: nestedFile)

        let listData = try encodeJSON([
            "ok": true,
            "result": [
                "worktrees": [
                    [
                        "id": "repo1::\(outerWorkspace.standardizedFileURL.path)",
                        "hostId": "local",
                        "path": outerWorkspace.standardizedFileURL.path,
                        "isArchived": false,
                        "isBare": false
                    ],
                    [
                        "id": "repo2::\(innerWorkspace.standardizedFileURL.path)",
                        "hostId": "local",
                        "path": innerWorkspace.standardizedFileURL.path,
                        "isArchived": false,
                        "isBare": false
                    ]
                ]
            ]
        ])

        final class CallRecorder: @unchecked Sendable {
            var commands: [[String]] = []
        }
        let recorder = CallRecorder()

        let result = PickerOrcaLauncher.prepareCommand(
            agent: .kiro,
            selection: "selected snippet",
            note: "hello",
            frontDocumentPath: nestedFile.path,
            candidatePaths: [fakeOrcaURL.path],
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: fakeHome.path,
            includeLoginShellPATH: false,
            subcommandRunner: { _, args, _, _ in
                recorder.commands.append(args)
                if args == ["worktree", "list", "--json"] {
                    return listData
                }
                return nil
            },
            temporaryDirectory: tempDirectoryURL.path
        )

        guard case .ready(let command) = result else {
            XCTFail("Expected ready launch command, got \(result)")
            return
        }

        let expectedRoot = innerWorkspace.standardizedFileURL.path
        XCTAssertEqual(recorder.commands, [["worktree", "list", "--json"]])
        XCTAssertEqual(command.worktreeSelector, "path:\(expectedRoot)")
        XCTAssertEqual(command.worktreeDirectory, expectedRoot)
        XCTAssertEqual(command.currentDirectoryPath, expectedRoot)
        XCTAssertNotEqual(command.worktreeDirectory, nestedSourceDir.standardizedFileURL.path)
        XCTAssertTrue(command.arguments.suffix(2) == ["--worktree", "path:\(expectedRoot)"])
    }

    func testChoice2UsesMostRecentRunningLocalWorkspaceFromWorktreePs() throws {
        let fakeOrcaURL = try makeExecutableScript()
        let fakeHome = tempDirectoryURL.appendingPathComponent("home", isDirectory: true)
        let downloadsDir = fakeHome.appendingPathComponent("Downloads", isDirectory: true)
        let olderRunningDir = tempDirectoryURL.appendingPathComponent("ws-older-running", isDirectory: true)
        let newerRunningDir = tempDirectoryURL.appendingPathComponent("ws-newer-running", isDirectory: true)
        let inactiveRecentDir = tempDirectoryURL.appendingPathComponent("ws-inactive", isDirectory: true)
        let remoteRunningDir = tempDirectoryURL.appendingPathComponent("ws-remote", isDirectory: true)

        for dir in [fakeHome, downloadsDir, olderRunningDir, newerRunningDir, inactiveRecentDir, remoteRunningDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let outsideFile = downloadsDir.appendingPathComponent("notes.txt")
        try Data("notes\n".utf8).write(to: outsideFile)

        let listData = try encodeJSON([
            "ok": true,
            "result": [
                "worktrees": [
                    [
                        "id": "repo::\(olderRunningDir.standardizedFileURL.path)",
                        "hostId": "local",
                        "path": olderRunningDir.standardizedFileURL.path
                    ]
                ]
            ]
        ])

        let psData = try encodeJSON([
            "ok": true,
            "result": [
                "worktrees": [
                    [
                        "worktreeId": "repo::\(inactiveRecentDir.standardizedFileURL.path)",
                        "hostId": "local",
                        "path": inactiveRecentDir.standardizedFileURL.path,
                        "status": "inactive",
                        "liveTerminalCount": 0,
                        "hasAttachedPty": false,
                        "lastActivityAt": 9_000_000
                    ],
                    [
                        "worktreeId": "repo::\(remoteRunningDir.standardizedFileURL.path)",
                        "hostId": "ssh:remote-box",
                        "path": remoteRunningDir.standardizedFileURL.path,
                        "status": "working",
                        "liveTerminalCount": 2,
                        "hasAttachedPty": true,
                        "lastActivityAt": 8_000_000
                    ],
                    [
                        "worktreeId": "repo::\(olderRunningDir.standardizedFileURL.path)",
                        "hostId": "local",
                        "path": olderRunningDir.standardizedFileURL.path,
                        "status": "active",
                        "liveTerminalCount": 1,
                        "hasAttachedPty": true,
                        "lastActivityAt": 1_000_000
                    ],
                    [
                        "worktreeId": "repo::\(newerRunningDir.standardizedFileURL.path)",
                        "hostId": "local",
                        "path": newerRunningDir.standardizedFileURL.path,
                        "status": "working",
                        "liveTerminalCount": 2,
                        "hasAttachedPty": true,
                        "lastActivityAt": 5_000_000
                    ]
                ]
            ]
        ])

        let outsideResult = PickerOrcaLauncher.prepareCommand(
            agent: .grok,
            selection: "不同机器上的地址和端口不一样。",
            note: "hello",
            frontDocumentPath: outsideFile.path,
            candidatePaths: [fakeOrcaURL.path],
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: fakeHome.path,
            includeLoginShellPATH: false,
            subcommandRunner: { _, args, _, _ in
                if args == ["worktree", "list", "--json"] { return listData }
                if args == ["worktree", "ps", "--json"] { return psData }
                return nil
            },
            temporaryDirectory: tempDirectoryURL.path
        )

        guard case .ready(let outsideCommand) = outsideResult else {
            XCTFail("Expected ready launch command, got \(outsideResult)")
            return
        }

        let expectedRecent = newerRunningDir.standardizedFileURL.path
        XCTAssertEqual(outsideCommand.worktreeSelector, "path:\(expectedRecent)")
        XCTAssertEqual(outsideCommand.worktreeDirectory, expectedRecent)
        XCTAssertEqual(outsideCommand.currentDirectoryPath, expectedRecent)
        XCTAssertFalse(outsideCommand.arguments.contains("path:\(downloadsDir.standardizedFileURL.path)"))

        let safariResult = PickerOrcaLauncher.prepareCommand(
            agent: .antigravity,
            selection: "Safari selection",
            note: "hello",
            frontDocumentPath: nil,
            candidatePaths: [fakeOrcaURL.path],
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: fakeHome.path,
            includeLoginShellPATH: false,
            subcommandRunner: { _, args, _, _ in
                if args == ["worktree", "ps", "--json"] { return psData }
                XCTFail("worktree list should not be required when frontDocumentPath is nil, got \(args)")
                return nil
            },
            temporaryDirectory: tempDirectoryURL.path
        )

        guard case .ready(let safariCommand) = safariResult else {
            XCTFail("Expected ready launch command for Safari selection, got \(safariResult)")
            return
        }

        XCTAssertEqual(safariCommand.worktreeSelector, "path:\(expectedRecent)")
        XCTAssertEqual(safariCommand.currentDirectoryPath, expectedRecent)
    }

    func testChoice3FallsBackToGlobalFloatingTerminalWhenNoRunningWorkspaceOrLookupFails() throws {
        let fakeHome = tempDirectoryURL.appendingPathComponent("home", isDirectory: true)
        let nonWorkspaceDir = tempDirectoryURL.appendingPathComponent("unmanaged-folder", isDirectory: true)
        let inactiveWorkspaceDir = tempDirectoryURL.appendingPathComponent("inactive-ws", isDirectory: true)
        for dir in [fakeHome, nonWorkspaceDir, inactiveWorkspaceDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let emptyMatchListData = try encodeJSON([
            "ok": true,
            "result": [
                "worktrees": [
                    [
                        "id": "repo::\(inactiveWorkspaceDir.standardizedFileURL.path)",
                        "hostId": "local",
                        "path": inactiveWorkspaceDir.standardizedFileURL.path
                    ]
                ]
            ]
        ])

        let inactiveOnlyPsData = try encodeJSON([
            "ok": true,
            "result": [
                "worktrees": [
                    [
                        "worktreeId": "repo::\(inactiveWorkspaceDir.standardizedFileURL.path)",
                        "hostId": "local",
                        "path": inactiveWorkspaceDir.standardizedFileURL.path,
                        "status": "inactive",
                        "liveTerminalCount": 0,
                        "hasAttachedPty": false,
                        "lastActivityAt": 1_234_567
                    ]
                ]
            ]
        ])

        let fakeOrcaURL = try makeExecutableScript(named: "orca-failing", body: "#!/bin/sh\nexit 1\n")

        let noRunningResult = PickerOrcaLauncher.prepareCommand(
            agent: .grok,
            selection: "WeChat message selection",
            note: "hello",
            frontDocumentPath: nonWorkspaceDir.path,
            candidatePaths: [fakeOrcaURL.path],
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: fakeHome.path,
            includeLoginShellPATH: false,
            subcommandRunner: { _, args, _, _ in
                if args == ["worktree", "list", "--json"] { return emptyMatchListData }
                if args == ["worktree", "ps", "--json"] { return inactiveOnlyPsData }
                return nil
            },
            temporaryDirectory: tempDirectoryURL.path
        )

        guard case .ready(let noRunningCommand) = noRunningResult else {
            XCTFail("Expected ready launch command, got \(noRunningResult)")
            return
        }

        let expectedHome = fakeHome.standardizedFileURL.path
        XCTAssertEqual(noRunningCommand.worktreeSelector, PickerOrcaLauncher.floatingTerminalWorktreeSelector)
        XCTAssertNil(noRunningCommand.worktreeDirectory)
        XCTAssertEqual(noRunningCommand.currentDirectoryPath, expectedHome)
        XCTAssertEqual(
            noRunningCommand.arguments,
            [
                "agent",
                "launch",
                "--agent", "grok",
                "--surface", "terminal",
                "--focus",
                "--json",
                "--prompt", noRunningCommand.promptText,
                "--worktree", "global-floating-terminal"
            ]
        )

        // Real subprocess lookup failure (exit status 1) must still launch with global-floating-terminal.
        let failingLookupResult = PickerOrcaLauncher.prepareCommand(
            agent: .kiro,
            selection: "Safari selection when lookup fails",
            note: "hello",
            frontDocumentPath: nonWorkspaceDir.path,
            candidatePaths: [fakeOrcaURL.path],
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: fakeHome.path,
            includeLoginShellPATH: false,
            temporaryDirectory: tempDirectoryURL.path
        )

        guard case .ready(let fallbackCommand) = failingLookupResult else {
            XCTFail("Expected ready fallback command when lookup fails, got \(failingLookupResult)")
            return
        }

        XCTAssertEqual(fallbackCommand.worktreeSelector, "global-floating-terminal")
        XCTAssertNil(fallbackCommand.worktreeDirectory)
        XCTAssertEqual(fallbackCommand.currentDirectoryPath, expectedHome)
        XCTAssertEqual(fallbackCommand.arguments.suffix(2), ["--worktree", "global-floating-terminal"])
    }

    @MainActor
    func testPanelButtonsStayEnabledForNonWorkspaceSelectionAndErrors() {
        let state = PickerOrcaPanelState()
        state.reset(selectionText: "不同机器上的地址和端口不一样。我按安装脚本里的...", isOrcaAvailable: true)

        XCTAssertNil(state.errorMessage)
        XCTAssertTrue(state.canSend)
        XCTAssertEqual(OrcaAgent.allCases.map(\.buttonTitle), ["Grok", "Kiro", "AGY"])

        // Even if a non-missing-orca error message is set, Grok/Kiro/AGY stay enabled.
        state.errorMessage = "Transient launch failure"
        XCTAssertTrue(state.canSend)
    }

    func testDisplaySelectionPreviewSingleLineTruncationAt80Characters() {
        let multiLine = "第一行内容\n   第二行内容   " + String(repeating: "测", count: 90)
        let preview = PickerOrcaLauncher.displaySelectionPreview(multiLine)
        XCTAssertFalse(preview.contains("\n"))
        XCTAssertEqual(preview.count, 81)
        XCTAssertTrue(preview.hasSuffix("…"))
    }

    func testPopupDividersAppearOnlyBetweenClipboardLookupAndSendToOrcaGroups() {
        let fullActions: [PopupAction] = [
            .copy,
            .cut,
            .paste,
            .search,
            .openLink,
            .dictionary,
            .reveal,
            .spelling,
            .sendToOrca
        ]
        let dividerIndices = fullActions.indices.filter {
            PickerPopupView.shouldShowDivider(before: $0, in: fullActions)
        }
        XCTAssertEqual(dividerIndices, [3, 8])

        let clipboardAndOrca: [PopupAction] = [.copy, .cut, .paste, .sendToOrca]
        let twoGroupDividers = clipboardAndOrca.indices.filter {
            PickerPopupView.shouldShowDivider(before: $0, in: clipboardAndOrca)
        }
        XCTAssertEqual(twoGroupDividers, [3])

        let pasteOnly: [PopupAction] = [.paste]
        let singleGroupDividers = pasteOnly.indices.filter {
            PickerPopupView.shouldShowDivider(before: $0, in: pasteOnly)
        }
        XCTAssertTrue(singleGroupDividers.isEmpty)
    }

    @MainActor
    func testPopupAndOrcaPanelsFollowSystemAppearanceAndMatchVisualSystemMetrics() {
        let popupPanel = PickerPopupPanel()
        let orcaPanel = PickerOrcaPanel()

        XCTAssertNil(popupPanel.appearance)
        XCTAssertNil(orcaPanel.appearance)
        XCTAssertFalse(popupPanel.hasShadow)
        XCTAssertFalse(orcaPanel.hasShadow)

        XCTAssertEqual(PickerPopupView.buttonSize, 28)
        XCTAssertEqual(PickerPopupView.symbolSize, 13)
        XCTAssertEqual(PickerOrcaView.panelWidth, 260)
        XCTAssertEqual(PickerOrcaView.panelPadding, 8)
        XCTAssertEqual(PickerOrcaView.agentRowHeight, 26)
        XCTAssertEqual(PickerOrcaView.cornerRadius, 8)

        let popupSize = popupPanel.setActions([.copy, .cut, .paste, .search, .sendToOrca]) { _ in }
        XCTAssertEqual(
            popupSize.height,
            28 + 2 + PickerStyle.floatingShadowInsets.top + PickerStyle.floatingShadowInsets.bottom,
            accuracy: 1.0
        )

        let state = PickerOrcaPanelState()
        state.reset(selectionText: "Selected snippet", isOrcaAvailable: true)
        state.noteText = "补充说明测试"
        let orcaSize = orcaPanel.configureContent(
            state: state,
            onSelectAgent: { _ in },
            onCancel: {}
        )
        XCTAssertEqual(
            orcaSize.width,
            260 + PickerStyle.floatingShadowInsets.leading + PickerStyle.floatingShadowInsets.trailing,
            accuracy: 1.0
        )
        XCTAssertEqual(orcaPanel.commitAndReadNoteText(fallback: ""), "补充说明测试")
    }
}
