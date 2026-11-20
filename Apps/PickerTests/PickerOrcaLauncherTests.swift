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
        let fakeOrcaURL = tempDirectoryURL.appendingPathComponent("orca")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeOrcaURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeOrcaURL.path)

        let workspaceDir = tempDirectoryURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

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
                "--worktree", "path:\(workspaceDir.standardizedFileURL.path)"
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

    func testDisplaySelectionPreviewSingleLineTruncationAt80Characters() {
        let multiLine = "第一行内容\n   第二行内容   " + String(repeating: "测", count: 90)
        let preview = PickerOrcaLauncher.displaySelectionPreview(multiLine)
        XCTAssertFalse(preview.contains("\n"))
        XCTAssertEqual(preview.count, 81)
        XCTAssertTrue(preview.hasSuffix("…"))
    }
}
