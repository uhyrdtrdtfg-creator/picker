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

public enum PickerOrcaWorktreeTarget: Equatable, Sendable {
    case workspace(path: String)
    case floatingTerminal

    public var selectorArgument: String {
        switch self {
        case .workspace(let path):
            return "path:\(path)"
        case .floatingTerminal:
            return PickerOrcaLauncher.floatingTerminalWorktreeSelector
        }
    }

    public var directoryPath: String? {
        switch self {
        case .workspace(let path):
            return path
        case .floatingTerminal:
            return nil
        }
    }
}

public typealias PickerOrcaSubcommandRunner = @Sendable (
    _ executablePath: String,
    _ arguments: [String],
    _ currentDirectoryPath: String,
    _ environment: [String: String]
) -> Data?

public struct PickerOrcaLaunchCommand: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let currentDirectoryPath: String
    public let environment: [String: String]
    public let promptText: String
    public let worktreeSelector: String
    public let worktreeDirectory: String?
    public let tempSelectionFilePath: String?

    public func withFloatingTerminalFallback(homeDirectory: String) -> PickerOrcaLaunchCommand {
        let fallbackCwd = PickerOrcaLauncher.resolveWorkingDirectory(
            worktreeDirectory: nil,
            homeDirectory: homeDirectory
        )
        var updatedArguments = arguments
        if let flagIndex = updatedArguments.firstIndex(of: "--worktree"),
           flagIndex + 1 < updatedArguments.count {
            updatedArguments[flagIndex + 1] = PickerOrcaLauncher.floatingTerminalWorktreeSelector
        } else {
            updatedArguments.append(contentsOf: ["--worktree", PickerOrcaLauncher.floatingTerminalWorktreeSelector])
        }
        return PickerOrcaLaunchCommand(
            executablePath: executablePath,
            arguments: updatedArguments,
            currentDirectoryPath: fallbackCwd,
            environment: environment,
            promptText: promptText,
            worktreeSelector: PickerOrcaLauncher.floatingTerminalWorktreeSelector,
            worktreeDirectory: nil,
            tempSelectionFilePath: tempSelectionFilePath
        )
    }
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
    public static let floatingTerminalWorktreeSelector = "global-floating-terminal"
    private static let subcommandTimeoutSeconds: TimeInterval = 3.0

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

    public static func resolveWorktreeTarget(
        frontDocumentPath: String?,
        executablePath: String,
        environment: [String: String],
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        subcommandRunner: PickerOrcaSubcommandRunner? = nil,
        fileManager: FileManager = .default
    ) -> PickerOrcaWorktreeTarget {
        let lookupCwd = resolveWorkingDirectory(worktreeDirectory: nil, homeDirectory: homeDirectory)
        let runner = subcommandRunner ?? defaultSubcommandRunner

        if let docDir = resolveDocumentDirectory(from: frontDocumentPath, fileManager: fileManager),
           let listData = runner(executablePath, ["worktree", "list", "--json"], lookupCwd, environment),
           let matchedRoot = matchingWorkspaceRoot(
               forDirectory: docDir,
               fromWorktreeListJSON: listData,
               fileManager: fileManager
           ) {
            return .workspace(path: matchedRoot)
        }

        if let psData = runner(executablePath, ["worktree", "ps", "--json"], lookupCwd, environment),
           let recentWorkspace = mostRecentRunningWorkspacePath(
               fromWorktreePsJSON: psData,
               fileManager: fileManager
           ) {
            return .workspace(path: recentWorkspace)
        }

        return .floatingTerminal
    }

    public static func matchingWorkspaceRoot(
        forDirectory directory: String,
        fromWorktreeListJSON data: Data,
        fileManager: FileManager = .default
    ) -> String? {
        guard let worktrees = extractWorktreeEntries(from: data) else {
            return nil
        }

        let candidateStd = standardizeDirectoryPath(directory)
        let candidateCanon = canonicalComparisonPath(candidateStd)
        guard candidateStd != "/", candidateCanon != "/" else {
            return nil
        }

        var bestRoot: String?
        var bestDepth = -1

        for entry in worktrees {
            guard isLocalHostEntry(entry),
                  (entry["isArchived"] as? Bool) != true,
                  (entry["isBare"] as? Bool) != true,
                  let rawPath = entry["path"] as? String else {
                continue
            }

            let wsStd = standardizeDirectoryPath(rawPath)
            guard isExistingDirectory(atPath: wsStd, fileManager: fileManager) else {
                continue
            }
            let wsCanon = canonicalComparisonPath(wsStd)

            if pathContains(parent: wsCanon, child: candidateCanon)
                || pathContains(parent: wsStd, child: candidateStd) {
                let depth = wsCanon.count
                if depth > bestDepth {
                    bestDepth = depth
                    bestRoot = wsStd
                }
            }
        }

        return bestRoot
    }

    public static func mostRecentRunningWorkspacePath(
        fromWorktreePsJSON data: Data,
        fileManager: FileManager = .default
    ) -> String? {
        guard let worktrees = extractWorktreeEntries(from: data) else {
            return nil
        }

        struct ScoredCandidate {
            let path: String
            let primaryActivity: Double
            let lastOutput: Double
            let isActiveRank: Int
            let sortOrder: Double
            let index: Int
        }

        var best: ScoredCandidate?

        for (index, entry) in worktrees.enumerated() {
            guard isLocalHostEntry(entry),
                  (entry["isArchived"] as? Bool) != true,
                  (entry["removing"] as? Bool) != true,
                  isRunningWorktreePsEntry(entry),
                  let rawPath = entry["path"] as? String else {
                continue
            }

            let wsStd = standardizeDirectoryPath(rawPath)
            guard isExistingDirectory(atPath: wsStd, fileManager: fileManager) else {
                continue
            }

            let lastActivity = numericDouble(entry["lastActivityAt"])
            let lastOutput = numericDouble(entry["lastOutputAt"])
            let primaryActivity = lastActivity ?? lastOutput ?? -.infinity
            let resolvedOutput = lastOutput ?? -.infinity
            let isActiveRank = ((entry["isActive"] as? Bool) == true) ? 1 : 0
            let sortOrder = numericDouble(entry["sortOrder"]) ?? -.infinity

            let candidate = ScoredCandidate(
                path: wsStd,
                primaryActivity: primaryActivity,
                lastOutput: resolvedOutput,
                isActiveRank: isActiveRank,
                sortOrder: sortOrder,
                index: index
            )

            if let currentBest = best {
                let candidateTuple = (
                    candidate.primaryActivity,
                    candidate.lastOutput,
                    candidate.isActiveRank,
                    candidate.sortOrder,
                    -candidate.index
                )
                let bestTuple = (
                    currentBest.primaryActivity,
                    currentBest.lastOutput,
                    currentBest.isActiveRank,
                    currentBest.sortOrder,
                    -currentBest.index
                )
                if candidateTuple > bestTuple {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }

        return best?.path
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
        subcommandRunner: PickerOrcaSubcommandRunner? = nil,
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

        let cleanEnvironment = sanitizedEnvironment(
            from: environment,
            executablePath: executablePath,
            homeDirectory: homeDirectory
        )
        let target = resolveWorktreeTarget(
            frontDocumentPath: frontDocumentPath,
            executablePath: executablePath,
            environment: cleanEnvironment,
            homeDirectory: homeDirectory,
            subcommandRunner: subcommandRunner,
            fileManager: fileManager
        )
        let cwd = resolveWorkingDirectory(worktreeDirectory: target.directoryPath, homeDirectory: homeDirectory)

        let arguments: [String] = [
            "agent",
            "launch",
            "--agent", agent.cliID,
            "--surface", "terminal",
            "--focus",
            "--json",
            "--prompt", promptResult.prompt,
            "--worktree", target.selectorArgument
        ]

        return .ready(
            PickerOrcaLaunchCommand(
                executablePath: executablePath,
                arguments: arguments,
                currentDirectoryPath: cwd,
                environment: cleanEnvironment,
                promptText: promptResult.prompt,
                worktreeSelector: target.selectorArgument,
                worktreeDirectory: target.directoryPath,
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
        subcommandRunner: PickerOrcaSubcommandRunner? = nil,
        temporaryDirectory: String = NSTemporaryDirectory(),
        fileManager: FileManager = .default,
        completion: @escaping @MainActor (PickerOrcaLaunchOutcome) -> Void
    ) {
        guard canSend(selection: selection) else {
            Task { @MainActor in
                completion(.emptySelection)
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
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
                subcommandRunner: subcommandRunner,
                temporaryDirectory: temporaryDirectory,
                fileManager: fileManager
            )

            let outcome: PickerOrcaLaunchOutcome
            switch prepared {
            case .rejected(let failureOutcome):
                outcome = failureOutcome
            case .ready(let command):
                let firstOutcome = execute(command: command)
                if case .failed(let errorMessage) = firstOutcome,
                   command.worktreeDirectory != nil,
                   isWorkspaceSelectorNotFoundMessage(errorMessage) {
                    outcome = execute(command: command.withFloatingTerminalFallback(homeDirectory: homeDirectory))
                } else {
                    outcome = firstOutcome
                }
            }

            Task { @MainActor in
                completion(outcome)
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

    private static let defaultSubcommandRunner: PickerOrcaSubcommandRunner = { executablePath, arguments, currentDirectoryPath, environment in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

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

        final class DataBox: @unchecked Sendable {
            var data = Data()
        }
        let outputBox = DataBox()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            outputBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        if finished.wait(timeout: .now() + subcommandTimeoutSeconds) == .timedOut {
            process.terminate()
            _ = readGroup.wait(timeout: .now() + 0.5)
            return nil
        }

        readGroup.wait()
        guard process.terminationStatus == 0, !outputBox.data.isEmpty else {
            return nil
        }
        return outputBox.data
    }

    private static func extractWorktreeEntries(from data: Data) -> [[String: Any]]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let ok = json["ok"] as? Bool, !ok {
            return nil
        }
        if let result = json["result"] as? [String: Any],
           let worktrees = result["worktrees"] as? [[String: Any]] {
            return worktrees
        }
        if let worktrees = json["worktrees"] as? [[String: Any]] {
            return worktrees
        }
        return nil
    }

    private static func isLocalHostEntry(_ entry: [String: Any]) -> Bool {
        guard let rawHost = entry["hostId"] as? String else {
            return true
        }
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "local"
    }

    private static func isRunningWorktreePsEntry(_ entry: [String: Any]) -> Bool {
        let status = (entry["status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let status,
           status == "inactive" || status == "sleeping" || status == "stopped" || status == "archived" {
            return false
        }

        if let liveCount = numericInt(entry["liveTerminalCount"]), liveCount > 0 {
            return true
        }
        if (entry["hasAttachedPty"] as? Bool) == true {
            return true
        }
        if (entry["terminalVerdict"] as? String)?.lowercased() == "live" {
            return true
        }
        if let status,
           status == "working"
            || status == "permission"
            || status == "active"
            || status == "running"
            || status == "monitoring"
            || status == "done" {
            return true
        }
        return false
    }

    private static func numericInt(_ raw: Any?) -> Int? {
        if let intVal = raw as? Int {
            return intVal
        }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private static func numericDouble(_ raw: Any?) -> Double? {
        if let doubleVal = raw as? Double, doubleVal.isFinite {
            return doubleVal
        }
        if let intVal = raw as? Int {
            return Double(intVal)
        }
        if let number = raw as? NSNumber {
            let value = number.doubleValue
            return value.isFinite ? value : nil
        }
        return nil
    }

    private static func standardizeDirectoryPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.hasPrefix("//") else {
            return ""
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private static func canonicalComparisonPath(_ path: String) -> String {
        guard path.hasPrefix("/"), path != "/" else {
            return path
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func pathContains(parent: String, child: String) -> Bool {
        guard parent.hasPrefix("/"), parent != "/", child.hasPrefix("/") else {
            return false
        }
        return child == parent || child.hasPrefix(parent + "/")
    }

    private static func isExistingDirectory(atPath path: String, fileManager: FileManager) -> Bool {
        guard path.hasPrefix("/"), path != "/" else {
            return false
        }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isWorkspaceSelectorNotFoundMessage(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("selector_not_found")
            || lowered.contains("no orca workspace")
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
        if fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return standardized
            }
        }

        let parentDir = URL(fileURLWithPath: standardized).deletingLastPathComponent().standardizedFileURL.path
        guard parentDir.hasPrefix("/"), parentDir != "/" else { return nil }

        var parentIsDir: ObjCBool = false
        if fileManager.fileExists(atPath: parentDir, isDirectory: &parentIsDir), parentIsDir.boolValue {
            return parentDir
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
