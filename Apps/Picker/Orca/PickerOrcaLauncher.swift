import Foundation

public enum OrcaAgent: String, CaseIterable, Identifiable, Equatable, Hashable, Sendable {
    case grok
    case kiro
    case antigravity

    public var id: String { rawValue }

    public var cliID: String {
        switch self {
        case .grok:
            return "grok"
        case .kiro:
            return "kiro"
        case .antigravity:
            return "antigravity"
        }
    }

    public var buttonTitle: String {
        switch self {
        case .grok:
            return "Grok"
        case .kiro:
            return "Kiro"
        case .antigravity:
            return "AGY"
        }
    }
}

public enum PickerOrcaStrings {
    public static let missingOrcaMessage = "找不到 orca"

    public static func prefersChinese(preferredLanguages: [String] = Locale.preferredLanguages) -> Bool {
        guard let first = preferredLanguages.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return first.hasPrefix("zh")
    }

    public static var popupButtonTitle: String {
        prefersChinese() ? "发给 Orca" : "Send to Orca"
    }

    public static var noteFieldLabel: String {
        prefersChinese() ? "补充说明" : "Add a note"
    }
}

public struct PickerOrcaLaunchCommand: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let currentDirectoryPath: String
    public let environment: [String: String]
    public let promptText: String
    public let worktreeDirectory: String?
    public let tempSelectionFilePath: String?
}

public enum PickerOrcaLaunchOutcome: Equatable, Sendable {
    case launched
    case emptySelection
    case missingOrca
    case failed(String)
}

public enum PickerOrcaPreparationResult: Equatable, Sendable {
    case ready(PickerOrcaLaunchCommand)
    case rejected(PickerOrcaLaunchOutcome)
}

private final class LoginShellPATHCache: @unchecked Sendable {
    static let shared = LoginShellPATHCache()

    private let lock = NSLock()
    private var hasCaptured = false
    private var cachedPATH: String?

    func value(environment: [String: String]) -> String? {
        lock.lock()
        if hasCaptured {
            let existing = cachedPATH
            lock.unlock()
            return existing
        }
        lock.unlock()

        let captured = Self.captureLoginShellPATH(environment: environment)

        lock.lock()
        if !hasCaptured {
            cachedPATH = captured
            hasCaptured = true
        }
        let resolved = cachedPATH
        lock.unlock()
        return resolved
    }

    private static func captureLoginShellPATH(environment: [String: String]) -> String? {
        let shell = resolvedLoginShell(from: environment)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "/usr/bin/printenv PATH"]
        process.standardInput = FileHandle.nullDevice

        var shellEnv: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "TERM"] {
            if let value = environment[key], !value.isEmpty {
                shellEnv[key] = value
            }
        }
        if shellEnv["HOME"] == nil {
            shellEnv["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        shellEnv["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = shellEnv

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        if finished.wait(timeout: .now() + 1.5) == .timedOut {
            process.terminate()
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in output.components(separatedBy: .newlines).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func resolvedLoginShell(from environment: [String: String]) -> String {
        if let rawShell = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           rawShell.hasPrefix("/"),
           FileManager.default.isExecutableFile(atPath: rawShell) {
            return rawShell
        }
        if FileManager.default.isExecutableFile(atPath: "/bin/zsh") {
            return "/bin/zsh"
        }
        return "/bin/sh"
    }
}

public enum PickerOrcaLauncher {
    public static let maxDisplayCharacters = 80
    public static let maxInlineSelectionCharacters = 8000
    public static let maxNoteCharacters = 2000
    public static let envExecutablePath = "/usr/bin/env"

    private static let allowedEnvironmentKeys: Set<String> = [
        "PATH",
        "HOME",
        "TMPDIR",
        "USER",
        "LOGNAME",
        "SHELL",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "TERM",
        "__CF_USER_TEXT_ENCODING"
    ]

    private static let fallbackSystemPATHDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    public static func canSend(selection: String) -> Bool {
        !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func displaySelectionPreview(
        _ selection: String,
        maxCharacters: Int = maxDisplayCharacters
    ) -> String {
        let singleLine = selection
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard maxCharacters > 0, singleLine.count > maxCharacters else {
            return singleLine
        }
        return String(singleLine.prefix(maxCharacters)) + "…"
    }

    public static func defaultCandidatePaths(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String] {
        let standardizedHome = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        var paths: [String] = [
            "/Applications/Orca.app/Contents/Resources/bin/orca",
            "/opt/homebrew/bin/orca",
            "/usr/local/bin/orca"
        ]
        if !standardizedHome.isEmpty, standardizedHome != "/" {
            paths.append((standardizedHome as NSString).appendingPathComponent(".local/bin/orca"))
            paths.append((standardizedHome as NSString).appendingPathComponent("Applications/Orca.app/Contents/Resources/bin/orca"))
        }
        return paths
    }

    public static func isUsableExecutable(
        atPath path: String,
        fileManager: FileManager = .default
    ) -> Bool {
        guard path.hasPrefix("/"), path != "/" else { return false }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }

    public static func resolveOrcaExecutable(
        candidatePaths: [String]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        includeLoginShellPATH: Bool = true,
        loginShellPATHProvider: (() -> String?)? = nil,
        fileManager: FileManager = .default
    ) -> String? {
        let fixedCandidates = candidatePaths ?? defaultCandidatePaths(homeDirectory: homeDirectory)
        for rawCandidate in fixedCandidates {
            let expanded = expandLeadingTilde(in: rawCandidate, homeDirectory: homeDirectory)
            if isUsableExecutable(atPath: expanded, fileManager: fileManager) {
                return expanded
            }
        }

        if let envMatch = findExecutableInPATH(
            environment["PATH"],
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) {
            return envMatch
        }

        if let loginShellPATHProvider {
            if let loginMatch = findExecutableInPATH(
                loginShellPATHProvider(),
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ) {
                return loginMatch
            }
        } else if includeLoginShellPATH {
            let loginPATH = LoginShellPATHCache.shared.value(environment: environment)
            if let loginMatch = findExecutableInPATH(
                loginPATH,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ) {
                return loginMatch
            }
        }

        return nil
    }

    public static func preloadLoginShellPATHIfNeeded() {
        DispatchQueue.global(qos: .utility).async {
            if resolveOrcaExecutable(includeLoginShellPATH: false) != nil {
                return
            }
            _ = LoginShellPATHCache.shared.value(environment: ProcessInfo.processInfo.environment)
        }
    }

    public static func isOrcaOnPATH(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> Bool {
        findExecutableInPATH(
            environment["PATH"],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            fileManager: fileManager
        ) != nil
    }

    public static func sanitizedEnvironment(
        from source: [String: String] = ProcessInfo.processInfo.environment,
        executablePath: String? = nil,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String: String] {
        var clean: [String: String] = [:]
        for key in allowedEnvironmentKeys {
            if let value = source[key], !value.isEmpty {
                clean[key] = value
            }
        }

        if clean["HOME"] == nil, !homeDirectory.isEmpty, homeDirectory != "/" {
            clean["HOME"] = homeDirectory
        }

        if clean["LANG"] == nil && clean["LC_ALL"] == nil && clean["LC_CTYPE"] == nil {
            clean["LANG"] = "en_US.UTF-8"
        }

        var pathEntries: [String] = []
        var seen: Set<String> = []

        func appendDirectory(_ dir: String) {
            guard dir.hasPrefix("/"), dir != "/" else { return }
            if seen.insert(dir).inserted {
                pathEntries.append(dir)
            }
        }

        if let executablePath, executablePath.hasPrefix("/") {
            let execDir = (executablePath as NSString).deletingLastPathComponent
            appendDirectory(execDir)
        }

        if let existingPATH = clean["PATH"] {
            for segment in existingPATH.split(separator: ":", omittingEmptySubsequences: true) {
                appendDirectory(expandLeadingTilde(in: String(segment), homeDirectory: homeDirectory))
            }
        }

        for fallbackDir in fallbackSystemPATHDirectories {
            appendDirectory(fallbackDir)
        }

        clean["PATH"] = pathEntries.joined(separator: ":")
        return clean
    }

    public static func buildPrompt(
        selection: String,
        note: String,
        temporaryDirectory: String = NSTemporaryDirectory(),
        uuid: UUID = UUID(),
        fileManager: FileManager = .default
    ) throws -> (prompt: String, tempFilePath: String?) {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let formattedNote = trimmedNote.isEmpty ? "(none)" : String(trimmedNote.prefix(maxNoteCharacters))

        if selection.count <= maxInlineSelectionCharacters {
            let prompt = """
            Selected text:
            \(selection)

            Additional instructions:
            \(formattedNote)
            """
            return (prompt, nil)
        }

        let tempDirURL = URL(fileURLWithPath: temporaryDirectory, isDirectory: true)
        try fileManager.createDirectory(at: tempDirURL, withIntermediateDirectories: true)
        let fileName = "picker-orca-\(uuid.uuidString.lowercased()).txt"
        let tempFileURL = tempDirURL.appendingPathComponent(fileName, isDirectory: false)
        guard let data = selection.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try data.write(to: tempFileURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempFileURL.path)

        let truncatedSelection = String(selection.prefix(maxInlineSelectionCharacters))
        let prompt = """
        Selected text:
        \(truncatedSelection)

        Full selection file: \(tempFileURL.path)

        Additional instructions:
        \(formattedNote)
        """
        return (prompt, tempFileURL.path)
    }

    public static func resolveWorktreeDirectory(
        frontDocumentPath: String?,
        selection: String,
        fileManager: FileManager = .default
    ) -> String? {
        if let docDir = resolveDocumentDirectory(from: frontDocumentPath, fileManager: fileManager) {
            return docDir
        }
        return resolveSingleSelectionDirectory(from: selection, fileManager: fileManager)
    }

    public static func resolveWorkingDirectory(
        worktreeDirectory: String?,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if let worktreeDirectory, !worktreeDirectory.isEmpty, worktreeDirectory != "/" {
            return worktreeDirectory
        }
        let standardizedHome = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        if !standardizedHome.isEmpty, standardizedHome != "/" {
            return standardizedHome
        }
        let fallbackTemp = URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path
        return (fallbackTemp.isEmpty || fallbackTemp == "/") ? "/tmp" : fallbackTemp
    }

    public static func prepareCommand(
        agent: OrcaAgent,
        selection: String,
        note: String,
        frontDocumentPath: String?,
        candidatePaths: [String]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        includeLoginShellPATH: Bool = true,
        loginShellPATHProvider: (() -> String?)? = nil,
        temporaryDirectory: String = NSTemporaryDirectory(),
        uuid: UUID = UUID(),
        fileManager: FileManager = .default
    ) -> PickerOrcaPreparationResult {
        guard canSend(selection: selection) else {
            return .rejected(.emptySelection)
        }

        guard let executablePath = resolveOrcaExecutable(
            candidatePaths: candidatePaths,
            environment: environment,
            homeDirectory: homeDirectory,
            includeLoginShellPATH: includeLoginShellPATH,
            loginShellPATHProvider: loginShellPATHProvider,
            fileManager: fileManager
        ) else {
            return .rejected(.missingOrca)
        }

        let promptResult: (prompt: String, tempFilePath: String?)
        do {
            promptResult = try buildPrompt(
                selection: selection,
                note: note,
                temporaryDirectory: temporaryDirectory,
                uuid: uuid,
                fileManager: fileManager
            )
        } catch {
            let line = firstNonEmptyLine(in: error.localizedDescription) ?? "Failed to write temporary selection file."
            return .rejected(.failed(line))
        }

        let worktreeDir = resolveWorktreeDirectory(
            frontDocumentPath: frontDocumentPath,
            selection: selection,
            fileManager: fileManager
        )
        let cwd = resolveWorkingDirectory(worktreeDirectory: worktreeDir, homeDirectory: homeDirectory)
        let cleanEnvironment = sanitizedEnvironment(
            from: environment,
            executablePath: executablePath,
            homeDirectory: homeDirectory
        )

        var arguments: [String] = [
            "agent",
            "launch",
            "--agent", agent.cliID,
            "--surface", "terminal",
            "--focus",
            "--json",
            "--prompt", promptResult.prompt
        ]
        if let worktreeDir {
            arguments.append(contentsOf: ["--worktree", "path:\(worktreeDir)"])
        }

        return .ready(
            PickerOrcaLaunchCommand(
                executablePath: executablePath,
                arguments: arguments,
                currentDirectoryPath: cwd,
                environment: cleanEnvironment,
                promptText: promptResult.prompt,
                worktreeDirectory: worktreeDir,
                tempSelectionFilePath: promptResult.tempFilePath
            )
        )
    }

    public static func launch(
        agent: OrcaAgent,
        selection: String,
        note: String,
        frontDocumentPath: String?,
        candidatePaths: [String]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        includeLoginShellPATH: Bool = true,
        loginShellPATHProvider: (() -> String?)? = nil,
        temporaryDirectory: String = NSTemporaryDirectory(),
        fileManager: FileManager = .default,
        completion: @escaping @MainActor (PickerOrcaLaunchOutcome) -> Void
    ) {
        let prepared = prepareCommand(
            agent: agent,
            selection: selection,
            note: note,
            frontDocumentPath: frontDocumentPath,
            candidatePaths: candidatePaths,
            environment: environment,
            homeDirectory: homeDirectory,
            includeLoginShellPATH: includeLoginShellPATH,
            loginShellPATHProvider: loginShellPATHProvider,
            temporaryDirectory: temporaryDirectory,
            fileManager: fileManager
        )

        switch prepared {
        case .rejected(let failureOutcome):
            Task { @MainActor in
                completion(failureOutcome)
            }
        case .ready(let command):
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = execute(command: command)
                Task { @MainActor in
                    completion(outcome)
                }
            }
        }
    }

    public static func execute(command: PickerOrcaLaunchCommand) -> PickerOrcaLaunchOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: command.currentDirectoryPath, isDirectory: true)
        process.environment = command.environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            let message = firstNonEmptyLine(in: error.localizedDescription) ?? "Failed to launch orca."
            return .failed(message)
        }

        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.wait()
        process.waitUntilExit()

        let status = process.terminationStatus
        if status == 0 {
            return .launched
        }

        let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        return .failed(firstErrorLine(stderr: stderrText, stdout: stdoutText, exitStatus: status))
    }

    public static func firstErrorLine(stderr: String, stdout: String, exitStatus: Int32) -> String {
        if exitStatus == 127 {
            return PickerOrcaStrings.missingOrcaMessage
        }

        if let stderrLine = extractErrorMessageLine(from: stderr) {
            if isMissingOrcaEnvLine(stderrLine) {
                return PickerOrcaStrings.missingOrcaMessage
            }
            return stderrLine
        }

        if let stdoutLine = extractErrorMessageLine(from: stdout) {
            if isMissingOrcaEnvLine(stdoutLine) {
                return PickerOrcaStrings.missingOrcaMessage
            }
            return stdoutLine
        }

        return "orca exited with status \(exitStatus)"
    }

    private static func findExecutableInPATH(
        _ rawPATH: String?,
        homeDirectory: String,
        fileManager: FileManager
    ) -> String? {
        guard let rawPATH, !rawPATH.isEmpty else {
            return nil
        }

        for segment in rawPATH.split(separator: ":", omittingEmptySubsequences: true) {
            let directory = expandLeadingTilde(in: String(segment), homeDirectory: homeDirectory)
            guard directory.hasPrefix("/"), directory != "/" else { continue }
            let candidate = (directory as NSString).appendingPathComponent("orca")
            if isUsableExecutable(atPath: candidate, fileManager: fileManager) {
                return candidate
            }
        }
        return nil
    }

    private static func expandLeadingTilde(in path: String, homeDirectory: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" {
            return URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        }
        if trimmed.hasPrefix("~/") {
            let suffix = String(trimmed.dropFirst(2))
            let baseHome = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
            return (baseHome as NSString).appendingPathComponent(suffix)
        }
        return trimmed
    }

    private static func isMissingOrcaEnvLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.contains("orca: no such file or directory")
            || lowered.contains("env: orca:")
    }

    private static func extractErrorMessageLine(from rawOutput: String) -> String? {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorDict = json["error"] as? [String: Any],
               let message = errorDict["message"] as? String,
               let line = firstNonEmptyLine(in: message) {
                return line
            }
            if let errorString = json["error"] as? String,
               let line = firstNonEmptyLine(in: errorString) {
                return line
            }
            if let message = json["message"] as? String,
               let line = firstNonEmptyLine(in: message) {
                return line
            }
        }

        for rawLine in trimmed.components(separatedBy: .newlines) {
            let cleaned = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty && cleaned != "{" && cleaned != "}" {
                return cleaned
            }
        }
        return firstNonEmptyLine(in: trimmed)
    }

    private static func firstNonEmptyLine(in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func resolveDocumentDirectory(
        from rawDocument: String?,
        fileManager: FileManager
    ) -> String? {
        guard let raw = rawDocument?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        let resolvedPath: String
        if raw.lowercased().hasPrefix("file://") {
            guard let url = URL(string: raw), url.isFileURL else { return nil }
            resolvedPath = url.path
        } else if raw.hasPrefix("/") && !raw.hasPrefix("//") {
            resolvedPath = raw
        } else {
            return nil
        }

        let standardized = URL(fileURLWithPath: resolvedPath).standardizedFileURL.path
        guard standardized.hasPrefix("/"), standardized != "/" else { return nil }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            return standardized
        }

        let parentDir = URL(fileURLWithPath: standardized).deletingLastPathComponent().standardizedFileURL.path
        guard parentDir.hasPrefix("/"), parentDir != "/" else { return nil }

        if let gitRoot = findEnclosingGitRoot(startingAt: parentDir, fileManager: fileManager) {
            return gitRoot
        }

        var parentIsDir: ObjCBool = false
        if fileManager.fileExists(atPath: parentDir, isDirectory: &parentIsDir), parentIsDir.boolValue {
            return parentDir
        }
        return nil
    }

    private static func findEnclosingGitRoot(
        startingAt directory: String,
        fileManager: FileManager
    ) -> String? {
        var current = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path
        while current.hasPrefix("/") && current != "/" {
            let gitMarker = (current as NSString).appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitMarker) {
                return current
            }
            let next = URL(fileURLWithPath: current).deletingLastPathComponent().standardizedFileURL.path
            if next == current {
                break
            }
            current = next
        }
        return nil
    }

    private static func resolveSingleSelectionDirectory(
        from selection: String,
        fileManager: FileManager
    ) -> String? {
        let candidates = detectAbsolutePaths(in: selection)
        var existingDirectories: [String] = []
        var seen: Set<String> = []

        for candidate in candidates {
            let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard standardized.hasPrefix("/"), standardized != "/" else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            if seen.insert(standardized).inserted {
                existingDirectories.append(standardized)
            }
        }

        return existingDirectories.count == 1 ? existingDirectories[0] : nil
    }

    static func detectAbsolutePaths(in text: String) -> [String] {
        guard !text.isEmpty, !text.contains("\0") else { return [] }
        guard
            let splitRegex = try? NSRegularExpression(pattern: #"(?<!\\)\s+(?=/[^\s/])"#),
            let inlineRegex = try? NSRegularExpression(
                pattern: #""(/[^"\r\n]+)"|'(/[^'\r\n]+)'|`(/[^`\r\n]+)`|(?:^|(?<=[\s(\[{]))(/[A-Za-z0-9._\-](?:\\ |[^\s"'`<>])*)"#
            ),
            let fileURLRegex = try? NSRegularExpression(pattern: #"(?i)\bfile:///[^\s<>"`]+"#),
            let schemeRegex = try? NSRegularExpression(pattern: #"(?i)[a-z][a-z0-9+.\-]*://[^\s<>"`]+"#)
        else {
            return []
        }

        var detected: [String] = []
        let horizontalWhitespace = CharacterSet(charactersIn: " \t")

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: horizontalWhitespace)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("/"), !line.hasPrefix("//"), line.count >= 2 {
                let secondIndex = line.index(after: line.startIndex)
                if !line[secondIndex].isWhitespace {
                    detected.append(contentsOf: splitPathLine(line, using: splitRegex))
                    continue
                }
            }

            let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
            for fileMatch in fileURLRegex.matches(in: line, range: lineRange) {
                guard let urlRange = Range(fileMatch.range, in: line) else { continue }
                let cleanedURL = stripTrailingPathPunctuation(String(line[urlRange]))
                if let url = URL(string: cleanedURL), url.isFileURL, isValidAbsolutePath(url.path) {
                    detected.append(url.path)
                }
            }

            let urlRanges = schemeRegex.matches(in: line, range: lineRange).map(\.range)
            for match in inlineRegex.matches(in: line, range: lineRange) {
                if urlRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                    continue
                }
                for group in 1...4 {
                    guard let captureRange = Range(match.range(at: group), in: line) else { continue }
                    var candidate = String(line[captureRange])
                    if group == 4 {
                        candidate = stripTrailingPathPunctuation(
                            candidate.replacingOccurrences(of: #"\ "#, with: " ")
                        )
                    }
                    if isValidAbsolutePath(candidate) {
                        detected.append(candidate)
                    }
                    break
                }
            }
        }

        var unique: [String] = []
        var seen: Set<String> = []
        for path in detected where seen.insert(path).inserted {
            unique.append(path)
        }
        return unique
    }

    private static func splitPathLine(_ line: String, using splitRegex: NSRegularExpression) -> [String] {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let splits = splitRegex.matches(in: line, range: range)
        guard !splits.isEmpty else {
            let unescaped = stripTrailingPathPunctuation(line.replacingOccurrences(of: #"\ "#, with: " "))
            return isValidAbsolutePath(unescaped) ? [unescaped] : []
        }

        var segments: [String] = []
        var segmentStart = line.startIndex
        for split in splits {
            guard let splitRange = Range(split.range, in: line) else { continue }
            let segment = stripTrailingPathPunctuation(
                String(line[segmentStart..<splitRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: #"\ "#, with: " ")
            )
            if isValidAbsolutePath(segment) {
                segments.append(segment)
            }
            segmentStart = splitRange.upperBound
        }
        let remainder = stripTrailingPathPunctuation(
            String(line[segmentStart...])
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"\ "#, with: " ")
        )
        if isValidAbsolutePath(remainder) {
            segments.append(remainder)
        }
        return segments
    }

    private static func isValidAbsolutePath(_ candidate: String) -> Bool {
        guard
            candidate.count >= 2,
            candidate.hasPrefix("/"),
            !candidate.hasPrefix("//"),
            !candidate.contains("\0")
        else {
            return false
        }
        let secondIndex = candidate.index(after: candidate.startIndex)
        return !candidate[secondIndex].isWhitespace
    }

    private static func stripTrailingPathPunctuation(_ raw: String) -> String {
        var result = raw
        while let last = result.last {
            switch last {
            case ".", ",", ";", ":", "!", "?":
                result.removeLast()
            case ")":
                if characterCount("(", in: result) < characterCount(")", in: result) {
                    result.removeLast()
                } else {
                    return result
                }
            case "]":
                if characterCount("[", in: result) < characterCount("]", in: result) {
                    result.removeLast()
                } else {
                    return result
                }
            case "}":
                if characterCount("{", in: result) < characterCount("}", in: result) {
                    result.removeLast()
                } else {
                    return result
                }
            default:
                return result
            }
        }
        return result
    }

    private static func characterCount(_ target: Character, in text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if character == target { count += 1 }
        }
    }
}
