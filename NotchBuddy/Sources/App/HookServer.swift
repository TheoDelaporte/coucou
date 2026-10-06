import Foundation
import Darwin
import AppKit

// MARK: - HookServer
// Listens on a Unix domain socket for events from nb-hook (Claude Code hooks).
// Thread-safe: socket I/O on background threads, state updates dispatched to main queue.

final class HookServer: @unchecked Sendable {
    static let shared = HookServer()

    // Support directory paths
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy")
    }
    static var socketPath: String { supportDir.appendingPathComponent("nb.sock").path }
    static var hookScriptPath: String {
        #if APPSTORE
        // Written to ~/.claude/coucou/nb-hook via security-scoped bookmark during hook installation
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/coucou/nb-hook").path
        #else
        return supportDir.appendingPathComponent("nb-hook").path
        #endif
    }

    // No approval blocking state — notch is notification-only, user answers in VS Code

    private var serverFD: Int32 = -1
    private struct PendingApprovalItem {
        let fd: Int32
        let sessionId: String
        let projectName: String
        let tool: String
        let command: String
    }
    private var pendingApprovals: [String: PendingApprovalItem] = [:]   // held open per session
    private var activeSessionId: String? = nil  // current active session

    private init() {}

    // MARK: - Start

    func start() {
        #if !APPSTORE
        installHookScript()
        #endif
        Thread.detachNewThread { self.serverThread() }
    }

    // MARK: - Socket server (background thread)

    private func serverThread() {
        let path = Self.socketPath
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        serverFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, c) in cpath.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: c) }
        }

        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindRC == 0 else { close(fd); return }
        guard Darwin.listen(fd, 10) == 0 else { close(fd); return }

        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else { break }
            Thread.detachNewThread { self.handleClient(fd: clientFD) }
        }
    }

    // MARK: - Client handler (background thread)

    private func handleClient(fd: Int32) {
        // Read newline-delimited JSON
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        outer: while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            for i in 0..<n {
                if buf[i] == UInt8(ascii: "\n") { break outer }
                raw.append(buf[i])
            }
        }

        guard !raw.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
            return
        }

        let eventName = payload["hook_event_name"] as? String ?? ""
        let isAntigravity = payload["conversationId"] != nil

        if eventName == "PermissionRequest" || (isAntigravity && eventName == "PreToolUse" && isDangerousTool(payload)) {
            // Hold fd open — Claude Code (PermissionRequest) or Antigravity (PreToolUse) waits for our decision (up to 120s)
            Task { @MainActor in self.processPermissionRequest(fd: fd, payload: payload) }
        } else {
            Task { @MainActor in self.processEvent(name: eventName, payload: payload) }
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
        }
    }

    // MARK: - Dangerous Tool Detection (Antigravity & Shell)

    private func isAlwaysAllowed(cmd: String, tool: String) -> Bool {
        let path = Self.supportDir.appendingPathComponent("always_allowed.json").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return false
        }
        let rules = Set(list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        if !tool.isEmpty {
            if rules.contains(tool) || rules.contains("mcp(\(tool))") {
                return true
            }
            if tool.contains("/") {
                let srv = String(tool.split(separator: "/").first ?? "")
                if rules.contains(srv) || rules.contains("mcp(\(srv))") {
                    return true
                }
            }
        }
        if !cmd.isEmpty {
            let cmdClean = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
            if rules.contains(cmdClean) {
                return true
            }
            var words = cmdClean.split(separator: " ").map(String.init)
            while let first = words.first, first.contains("=") && !first.hasPrefix("-") {
                words.removeFirst()
            }
            if let binFull = words.first {
                let binBase = URL(fileURLWithPath: binFull).lastPathComponent.lowercased()
                if rules.contains(binFull) || rules.contains(binBase) {
                    return true
                }
                for i in 1...words.count {
                    let p = words[0..<i].joined(separator: " ")
                    if rules.contains(p) { return true }
                    if i > 1 {
                        let pb = ([binBase] + words[1..<i]).joined(separator: " ")
                        if rules.contains(pb) { return true }
                    }
                }
            }
            for r in rules {
                if !r.isEmpty && (cmdClean == r || cmdClean.hasPrefix(r + " ") || cmdClean.hasPrefix(r + "\t")) {
                    return true
                }
            }
        }
        return false
    }

    private func isMajorDestructiveCommand(_ cmd: String) -> Bool {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return false }

        let subCommands = trimmed.components(separatedBy: CharacterSet(charactersIn: ";|&"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for sub in subCommands {
            var words = sub.split(separator: " ").map(String.init)
            while let first = words.first, first.contains("=") && !first.hasPrefix("-") {
                words.removeFirst()
            }
            guard let binaryWithExt = words.first else { continue }
            let binary = URL(fileURLWithPath: binaryWithExt).lastPathComponent.lowercased()

            if binary == "sudo" || binary == "shutdown" || binary == "reboot" {
                return true
            }
            if binary.hasPrefix("mkfs") {
                return true
            }
            if binary == "rm" {
                let args = words.dropFirst()
                let flags = args.filter { $0.hasPrefix("-") }.map { String($0.dropFirst()) }.joined()
                let hasRF = (flags.contains("r") || flags.contains("R")) && flags.contains("f")
                let targets = args.filter { !$0.hasPrefix("-") }
                if hasRF && targets.contains(where: { $0 == "/" || $0 == "/*" || $0 == "~" || $0 == "$home" || $0 == "/system" || $0 == "/library" }) {
                    return true
                }
            }
            if binary == "dd" {
                let args = words.dropFirst()
                if args.contains(where: { $0.hasPrefix("if=") }) {
                    return true
                }
            }
            if words.contains("sudo") || words.contains("shutdown") || words.contains("reboot") {
                return true
            }
        }
        return false
    }

    private func isDangerousTool(_ payload: [String: Any]) -> Bool {
        var toolName = payload["tool_name"] as? String ?? ""
        var args: [String: Any] = [:]

        if let tc = payload["toolCall"] as? [String: Any] {
            if let name = tc["name"] as? String, !name.isEmpty {
                toolName = name
            }
            if let tcArgs = tc["args"] as? [String: Any] {
                args = tcArgs
            }
        } else if let toolInput = payload["tool_input"] as? [String: Any] {
            args = toolInput
        }

        // 1. Shell commands
        if toolName == "run_command" || toolName == "Command" || toolName == "Bash" {
            let cmd = (args["CommandLine"] as? String) ?? (args["command"] as? String) ?? ""
            if isAlwaysAllowed(cmd: cmd, tool: toolName) {
                return false
            }
            if isMajorDestructiveCommand(cmd) {
                return true
            }
            let isBypass = (args["BypassSandbox"] as? Bool) ?? false
            if isBypass {
                return isDangerousShellCommand(cmd)
            }
            // BypassSandbox: false and not major destructive -> auto-allow
            return false
        }

        // 2. Read-only built-in tools
        let readOnlyTools: Set<String> = [
            "view_file", "list_dir", "grep_search", "find_by_name",
            "read_url_content", "search_web", "read_resource",
            "list_resources", "ask_question", "schedule"
        ]
        if readOnlyTools.contains(toolName) {
            return false
        }

        // 3. Task / subagent management (read vs write)
        if toolName == "manage_task" || toolName == "manage_subagents" {
            let action = (args["Action"] as? String)?.lowercased() ?? ""
            if action == "list" || action == "status" {
                return false
            }
            if isAlwaysAllowed(cmd: "", tool: toolName) {
                return false
            }
            return true
        }

        // 4. MCP Tools
        if toolName == "call_mcp_tool" {
            let server = (args["ServerName"] as? String)?.lowercased() ?? ""
            let tool = (args["ToolName"] as? String) ?? ""
            let fullMcp = "\(server)/\(tool)"
            if isAlwaysAllowed(cmd: "", tool: fullMcp) {
                return false
            }
            return isDangerousMcpTool(server: server, tool: tool)
        }

        // 5. File / other tools
        let target = (args["TargetFile"] as? String) ?? (args["AbsolutePath"] as? String) ?? ""
        if !target.isEmpty && isAlwaysAllowed(cmd: target, tool: toolName) {
            return false
        }
        if isAlwaysAllowed(cmd: "", tool: toolName) {
            return false
        }

        // 6. Explicitly sensitive tools
        let sensitiveTools: Set<String> = [
            "write_to_file", "replace_file_content", "multi_replace_file_content",
            "apply_diff", "generate_image", "invoke_subagent", "define_subagent",
            "send_message"
        ]
        if sensitiveTools.contains(toolName) {
            return true
        }

        // Fail-safe default
        return true
    }

    private func isDangerousShellCommand(_ cmd: String) -> Bool {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }

        let subCommands = trimmed.components(separatedBy: CharacterSet(charactersIn: ";|&"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for sub in subCommands {
            if isDangerousSingleShellCommand(sub) {
                return true
            }
        }
        return false
    }

    private func isDangerousSingleShellCommand(_ cmd: String) -> Bool {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }

        let stripped = trimmed
            .replacingOccurrences(of: "2>/dev/null", with: "")
            .replacingOccurrences(of: "2>&1", with: "")
            .replacingOccurrences(of: "1>/dev/null", with: "")
            .replacingOccurrences(of: "&>/dev/null", with: "")
        if stripped.contains(">") {
            return true
        }

        var words = trimmed.split(separator: " ").map(String.init)
        while let first = words.first, first.contains("=") && !first.hasPrefix("-") {
            words.removeFirst()
        }
        guard let binaryWithExt = words.first else { return false }
        let binary = URL(fileURLWithPath: binaryWithExt).lastPathComponent.lowercased()

        let safeShellBinaries: Set<String> = [
            "ls", "pwd", "cat", "head", "tail", "less", "more",
            "which", "whereis", "type", "file", "stat",
            "grep", "egrep", "fgrep", "rg", "ag", "wc",
            "find", "tree", "diff", "cmp",
            "uname", "whoami", "id", "date", "uptime",
            "echo", "printf", "true", "false", "test", "["
        ]

        if safeShellBinaries.contains(binary) {
            if binary == "find" {
                if words.contains("-exec") || words.contains("-execdir") || words.contains("-delete") {
                    return true
                }
            }
            return false
        }

        if binary == "git" {
            let args = words.dropFirst()
            var subVerb = ""
            for arg in args {
                if !arg.hasPrefix("-") {
                    subVerb = arg.lowercased()
                    break
                }
            }
            let safeGitSubverbs: Set<String> = [
                "status", "diff", "log", "show", "branch", "rev-parse",
                "describe", "tag", "remote", "config"
            ]
            if safeGitSubverbs.contains(subVerb) {
                if subVerb == "branch" {
                    if args.contains("-d") || args.contains("-D") || args.contains("-m") || args.contains("-M") {
                        return true
                    }
                }
                if subVerb == "remote" {
                    if args.contains("add") || args.contains("remove") || args.contains("rename") || args.contains("set-url") {
                        return true
                    }
                }
                if subVerb == "tag" {
                    if args.contains("-d") || args.contains("--delete") {
                        return true
                    }
                }
                return false
            }
            return true
        }

        return true
    }

    private func isDangerousMcpTool(server: String, tool: String) -> Bool {
        let s = server.lowercased()
        let t = tool.lowercased()

        if s == "context7" || s == "snyk" {
            return false
        }
        if s == "serena" {
            let serenaReadOnly: Set<String> = [
                "read_file", "list_dir", "find_file", "search_for_pattern",
                "get_symbols_overview", "find_symbol", "find_referencing_symbols",
                "find_implementations", "find_declaration", "get_diagnostics_for_file",
                "read_memory", "list_memories", "get_current_config",
                "initial_instructions", "onboarding"
            ]
            return !serenaReadOnly.contains(t)
        }
        if s == "notion" {
            if t.hasPrefix("api-get-") || t.hasPrefix("api-retrieve-") || t.hasPrefix("api-list-") {
                return false
            }
            return true
        }

        let readOnlyPrefixes = ["get", "list", "read", "view", "search", "find", "query", "check"]
        for p in readOnlyPrefixes {
            if t.hasPrefix(p) {
                return false
            }
        }
        return true
    }


    // MARK: - Event → AppState
    // All Claude Code events route to the permanent "integration_claude" task.
    // View switches only happen if VS Code is the currently focused mochi.
    // When not focused: state updates animate the mini bot in the pill; badge shown for alerts.

    @MainActor
    private func processEvent(name: String, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String
            ?? payload["conversationId"] as? String
            ?? "unknown"
        var cwd = payload["cwd"] as? String ?? ""
        if cwd.isEmpty, let workspaces = payload["workspacePaths"] as? [String], let first = workspaces.first {
            cwd = first
        }
        var projectName: String = "Antigravity"
        if let workspaces = payload["workspacePaths"] as? [String], let first = workspaces.first, !first.isEmpty {
            let wsName = URL(fileURLWithPath: first).lastPathComponent
            if !wsName.isEmpty && !wsName.hasPrefix(".") {
                projectName = wsName
            }
        }
        if projectName == "Antigravity", !cwd.isEmpty {
            let raw = URL(fileURLWithPath: cwd).lastPathComponent
            if !raw.isEmpty && !raw.hasPrefix(".") && raw != "config" && raw != "bin" && raw != "tmp" {
                projectName = raw
            }
        }
        projectName = aliasProjectName(projectName)

        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""
        let isEditor = termProgram.lowercased().contains("antigravity") ||
                       bundleId.lowercased().contains("antigravity") ||
                       termProgram.lowercased().contains("vscode") ||
                       bundleId.lowercased().contains("vscode") ||
                       payload["conversationId"] != nil
        guard isEditor else {
            nbLog("Ignored \(name) from \(termProgram.isEmpty ? bundleId : termProgram) (\(projectName))")
            return
        }

        let focused = state.focusId == "integration_claude"

        switch name {

        case "SessionStart":
            activeSessionId = sessionId
            upsertTask(projectName: projectName, cwd: cwd)
            nbLog("SessionStart \(projectName) (\(sessionId.prefix(8)))")
            if state.isPresent { expandIfNeeded(to: .overview) }
            SoundEngine.shared.play("work")

        case "PreInvocation", "UserPromptSubmit":
            activeSessionId = sessionId
            upsertTask(projectName: projectName, cwd: cwd)
            state.updateTask(id: "integration_claude", state: .thinking)
            state.focusId = "integration_claude"
            if let prompt = payload["prompt"] as? String, !prompt.isEmpty {
                appendStep(id: "integration_claude", step: String(prompt.prefix(60)))
            } else {
                appendStep(id: "integration_claude", step: "Réflexion…")
            }
            if state.mode == .hidden {
                NotificationCenter.default.post(name: .hookReveal, object: nil)
            }

        case "PreToolUse":
            if state.pendingApproval == nil || state.pendingApproval?.sessionId == sessionId {
                activeSessionId = sessionId
                upsertTask(projectName: projectName, cwd: cwd)
                state.focusId = "integration_claude"
                if state.pendingApproval == nil {
                    state.updateTask(id: "integration_claude", state: .working)
                }
            }
            var tool = payload["tool_name"] as? String
            var input = payload["tool_input"] as? [String: Any]
            if tool == nil, let tc = payload["toolCall"] as? [String: Any] {
                tool = tc["name"] as? String
                input = tc["args"] as? [String: Any]
            }
            let step = frenchStep(tool: tool ?? "Tool", input: input ?? [:])
            appendStep(id: "integration_claude", step: step)
            nbLog("PreToolUse \(step)")
            if tool == "ask_question" || (payload["toolCall"] as? [String: Any])?["name"] as? String == "ask_question" {
                state.updateTask(id: "integration_claude", state: .question)
            }
            if state.mode == .hidden && state.pendingApproval == nil {
                NotificationCenter.default.post(name: .hookReveal, object: nil)
            }

        case "PostToolUse":
            if state.pendingApproval == nil {
                state.updateTask(id: "integration_claude", state: .working)
            }

        case "PostInvocation":
            break

        case "PostToolUseFailure":
            state.updateTask(id: "integration_claude", state: .working)
            appendStep(id: "integration_claude", step: "⚠ failed")

        case "Notification":
            let message = payload["message"] as? String ?? ""
            let lower = message.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                state.updateTask(id: "integration_claude", state: .ratelimit)
                SoundEngine.shared.play("rate")
            } else if message.hasSuffix("?") {
                state.updateTask(id: "integration_claude", state: .question)
                appendStep(id: "integration_claude", step: message)
            }

        case "Stop":
            cleanupPendingApproval(for: sessionId)
            if state.pendingApproval != nil {
                for (_, item) in pendingApprovals {
                    let fd = item.fd
                    Task.detached { [weak self] in
                        self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                        close(fd)
                    }
                }
                pendingApprovals.removeAll()
                state.pendingApproval = nil
                state.isPinned = false
                if state.view == .approval {
                    state.view = state.tasks.isEmpty ? .empty : .overview
                }
            }
            state.updateTask(id: "integration_claude", state: .finished)
            if let message = payload["message"] as? String, !message.isEmpty {
                appendStep(id: "integration_claude", step: String(message.prefix(60)))
            } else {
                appendStep(id: "integration_claude", step: "Terminé ✓")
            }
            SoundEngine.shared.play("finish")
            if focused {
                expandIfNeeded(to: .finished)
            } else {
                setPillBadge(id: "integration_claude", badge: .finished)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                state.updateTask(id: "integration_claude", state: .idle)
                self.clearPillBadge(id: "integration_claude")
            }

        case "StopFailure":
            state.updateTask(id: "integration_claude", state: .error)
            SoundEngine.shared.play("error")
            if focused {
                expandIfNeeded(to: .error)
            } else {
                setPillBadge(id: "integration_claude", badge: .error)
            }

        case "SessionEnd":
            activeSessionId = nil
            state.updateTask(id: "integration_claude", state: .idle)
            clearSession()

        case "SubagentStart":
            appendStep(id: "integration_claude", step: "+ subagent")

        case "SubagentStop":
            appendStep(id: "integration_claude", step: "• subagent done")

        default:
            break
        }

        // Trigger live context budget refresh
        DispatchQueue.global(qos: .background).async {
            AntigravityContextService.shared.refresh()
        }
    }

    // MARK: - Helpers

    @MainActor
    private func cleanupPendingApproval(for sessionId: String) {
        if let item = pendingApprovals.removeValue(forKey: sessionId) {
            let fd = item.fd
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
        }
        let state = AppState.shared
        if state.pendingApproval?.sessionId == sessionId {
            if let next = pendingApprovals.values.first {
                state.pendingApproval = ApprovalInfo(
                    sessionId: next.sessionId,
                    projectName: next.projectName,
                    tool: next.tool,
                    command: next.command
                )
                state.isPinned = true
                state.updateTask(id: "integration_claude", state: .approval)
            } else {
                state.pendingApproval = nil
                state.isPinned = false
                if state.view == .approval {
                    state.view = state.tasks.isEmpty ? .empty : .overview
                }
            }
        }
    }

    @MainActor
    private func expandIfNeeded(to view: IslandView) {
        let state = AppState.shared
        if state.pendingApproval != nil && view != .approval {
            return
        }
        let isAlert: Bool
        switch view {
        case .approval, .finished, .error, .confused: isAlert = true
        default: isAlert = false
        }
        if isAlert {
            state.view = view
            NotificationCenter.default.post(name: .hookExpand, object: view)
        } else if state.mode == .hidden {
            // Non-alert work events: reveal compact only, never force-expand
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }
        // Already compact and non-alert: Mochi state update is enough, no expand
    }

    // MARK: - Permission request (blocking — Claude Code waits for decision)

    @MainActor
    private func processPermissionRequest(fd: Int32, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String
            ?? payload["conversationId"] as? String
            ?? "unknown"
        var cwd = payload["cwd"] as? String ?? ""
        if cwd.isEmpty, let workspaces = payload["workspacePaths"] as? [String], let first = workspaces.first {
            cwd = first
        }
        var projectName: String = "Antigravity"
        if let workspaces = payload["workspacePaths"] as? [String], let first = workspaces.first, !first.isEmpty {
            let wsName = URL(fileURLWithPath: first).lastPathComponent
            if !wsName.isEmpty && !wsName.hasPrefix(".") {
                projectName = wsName
            }
        }
        if projectName == "Antigravity", !cwd.isEmpty {
            let raw = URL(fileURLWithPath: cwd).lastPathComponent
            if !raw.isEmpty && !raw.hasPrefix(".") && raw != "config" && raw != "bin" && raw != "tmp" {
                projectName = raw
            }
        }
        projectName = aliasProjectName(projectName)

        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""
        let isEditor = termProgram.lowercased().contains("antigravity") ||
                       bundleId.lowercased().contains("antigravity") ||
                       termProgram.lowercased().contains("vscode") ||
                       bundleId.lowercased().contains("vscode") ||
                       payload["conversationId"] != nil
        guard isEditor else {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        var tool = payload["tool_name"] as? String ?? "Command"
        var command = tool
        if let input = payload["tool_input"] as? [String: Any] {
            command = input["command"] as? String ?? tool
        }
        if let tc = payload["toolCall"] as? [String: Any] {
            if let name = tc["name"] as? String, !name.isEmpty {
                tool = name
            }
            if let args = tc["args"] as? [String: Any] {
                if let cmd = args["CommandLine"] as? String, !cmd.isEmpty {
                    command = cmd
                } else if let target = args["TargetFile"] as? String, !target.isEmpty {
                    command = target
                } else if let path = args["AbsolutePath"] as? String, !path.isEmpty {
                    command = path
                } else if let server = args["ServerName"] as? String, let tname = args["ToolName"] as? String {
                    tool = "\(server)/\(tname)"
                    command = "\(server)/\(tname)"
                }
            }
        }
        nbLog("PermissionRequest \(tool): \(command)")

        if let existing = pendingApprovals.removeValue(forKey: sessionId) {
            let oldFd = existing.fd
            Task.detached { [weak self] in
                self?.sendLine(fd: oldFd, text: #"{"permissionDecision":"ask"}"#)
                close(oldFd)
            }
        }
        let item = PendingApprovalItem(
            fd: fd,
            sessionId: sessionId,
            projectName: projectName,
            tool: tool,
            command: command
        )
        pendingApprovals[sessionId] = item
        activeSessionId = sessionId

        upsertTask(projectName: projectName, cwd: cwd)
        state.updateTask(id: "integration_claude", state: .approval)
        state.pendingApproval = ApprovalInfo(sessionId: sessionId, projectName: projectName, tool: tool, command: command)
        state.isPinned = true
        SoundEngine.shared.play("approval")

        // Approval always forces the island open — user must be able to respond
        state.focusId = "integration_claude"
        expandIfNeeded(to: .approval)

        let capturedFd = fd
        let capturedSessionId = sessionId
        DispatchQueue.main.asyncAfter(deadline: .now() + 115) { [weak self] in
            guard let self else { return }
            if self.pendingApprovals[capturedSessionId]?.fd == capturedFd {
                self.sendApprovalDecision("ask", forSession: capturedSessionId)
            }
        }
    }

    /// Called by ApprovalView buttons. Writes the decision to the waiting nb-hook and cleans up.
    @MainActor
    func sendApprovalDecision(_ decision: String, forSession targetSessionId: String? = nil) {
        let state = AppState.shared
        let targetId = targetSessionId ?? state.pendingApproval?.sessionId ?? ""
        let item = pendingApprovals.removeValue(forKey: targetId)
            ?? pendingApprovals.values.first

        let json: String
        switch decision {
        case "allow":  json = #"{"permissionDecision":"allow"}"#
        case "always": json = #"{"permissionDecision":"always"}"#
        case "ask":    json = #"{"permissionDecision":"ask"}"#
        default:       json = #"{"permissionDecision":"deny"}"#
        }

        if let item = item {
            let fd = item.fd
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: json)
                close(fd)
            }
        }

        // If there's another session waiting for approval, show it now
        if let next = pendingApprovals.values.first {
            state.pendingApproval = ApprovalInfo(
                sessionId: next.sessionId,
                projectName: next.projectName,
                tool: next.tool,
                command: next.command
            )
            state.isPinned = true
            state.updateTask(id: "integration_claude", state: .approval)
            expandIfNeeded(to: .approval)
        } else {
            state.pendingApproval = nil
            state.isPinned = false
            state.updateTask(id: "integration_claude", state: .working)
            clearPillBadge(id: "integration_claude")
            state.view = state.tasks.isEmpty ? .empty : .overview
        }
    }

    /// Updates integration_claude with the current session project name and cwd.
    @MainActor
    private func upsertTask(projectName: String, cwd: String = "") {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) else { return }
        state.tasks[idx].name = projectName
        if !cwd.isEmpty { state.tasks[idx].sessionCwd = cwd }
    }

    // MARK: - Badge helpers

    @MainActor
    private func setPillBadge(id: String, badge: PillBadge) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = badge
    }

    @MainActor
    private func clearPillBadge(id: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = nil
    }

    /// Resets integration_claude to idle, clears steps and project name.
    @MainActor
    private func clearSession() {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) else { return }
        state.tasks[idx].steps = []
        state.tasks[idx].stepIndex = 0
        state.tasks[idx].name = "Antigravity"
        state.tasks[idx].pillBadge = nil
    }

    @MainActor
    private func appendStep(id: String, step: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].steps.append(step)
        if state.tasks[idx].steps.count > 20 { state.tasks[idx].steps.removeFirst() }
        state.tasks[idx].stepIndex = state.tasks[idx].steps.count - 1
    }

    // MARK: - Project name alias mapping

    private func aliasProjectName(_ name: String) -> String {
        let aliases: [String: String] = [
            "notch-buddy":  "Notch Buddy",
            "notchbuddy":   "Notch Buddy",
            "notch_buddy":  "Notch Buddy",
        ]
        return aliases[name.lowercased()] ?? name
    }

    // MARK: - French step labels

    private func frenchStep(tool: String, input: [String: Any]) -> String {
        let labels: [String: String] = [
            // Claude Code
            "Bash":       "Exécute",
            "Read":       "Lit",
            "Write":      "Écrit",
            "Edit":       "Modifie",
            "Glob":       "Cherche",
            "Grep":       "Recherche",
            "WebSearch":  "Recherche web",
            "WebFetch":   "Récupère",
            "TodoWrite":  "Tâches",
            "Task":       "Agent",
            "LS":         "Liste",
            "MultiEdit":  "Modifie",
            "NotebookEdit": "Notebook",
            // Antigravity
            "run_command":          "Exécute",
            "view_file":            "Lit",
            "replace_file_content": "Modifie",
            "write_to_file":        "Écrit",
            "search_web":           "Recherche web",
            "read_url_content":     "Récupère",
            "ask_question":         "Question",
            "call_mcp_tool":        "Outil",
            "manage_task":          "Tâche",
            "schedule":             "Planifie",
            "invoke_subagent":      "Sous-agent",
        ]
        let label = labels[tool] ?? tool
        if let cmd = (input["command"] as? String) ?? (input["CommandLine"] as? String) {
            let short = String(cmd.prefix(40))
            return "\(label) · \(short)"
        } else if let path = (input["path"] as? String) ?? (input["AbsolutePath"] as? String) ?? (input["TargetFile"] as? String) {
            return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
        } else if let file = input["file_path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: file).lastPathComponent)"
        } else if let query = input["query"] as? String {
            return "\(label) · \(String(query.prefix(40)))"
        } else if let url = input["Url"] as? String {
            let host = URL(string: url)?.host ?? String(url.prefix(30))
            return "\(label) · \(host)"
        } else if let toolName = input["ToolName"] as? String {
            return "\(label) · \(toolName)"
        }
        return label
    }

    // MARK: - Logging

    private func nbLog(_ message: String) {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/NotchBuddy")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logFile = logsDir.appendingPathComponent("nb.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFile)
        }
    }

    private func sendLine(fd: Int32, text: String) {
        let bytes = Array((text + "\n").utf8)
        bytes.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = Darwin.send(fd, buffer.baseAddress! + sent, buffer.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    // MARK: - nb-hook script installation

    func installHookScript() {
        #if APPSTORE
        // In App Store mode the script is written during settings hook installation
        // (requires a security-scoped bookmark to ~/.claude chosen by the user)
        #else
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scriptURL = URL(fileURLWithPath: Self.hookScriptPath)
        try? nbHookScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755 as NSNumber],
            ofItemAtPath: scriptURL.path
        )
        #endif
    }

    // MARK: - Outdated hook detection

    /// Returns true if settings.json has a Coucou PermissionRequest hook with timeout < 120s.
    static func hooksNeedUpdate() -> Bool {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = settings["hooks"] as? [String: Any],
              let permReqHooks = hooks["PermissionRequest"] as? [[String: Any]] else {
            return false
        }
        for matcher in permReqHooks {
            if let hookList = matcher["hooks"] as? [[String: Any]] {
                for hook in hookList {
                    if let cmd = hook["command"] as? String,
                       (cmd.contains("NotchBuddy") || cmd.contains("coucou")),
                       let timeout = hook["timeout"] as? Int,
                       timeout < 120 {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Antigravity hooks.json installer

    static var geminiConfigDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/config")
    }

    static var geminiHooksURL: URL {
        geminiConfigDir.appendingPathComponent("hooks.json")
    }

    static func antigravityHooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: geminiHooksURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["coucou"] != nil
    }

    func installAntigravityHooks() throws {
        installHookScript()
        let hookPath = Self.hookScriptPath
        let dir = Self.geminiConfigDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var hooksConfig: [String: Any] = [:]
        if let data = try? Data(contentsOf: Self.geminiHooksURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            hooksConfig = parsed
        }

        let coucouHook: [String: Any] = [
            "PreInvocation": [
                ["type": "command", "command": "\"\(hookPath)\" PreInvocation", "timeout": 10]
            ],
            "PreToolUse": [
                ["matcher": "*", "hooks": [["type": "command", "command": "\"\(hookPath)\" PreToolUse", "timeout": 120]]]
            ],
            "PostToolUse": [
                ["matcher": "*", "hooks": [["type": "command", "command": "\"\(hookPath)\" PostToolUse", "timeout": 10]]]
            ],
            "Stop": [
                ["type": "command", "command": "\"\(hookPath)\" Stop", "timeout": 10]
            ]
        ]

        hooksConfig["coucou"] = coucouHook
        let data = try JSONSerialization.data(withJSONObject: hooksConfig, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Self.geminiHooksURL, options: .atomic)
    }

    func uninstallAntigravityHooks() throws {
        guard FileManager.default.fileExists(atPath: Self.geminiHooksURL.path) else { return }
        guard let data = try? Data(contentsOf: Self.geminiHooksURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json.removeValue(forKey: "coucou")
        let outData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: Self.geminiHooksURL, options: .atomic)
    }

    // MARK: - Claude Code settings.json hook installer

    private var _pendingHooksData: Data?

    /// Returns preview JSON without writing — call writeClaudeHooks() to confirm.
    func previewClaudeHooks() throws -> String {
        let data = try buildHooksData()
        _pendingHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Writes the hooks to disk (call after user confirms preview).
    func writeClaudeHooks() throws {
        guard let data = _pendingHooksData else { return }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        // Backup first
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.bak-\(stamp)")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
        _pendingHooksData = nil
    }

    private func buildHooksData() throws -> Data {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        let hookPath = Self.hookScriptPath
        #if APPSTORE
        // Sandboxed apps create quarantined files; /bin/sh bypasses the quarantine flag
        let quotedCmd = "/bin/sh \"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        #else
        let quotedCmd = "\"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        #endif
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 10), ("StopFailure", 10),
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("NotchBuddy") == true || ($0["command"] as? String)?.contains("coucou") == true } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    func uninstallClaudeHooks() throws {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return }

        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { matcher in
                    (matcher["hooks"] as? [[String: Any]])?.contains {
                        ($0["command"] as? String)?.contains("NotchBuddy") == true ||
                        ($0["command"] as? String)?.contains("coucou") == true
                    } ?? false
                }
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: settingsURL, options: .atomic)
    }

    // MARK: - App Store: hooks via security-scoped bookmark

    #if APPSTORE
    /// App Store variant — needs a security-scoped bookmark URL pointing to ~/.claude
    func previewClaudeHooksAppStore(claudeURL: URL) throws -> String {
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }
        let data = try buildHooksData(claudeURL: claudeURL)
        _pendingHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    func writeClaudeHooksAppStore(claudeURL: URL) throws {
        guard let data = _pendingHooksData else { return }
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }

        // Write the nb-hook script into ~/.claude/coucou/nb-hook
        let coucouDir = claudeURL.appendingPathComponent("coucou")
        try FileManager.default.createDirectory(at: coucouDir, withIntermediateDirectories: true)
        let scriptURL = coucouDir.appendingPathComponent("nb-hook")
        try nbHookScriptAppStore.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: scriptURL.path)

        // Write settings.json (with backup)
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let backupURL = claudeURL.appendingPathComponent("settings.json.bak-\(formatter.string(from: Date()))")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try data.write(to: settingsURL, options: .atomic)
        _pendingHooksData = nil
    }

    func uninstallClaudeHooksAppStore(claudeURL: URL) throws {
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return }
        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { matcher in
                    (matcher["hooks"] as? [[String: Any]])?.contains {
                        ($0["command"] as? String)?.contains("coucou") == true ||
                        ($0["command"] as? String)?.contains("NotchBuddy") == true
                    } ?? false
                }
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: settingsURL, options: .atomic)
    }

    private func buildHooksData(claudeURL: URL) throws -> Data {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        let hookPath = Self.hookScriptPath
        let quotedCmd = "/bin/sh \"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 10), ("StopFailure", 10),
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("coucou") == true ||
                ($0["command"] as? String)?.contains("NotchBuddy") == true
            } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }
    #endif
}

// MARK: - Notification names for hook server → controller communication

extension Notification.Name {
    static let hookExpand = Notification.Name("notchBuddy.hookExpand")
}

// MARK: - nb-hook Python script content

private let nbHookScript = """
#!/usr/bin/env python3
# nb-hook — Coucou hook relay for Claude Code and Antigravity
# Reads JSON from stdin, forwards to Coucou via Unix socket, translates response.
import sys, json, os, socket, re

SAFE_READONLY_SHELL_CMDS = {
    'ls', 'pwd', 'cat', 'head', 'tail', 'less', 'more',
    'which', 'whereis', 'type', 'file', 'stat',
    'grep', 'egrep', 'fgrep', 'rg', 'ag', 'wc',
    'find', 'tree', 'diff', 'cmp',
    'uname', 'whoami', 'id', 'date', 'uptime',
    'echo', 'printf', 'true', 'false', 'test', '['
}

SAFE_GIT_SUBCOMMANDS = {
    'status', 'diff', 'log', 'show', 'branch', 'rev-parse',
    'describe', 'tag', 'remote', 'config'
}

READ_ONLY_TOOLS = {
    'view_file', 'list_dir', 'grep_search', 'find_by_name',
    'read_url_content', 'search_web', 'read_resource',
    'list_resources', 'ask_question', 'schedule'
}

ALWAYS_ALLOWED_PATH = os.path.expanduser('~/Library/Application Support/NotchBuddy/always_allowed.json')

def is_always_allowed(cmd="", tool_name=""):
    try:
        if not os.path.exists(ALWAYS_ALLOWED_PATH):
            return False
        with open(ALWAYS_ALLOWED_PATH, 'r', encoding='utf-8') as f:
            allowed = json.load(f)
        if not isinstance(allowed, list):
            return False
        rules = set(str(r).strip() for r in allowed if r)
    except Exception:
        return False

    if tool_name:
        t = tool_name.strip()
        if t in rules or f"mcp({t})" in rules:
            return True
        if "/" in t:
            server = t.split("/")[0]
            if server in rules or f"mcp({server})" in rules:
                return True

    if cmd:
        cmd_clean = cmd.strip()
        if not cmd_clean:
            return False
        if cmd_clean in rules:
            return True

        words = cmd_clean.split()
        while words and "=" in words[0] and not words[0].startswith("-"):
            words.pop(0)
        if words:
            binary_full = words[0]
            binary_base = os.path.basename(binary_full).lower()
            if binary_full in rules or binary_base in rules:
                return True
            for i in range(1, len(words) + 1):
                prefix = " ".join(words[:i])
                if prefix in rules:
                    return True
                if i > 1:
                    prefix_base = " ".join([binary_base] + words[1:i])
                    if prefix_base in rules:
                        return True

        for r in rules:
            if not r:
                continue
            if cmd_clean == r or cmd_clean.startswith(r + " ") or cmd_clean.startswith(r + "\\t"):
                return True
            if (r.startswith("http://") or r.startswith("https://") or "/" in r or "." in r) and r in cmd_clean:
                return True

    return False

def save_always_allowed(cmd="", tool_name=""):
    try:
        os.makedirs(os.path.dirname(ALWAYS_ALLOWED_PATH), exist_ok=True)
        items = []
        if os.path.exists(ALWAYS_ALLOWED_PATH):
            try:
                with open(ALWAYS_ALLOWED_PATH, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    if isinstance(data, list):
                        items = data
            except Exception:
                items = []

        to_add = []
        if cmd:
            cmd_clean = cmd.strip()
            if cmd_clean and cmd_clean not in items:
                to_add.append(cmd_clean)
            words = cmd_clean.split()
            while words and "=" in words[0] and not words[0].startswith("-"):
                words.pop(0)
            if words:
                binary = os.path.basename(words[0])
                if binary and binary not in items and binary not in to_add:
                    to_add.append(binary)
                if len(words) >= 2:
                    prefix = f"{binary} {words[1]}"
                    if prefix not in items and prefix not in to_add:
                        to_add.append(prefix)
        if tool_name:
            t = tool_name.strip()
            if t and t not in items and t not in to_add:
                to_add.append(t)
            if "/" in t:
                mcp_full = f"mcp({t})"
                if mcp_full not in items and mcp_full not in to_add:
                    to_add.append(mcp_full)
                server = t.split("/")[0]
                mcp_srv = f"mcp({server})"
                if mcp_srv not in items and mcp_srv not in to_add:
                    to_add.append(mcp_srv)

        if to_add:
            items.extend(to_add)
            with open(ALWAYS_ALLOWED_PATH, "w", encoding="utf-8") as f:
                json.dump(items, f, indent=2, ensure_ascii=False)
    except Exception:
        pass

def is_major_destructive_command(cmd):
    if not cmd:
        return False
    cmd_lower = cmd.strip().lower()
    parts = re.split(r"[;&|]+", cmd_lower)
    for part in parts:
        part = part.strip()
        if not part:
            continue
        words = part.split()
        while words and "=" in words[0] and not words[0].startswith("-"):
            words.pop(0)
        if not words:
            continue
        binary = os.path.basename(words[0])
        if binary in ("sudo", "shutdown", "reboot"):
            return True
        if binary.startswith("mkfs"):
            return True
        if binary == "rm":
            args = words[1:]
            flags = "".join(x[1:] for x in args if x.startswith("-"))
            has_rf = ("r" in flags or "R" in flags) and "f" in flags
            targets = [a for a in args if not a.startswith("-")]
            if has_rf and any(t in ("/", "/*", "~", "$home", "/system", "/library") for t in targets):
                return True
        if binary == "dd" and any(a.startswith("if=") for a in words[1:]):
            return True
        if "sudo" in words or "shutdown" in words or "reboot" in words:
            return True
    return False

def is_sensitive_single_cmd(cmd_str):
    cmd_str = cmd_str.strip()
    if not cmd_str:
        return False

    cleaned_redirs = (
        cmd_str.replace('2>/dev/null', '')
               .replace('2>&1', '')
               .replace('1>/dev/null', '')
               .replace('&>/dev/null', '')
    )
    if '>' in cleaned_redirs:
        return True

    words = cmd_str.split()
    while words and '=' in words[0] and not words[0].startswith('-'):
        words.pop(0)
    if not words:
        return False

    binary = os.path.basename(words[0]).lower()

    if binary in SAFE_READONLY_SHELL_CMDS:
        if binary == 'find':
            if any(arg in ('-exec', '-execdir', '-delete') for arg in words):
                return True
        return False

    if binary == 'git':
        args = words[1:]
        subverb = None
        for arg in args:
            if not arg.startswith('-'):
                subverb = arg.lower()
                break
        if subverb in SAFE_GIT_SUBCOMMANDS:
            if subverb == 'branch' and any(a in ('-d', '-D', '-m', '-M') for a in args):
                return True
            if subverb == 'remote' and any(a in ('add', 'remove', 'rename', 'set-url') for a in args):
                return True
            if subverb == 'tag' and any(a in ('-d', '--delete') for a in args):
                return True
            return False
        return True

    return True

def is_sensitive_shell_command(cmd):
    if not cmd or not cmd.strip():
        return False
    parts = re.split(r'[;&|]+', cmd)
    for part in parts:
        part = part.strip()
        if not part:
            continue
        if is_sensitive_single_cmd(part):
            return True
    return False

def is_sensitive_mcp_tool(server, tool_name):
    s = server.lower()
    t = tool_name.lower()
    if s in ('context7', 'snyk'):
        return False
    if s == 'serena':
        serena_read = {
            'read_file', 'list_dir', 'find_file', 'search_for_pattern',
            'get_symbols_overview', 'find_symbol', 'find_referencing_symbols',
            'find_implementations', 'find_declaration', 'get_diagnostics_for_file',
            'read_memory', 'list_memories', 'get_current_config',
            'initial_instructions', 'onboarding'
        }
        return t not in serena_read
    if s == 'notion':
        if t.startswith('api-get-') or t.startswith('api-retrieve-') or t.startswith('api-list-'):
            return False
        return True

    read_prefixes = ('get', 'list', 'read', 'view', 'search', 'find', 'query', 'check')
    for p in read_prefixes:
        if t.startswith(p):
            return False
    return True

def check_antigravity_tool_approval(payload):
    tc = payload.get('toolCall') or {}
    tool = tc.get('name') or payload.get('tool_name') or ''
    args = tc.get('args') or payload.get('tool_input') or {}

    cmd_ident = ""
    tool_ident = tool

    if tool in ('run_command', 'Bash', 'Command'):
        cmd = args.get('CommandLine') or args.get('command') or ''
        cmd_ident = cmd
        is_bypass = (args.get('BypassSandbox') is True)

        if is_always_allowed(cmd=cmd):
            return False, cmd_ident, tool_ident
        if is_major_destructive_command(cmd):
            return True, cmd_ident, tool_ident
        if not is_sensitive_shell_command(cmd):
            return False, cmd_ident, tool_ident
        if not is_bypass:
            return False, cmd_ident, tool_ident
        return True, cmd_ident, tool_ident

    if tool in READ_ONLY_TOOLS:
        return False, cmd_ident, tool_ident

    if tool in ('manage_task', 'manage_subagents'):
        action = str(args.get('Action', '')).lower()
        if action in ('list', 'status'):
            return False, cmd_ident, tool_ident
        if is_always_allowed(tool_name=tool):
            return False, cmd_ident, tool_ident
        return True, cmd_ident, tool_ident

    if tool == 'call_mcp_tool':
        server = str(args.get('ServerName', '')).lower()
        tname = str(args.get('ToolName', ''))
        tool_ident = f"{server}/{tname}"
        if is_always_allowed(tool_name=tool_ident):
            return False, cmd_ident, tool_ident
        if not is_sensitive_mcp_tool(server, tname):
            return False, cmd_ident, tool_ident
        return True, cmd_ident, tool_ident

    target = args.get('TargetFile') or args.get('AbsolutePath') or ''
    cmd_ident = target
    if target and is_always_allowed(cmd=target, tool_name=tool):
        return False, cmd_ident, tool_ident
    if is_always_allowed(tool_name=tool):
        return False, cmd_ident, tool_ident

    sensitive_tools = {
        'write_to_file', 'replace_file_content', 'multi_replace_file_content',
        'apply_diff', 'generate_image', 'invoke_subagent', 'define_subagent',
        'send_message'
    }
    if tool in sensitive_tools:
        return True, cmd_ident, tool_ident

    return True, cmd_ident, tool_ident

def is_sensitive_antigravity_tool(payload):
    return check_antigravity_tool_approval(payload)[0]

def main():
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            return
        payload = json.loads(raw)
    except Exception:
        return

    # Project CWD resolution
    if 'workspacePaths' in payload and payload['workspacePaths']:
        payload['cwd'] = payload['workspacePaths'][0]
    elif 'cwd' not in payload or not payload['cwd']:
        payload['cwd'] = os.getcwd()

    event = payload.get('hook_event_name', '')
    if not event and len(sys.argv) > 1:
        event = sys.argv[1]
    payload['hook_event_name'] = event

    # Enrich with terminal / IDE context
    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', 'antigravity'))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', 'com.google.antigravity'))

    if event == 'PreInvocation' and ('prompt' not in payload or not payload['prompt']):
        t_path = payload.get('transcriptPath')
        if t_path and os.path.exists(t_path):
            try:
                with open(t_path, 'r', encoding='utf-8') as f:
                    for line in reversed(f.readlines()):
                        entry = json.loads(line)
                        if entry.get('source') == 'USER_EXPLICIT' or entry.get('type') == 'USER_INPUT':
                            content = entry.get('content', '')
                            if '<USER_REQUEST>' in content:
                                content = content.split('<USER_REQUEST>')[1].split('</USER_REQUEST>')[0].strip()
                            payload['prompt'] = content
                            break
            except Exception:
                pass

    is_antigravity = ('conversationId' in payload)

    socket_dir = os.path.expanduser('~/Library/Application Support/NotchBuddy')
    socket_path = os.path.join(socket_dir, 'nb.sock')

    # Claude Code: blocking approval flow for PermissionRequest (up to 115s)
    if event == 'PermissionRequest':
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(115)
            s.connect(socket_path)
            s.sendall(json.dumps(payload).encode() + b'\\n')
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk: break
                chunks.append(chunk)
                if 10 in chunk: break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'allow':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    print(json.dumps(out), flush=True)
                    sys.exit(0)
                elif decision == 'always':
                    suggestions = payload.get('permission_suggestions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    print(json.dumps(out), flush=True)
                    sys.exit(0)
                elif decision == 'deny':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    print(json.dumps(out), flush=True)
                    sys.exit(0)
        except Exception:
            pass
        sys.exit(0)

    # Antigravity PreToolUse approval or telemetry
    if is_antigravity and event == 'PreToolUse':
        must_prompt, cmd_ident, tool_ident = check_antigravity_tool_approval(payload)
        if not must_prompt:
            # Auto-allow immédiat: télémétrie fire-and-forget (0.3s)
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(0.3)
                s.connect(socket_path)
                s.sendall(json.dumps(payload).encode() + b'\\n')
                s.close()
            except Exception:
                pass
            print(json.dumps({"allow_tool": True}), flush=True)
            sys.exit(0)

        # Prompt Notch: ouverture socket 115s pour demander l'accord dans le Notch
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(115)
            s.connect(socket_path)
            s.sendall(json.dumps(payload).encode() + b'\\n')
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk: break
                chunks.append(chunk)
                if 10 in chunk: break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'always':
                    save_always_allowed(cmd=cmd_ident, tool_name=tool_ident)
                    print(json.dumps({"allow_tool": True}), flush=True)
                    sys.exit(0)
                elif decision == 'allow':
                    print(json.dumps({"allow_tool": True}), flush=True)
                    sys.exit(0)
                elif decision == 'deny':
                    print(json.dumps({"allow_tool": False, "deny_reason": "Action refusée depuis le Notch"}), flush=True)
                    sys.exit(0)
        except Exception:
            # Coucou ne répond pas / timeout / fermé : fail-open immédiat
            pass
        print(json.dumps({"allow_tool": True}), flush=True)
        sys.exit(0)

    # All other events (Antigravity & Claude Code): fire-and-forget (0.3s timeout, never blocks)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall(json.dumps(payload).encode() + b'\\n')
        s.close()
    except Exception:
        pass

    # Antigravity PreToolUse fallback (if somehow reached)
    if is_antigravity and event == 'PreToolUse':
        print(json.dumps({"allow_tool": True}), flush=True)
    else:
        print('{}', flush=True)
    sys.exit(0)

if __name__ == '__main__':
    main()
    sys.exit(0)
"""

// MARK: - nb-hook script for App Store (socket in sandboxed container)

private let nbHookScriptAppStore = """
#!/usr/bin/env python3
# nb-hook — Coucou (App Store) hook relay for Claude Code and Antigravity
# Socket lives inside the sandboxed container; script runs outside the sandbox.
import sys, json, os, socket, re

SAFE_READONLY_SHELL_CMDS = {
    'ls', 'pwd', 'cat', 'head', 'tail', 'less', 'more',
    'which', 'whereis', 'type', 'file', 'stat',
    'grep', 'egrep', 'fgrep', 'rg', 'ag', 'wc',
    'find', 'tree', 'diff', 'cmp',
    'uname', 'whoami', 'id', 'date', 'uptime',
    'echo', 'printf', 'true', 'false', 'test', '['
}

SAFE_GIT_SUBCOMMANDS = {
    'status', 'diff', 'log', 'show', 'branch', 'rev-parse',
    'describe', 'tag', 'remote', 'config'
}

READ_ONLY_TOOLS = {
    'view_file', 'list_dir', 'grep_search', 'find_by_name',
    'read_url_content', 'search_web', 'read_resource',
    'list_resources', 'ask_question', 'schedule'
}

ALWAYS_ALLOWED_PATH = os.path.expanduser('~/Library/Containers/fr.louisraille.Coucou/Data/Library/Application Support/NotchBuddy/always_allowed.json')

def is_always_allowed(cmd="", tool_name=""):
    try:
        if not os.path.exists(ALWAYS_ALLOWED_PATH):
            return False
        with open(ALWAYS_ALLOWED_PATH, 'r', encoding='utf-8') as f:
            allowed = json.load(f)
        if not isinstance(allowed, list):
            return False
        rules = set(str(r).strip() for r in allowed if r)
    except Exception:
        return False

    if tool_name:
        t = tool_name.strip()
        if t in rules or f"mcp({t})" in rules:
            return True
        if "/" in t:
            server = t.split("/")[0]
            if server in rules or f"mcp({server})" in rules:
                return True

    if cmd:
        cmd_clean = cmd.strip()
        if not cmd_clean:
            return False
        if cmd_clean in rules:
            return True

        words = cmd_clean.split()
        while words and "=" in words[0] and not words[0].startswith("-"):
            words.pop(0)
        if words:
            binary_full = words[0]
            binary_base = os.path.basename(binary_full).lower()
            if binary_full in rules or binary_base in rules:
                return True
            for i in range(1, len(words) + 1):
                prefix = " ".join(words[:i])
                if prefix in rules:
                    return True
                if i > 1:
                    prefix_base = " ".join([binary_base] + words[1:i])
                    if prefix_base in rules:
                        return True

        for r in rules:
            if not r:
                continue
            if cmd_clean == r or cmd_clean.startswith(r + " ") or cmd_clean.startswith(r + "\\t"):
                return True
            if (r.startswith("http://") or r.startswith("https://") or "/" in r or "." in r) and r in cmd_clean:
                return True

    return False

def save_always_allowed(cmd="", tool_name=""):
    try:
        os.makedirs(os.path.dirname(ALWAYS_ALLOWED_PATH), exist_ok=True)
        items = []
        if os.path.exists(ALWAYS_ALLOWED_PATH):
            try:
                with open(ALWAYS_ALLOWED_PATH, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    if isinstance(data, list):
                        items = data
            except Exception:
                items = []

        to_add = []
        if cmd:
            cmd_clean = cmd.strip()
            if cmd_clean and cmd_clean not in items:
                to_add.append(cmd_clean)
            words = cmd_clean.split()
            while words and "=" in words[0] and not words[0].startswith("-"):
                words.pop(0)
            if words:
                binary = os.path.basename(words[0])
                if binary and binary not in items and binary not in to_add:
                    to_add.append(binary)
                if len(words) >= 2:
                    prefix = f"{binary} {words[1]}"
                    if prefix not in items and prefix not in to_add:
                        to_add.append(prefix)
        if tool_name:
            t = tool_name.strip()
            if t and t not in items and t not in to_add:
                to_add.append(t)
            if "/" in t:
                mcp_full = f"mcp({t})"
                if mcp_full not in items and mcp_full not in to_add:
                    to_add.append(mcp_full)
                server = t.split("/")[0]
                mcp_srv = f"mcp({server})"
                if mcp_srv not in items and mcp_srv not in to_add:
                    to_add.append(mcp_srv)

        if to_add:
            items.extend(to_add)
            with open(ALWAYS_ALLOWED_PATH, "w", encoding="utf-8") as f:
                json.dump(items, f, indent=2, ensure_ascii=False)
    except Exception:
        pass

def is_major_destructive_command(cmd):
    if not cmd:
        return False
    cmd_lower = cmd.strip().lower()
    parts = re.split(r"[;&|]+", cmd_lower)
    for part in parts:
        part = part.strip()
        if not part:
            continue
        words = part.split()
        while words and "=" in words[0] and not words[0].startswith("-"):
            words.pop(0)
        if not words:
            continue
        binary = os.path.basename(words[0])
        if binary in ("sudo", "shutdown", "reboot"):
            return True
        if binary.startswith("mkfs"):
            return True
        if binary == "rm":
            args = words[1:]
            flags = "".join(x[1:] for x in args if x.startswith("-"))
            has_rf = ("r" in flags or "R" in flags) and "f" in flags
            targets = [a for a in args if not a.startswith("-")]
            if has_rf and any(t in ("/", "/*", "~", "$home", "/system", "/library") for t in targets):
                return True
        if binary == "dd" and any(a.startswith("if=") for a in words[1:]):
            return True
        if "sudo" in words or "shutdown" in words or "reboot" in words:
            return True
    return False

def is_sensitive_single_cmd(cmd_str):
    cmd_str = cmd_str.strip()
    if not cmd_str:
        return False

    cleaned_redirs = (
        cmd_str.replace('2>/dev/null', '')
               .replace('2>&1', '')
               .replace('1>/dev/null', '')
               .replace('&>/dev/null', '')
    )
    if '>' in cleaned_redirs:
        return True

    words = cmd_str.split()
    while words and '=' in words[0] and not words[0].startswith('-'):
        words.pop(0)
    if not words:
        return False

    binary = os.path.basename(words[0]).lower()

    if binary in SAFE_READONLY_SHELL_CMDS:
        if binary == 'find':
            if any(arg in ('-exec', '-execdir', '-delete') for arg in words):
                return True
        return False

    if binary == 'git':
        args = words[1:]
        subverb = None
        for arg in args:
            if not arg.startswith('-'):
                subverb = arg.lower()
                break
        if subverb in SAFE_GIT_SUBCOMMANDS:
            if subverb == 'branch' and any(a in ('-d', '-D', '-m', '-M') for a in args):
                return True
            if subverb == 'remote' and any(a in ('add', 'remove', 'rename', 'set-url') for a in args):
                return True
            if subverb == 'tag' and any(a in ('-d', '--delete') for a in args):
                return True
            return False
        return True

    return True

def is_sensitive_shell_command(cmd):
    if not cmd or not cmd.strip():
        return False
    parts = re.split(r'[;&|]+', cmd)
    for part in parts:
        part = part.strip()
        if not part:
            continue
        if is_sensitive_single_cmd(part):
            return True
    return False

def is_sensitive_mcp_tool(server, tool_name):
    s = server.lower()
    t = tool_name.lower()
    if s in ('context7', 'snyk'):
        return False
    if s == 'serena':
        serena_read = {
            'read_file', 'list_dir', 'find_file', 'search_for_pattern',
            'get_symbols_overview', 'find_symbol', 'find_referencing_symbols',
            'find_implementations', 'find_declaration', 'get_diagnostics_for_file',
            'read_memory', 'list_memories', 'get_current_config',
            'initial_instructions', 'onboarding'
        }
        return t not in serena_read
    if s == 'notion':
        if t.startswith('api-get-') or t.startswith('api-retrieve-') or t.startswith('api-list-'):
            return False
        return True

    read_prefixes = ('get', 'list', 'read', 'view', 'search', 'find', 'query', 'check')
    for p in read_prefixes:
        if t.startswith(p):
            return False
    return True

def check_antigravity_tool_approval(payload):
    tc = payload.get('toolCall') or {}
    tool = tc.get('name') or payload.get('tool_name') or ''
    args = tc.get('args') or payload.get('tool_input') or {}

    cmd_ident = ""
    tool_ident = tool

    if tool in ('run_command', 'Bash', 'Command'):
        cmd = args.get('CommandLine') or args.get('command') or ''
        cmd_ident = cmd
        is_bypass = (args.get('BypassSandbox') is True)

        if is_always_allowed(cmd=cmd):
            return False, cmd_ident, tool_ident
        if is_major_destructive_command(cmd):
            return True, cmd_ident, tool_ident
        if not is_sensitive_shell_command(cmd):
            return False, cmd_ident, tool_ident
        if not is_bypass:
            return False, cmd_ident, tool_ident
        return True, cmd_ident, tool_ident

    if tool in READ_ONLY_TOOLS:
        return False, cmd_ident, tool_ident

    if tool in ('manage_task', 'manage_subagents'):
        action = str(args.get('Action', '')).lower()
        if action in ('list', 'status'):
            return False, cmd_ident, tool_ident
        if is_always_allowed(tool_name=tool):
            return False, cmd_ident, tool_ident
        return True, cmd_ident, tool_ident

    if tool == 'call_mcp_tool':
        server = str(args.get('ServerName', '')).lower()
        tname = str(args.get('ToolName', ''))
        tool_ident = f"{server}/{tname}"
        if is_always_allowed(tool_name=tool_ident):
            return False, cmd_ident, tool_ident
        if not is_sensitive_mcp_tool(server, tname):
            return False, cmd_ident, tool_ident
        return True, cmd_ident, tool_ident

    target = args.get('TargetFile') or args.get('AbsolutePath') or ''
    cmd_ident = target
    if target and is_always_allowed(cmd=target, tool_name=tool):
        return False, cmd_ident, tool_ident
    if is_always_allowed(tool_name=tool):
        return False, cmd_ident, tool_ident

    sensitive_tools = {
        'write_to_file', 'replace_file_content', 'multi_replace_file_content',
        'apply_diff', 'generate_image', 'invoke_subagent', 'define_subagent',
        'send_message'
    }
    if tool in sensitive_tools:
        return True, cmd_ident, tool_ident

    return True, cmd_ident, tool_ident

def is_sensitive_antigravity_tool(payload):
    return check_antigravity_tool_approval(payload)[0]

def main():
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            return
        payload = json.loads(raw)
    except Exception:
        return

    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if 'cwd' not in payload or not payload['cwd']:
        payload['cwd'] = os.getcwd()

    event = payload.get('hook_event_name', '')
    is_antigravity = ('conversationId' in payload)
    socket_path = os.path.expanduser(
        '~/Library/Containers/fr.louisraille.Coucou/Data/Library/Application Support/NotchBuddy/nb.sock'
    )

    if event == 'PermissionRequest':
        # Block and wait for Coucou's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'allow':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'always':
                    # Let Claude Code persist the rule via updatedPermissions
                    suggestions = payload.get('permission_suggestions', [])
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'allow', 'updatedPermissions': suggestions}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                elif decision == 'deny':
                    out = {'hookSpecificOutput': {'hookEventName': 'PermissionRequest', 'decision': {'behavior': 'deny', 'message': 'Denied from Coucou'}}}
                    sys.stdout.write(json.dumps(out) + '\\n')
                    sys.stdout.flush()
                    sys.exit(0)
                # 'ask' or unknown: fall through → no output → Claude Code re-asks
        except Exception:
            pass
        # App unreachable, timed out, or no explicit decision — print nothing
        sys.exit(0)

    # Antigravity PreToolUse approval or telemetry
    if is_antigravity and event == 'PreToolUse':
        must_prompt, cmd_ident, tool_ident = check_antigravity_tool_approval(payload)
        if not must_prompt:
            # Auto-allow immédiat: télémétrie fire-and-forget (0.3s)
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(0.3)
                s.connect(socket_path)
                s.sendall((json.dumps(payload) + '\\n').encode())
                s.close()
            except Exception:
                pass
            print(json.dumps({"allow_tool": True}), flush=True)
            sys.exit(0)

        # Sensitive tool: blocking approval with Notch (up to 118s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response:
                try:
                    resp_obj = json.loads(response)
                    decision = resp_obj.get('permissionDecision', '')
                except Exception:
                    decision = ''
                if decision == 'always':
                    save_always_allowed(cmd=cmd_ident, tool_name=tool_ident)
                    print(json.dumps({"allow_tool": True}), flush=True)
                    sys.exit(0)
                elif decision == 'allow':
                    print(json.dumps({"allow_tool": True}), flush=True)
                    sys.exit(0)
                elif decision == 'deny':
                    print(json.dumps({"allow_tool": False, "deny_reason": "Action refusée depuis le Notch"}), flush=True)
                    sys.exit(0)
        except Exception:
            # Socket unreachable or timeout: fail-open (never hang Antigravity)
            pass
        print(json.dumps({"allow_tool": True}), flush=True)
        sys.exit(0)

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block Claude Code

    if is_antigravity and event == 'PreToolUse':
        print(json.dumps({"allow_tool": True}), flush=True)
    else:
        print('{}', flush=True)
    sys.exit(0)

if __name__ == '__main__':
    main()
    sys.exit(0)
"""
