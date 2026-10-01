import Foundation
import SQLite3

// MARK: - Antigravity Budget Model

public struct AntigravityBudget: Equatable, Sendable {
    public var maxTokens: Int = 1_000_000
    public var currentTokens: Int = 0
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var percentage: Double = 0.0
    public var statusColor: String = "green" // green, purple, orange, red
    public var statusLabel: String = "Optimal"
    public var sessionId: String? = nil

    // Detailed breakdown
    public var rulesTokens: Int = 0
    public var skillsTokens: Int = 0
    public var mcpTokens: Int = 0
    public var thinkingTokens: Int = 0
    public var contentTokens: Int = 0

    public var isServerRunning: Bool = false
    public var lastUpdated: Date = .now

    public var formattedCurrent: String {
        formatCompact(currentTokens)
    }

    public var formattedMax: String {
        formatCompact(maxTokens)
    }

    public var formattedPercentage: String {
        String(format: "%.1f%%", percentage)
    }

    private func formatCompact(_ num: Int) -> String {
        if num >= 1_000_000 {
            return String(format: "%.1fM", Double(num) / 1_000_000.0)
        } else if num >= 1_000 {
            return String(format: "%.1fk", Double(num) / 1_000.0)
        }
        return "\(num)"
    }
}

// MARK: - Antigravity Context Service

public final class AntigravityContextService: @unchecked Sendable {
    public static let shared = AntigravityContextService()

    private var timer: DispatchSourceTimer?
    private let charsPerToken: Double = 3.8
    private let maxBudgetDefault: Int = 1_000_000
    private var isRefreshing: Bool = false

    private init() {}

    public func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        // Run immediately after 1s, then every 15s
        t.schedule(deadline: .now() + 1, repeating: 15)
        t.setEventHandler { [weak self] in
            self?.refresh()
        }
        t.resume()
        timer = t
    }

    public func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        // Option A: Try local HTTP server (http://127.0.0.1:3456/api/metrics)
        fetchFromServer { [weak self] serverBudget in
            guard let self else { return }
            if let serverBudget = serverBudget {
                DispatchQueue.main.async {
                    AppState.shared.antigravityBudget = serverBudget
                    self.isRefreshing = false
                }
            } else {
                // Option B: Native local extraction without server
                DispatchQueue.global(qos: .userInitiated).async {
                    let localBudget = self.extractNativeMetrics()
                    DispatchQueue.main.async {
                        if let localBudget = localBudget {
                            AppState.shared.antigravityBudget = localBudget
                        }
                        self.isRefreshing = false
                    }
                }
            }
        }
    }

    // MARK: - Server Fetch (Option A)

    private func fetchFromServer(completion: @escaping (AntigravityBudget?) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:3456/api/metrics") else {
            completion(nil)
            return
        }

        var req = URLRequest(url: url, timeoutInterval: 0.8)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, response, error in
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil)
                return
            }

            guard let budgetDict = json["budget"] as? [String: Any] else {
                completion(nil)
                return
            }

            var budget = AntigravityBudget()
            budget.isServerRunning = true
            budget.maxTokens = (budgetDict["max"] as? Int) ?? 1_000_000
            budget.currentTokens = (budgetDict["current"] as? Int) ?? 0
            budget.inputTokens = (budgetDict["input"] as? Int) ?? 0
            budget.outputTokens = (budgetDict["output"] as? Int) ?? 0
            budget.percentage = (budgetDict["percentage"] as? Double) ?? 0.0
            budget.statusColor = (budgetDict["statusColor"] as? String) ?? "green"
            budget.statusLabel = (budgetDict["statusLabel"] as? String) ?? "Optimal"

            if let sessionDict = json["session"] as? [String: Any] {
                budget.sessionId = sessionDict["id"] as? String
            }

            if let breakdown = json["breakdown"] as? [String: Any] {
                if let rules = breakdown["rules"] as? [String: Any] {
                    budget.rulesTokens = (rules["totalTokens"] as? Int) ?? 0
                }
                if let skills = breakdown["skills"] as? [String: Any] {
                    budget.skillsTokens = (skills["totalInPromptTokens"] as? Int) ?? 0
                }
                if let mcp = breakdown["mcp"] as? [String: Any] {
                    budget.mcpTokens = (mcp["totalInPromptTokens"] as? Int) ?? 0
                }
                if let history = breakdown["history"] as? [String: Any] {
                    budget.thinkingTokens = (history["thinkingTokens"] as? Int) ?? 0
                    budget.contentTokens = (history["contentTokens"] as? Int) ?? 0
                }
            }

            budget.lastUpdated = .now
            completion(budget)
        }.resume()
    }

    // MARK: - Native Extraction (Option B)

    private func extractNativeMetrics() -> AntigravityBudget? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let antigravityDir = home.appendingPathComponent(".gemini/antigravity")
        let convDir = antigravityDir.appendingPathComponent("conversations")
        let brainDir = antigravityDir.appendingPathComponent("brain")

        guard FileManager.default.fileExists(atPath: convDir.path) else {
            return nil
        }

        // 1. Find most recently modified conversation SQLite DB
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: convDir.path) else {
            return nil
        }

        let dbs = files.filter { $0.hasSuffix(".db") && !$0.contains("-shm") && !$0.contains("-wal") }
        guard !dbs.isEmpty else { return nil }

        var latestDbURL: URL? = nil
        var latestMtime: TimeInterval = 0

        for file in dbs {
            let fileURL = convDir.appendingPathComponent(file)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let modDate = attrs[.modificationDate] as? Date {
                let mtime = modDate.timeIntervalSince1970
                if mtime > latestMtime {
                    latestMtime = mtime
                    latestDbURL = fileURL
                }
            }
        }

        guard let dbURL = latestDbURL else { return nil }
        let convId = dbURL.deletingPathExtension().lastPathComponent

        // 2. Query SQLite for promptText (gen_metadata)
        let promptText = readPromptFromDb(at: dbURL.path) ?? ""
        let inputTokens = Int(round(Double(promptText.count) / charsPerToken))

        let rulesText = extractTag(from: promptText, tag: "user_rules")
        let skillsText = extractTag(from: promptText, tag: "skills")
        let mcpText = extractTag(from: promptText, tag: "mcp_servers")

        let rulesTokens = Int(round(Double(rulesText.count) / charsPerToken))
        let skillsTokens = Int(round(Double(skillsText.count) / charsPerToken))
        let mcpTokens = Int(round(Double(mcpText.count) / charsPerToken))

        // 3. Output tokens from transcript.jsonl
        let (outputTokens, contentTokens, thinkingTokens) = readTranscriptOutput(brainDir: brainDir, convId: convId)

        let totalTokens = inputTokens + outputTokens
        let percentage = (Double(totalTokens) / Double(maxBudgetDefault)) * 100.0

        var statusColor = "green"
        var statusLabel = "Optimal"
        if totalTokens > Int(Double(maxBudgetDefault) * 0.90) {
            statusColor = "red"
            statusLabel = "Critique (>90%)"
        } else if totalTokens > Int(Double(maxBudgetDefault) * 0.75) {
            statusColor = "orange"
            statusLabel = "Attention (>75%)"
        } else if totalTokens > Int(Double(maxBudgetDefault) * 0.50) {
            statusColor = "purple"
            statusLabel = "Modéré (>50%)"
        }

        var budget = AntigravityBudget()
        budget.maxTokens = maxBudgetDefault
        budget.currentTokens = totalTokens
        budget.inputTokens = inputTokens
        budget.outputTokens = outputTokens
        budget.percentage = percentage
        budget.statusColor = statusColor
        budget.statusLabel = statusLabel
        budget.sessionId = convId
        budget.rulesTokens = rulesTokens
        budget.skillsTokens = skillsTokens
        budget.mcpTokens = mcpTokens
        budget.thinkingTokens = thinkingTokens
        budget.contentTokens = contentTokens
        budget.isServerRunning = false
        budget.lastUpdated = .now

        return budget
    }

    private func readPromptFromDb(at path: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let query = "SELECT data FROM gen_metadata WHERE size > 5000 ORDER BY idx DESC LIMIT 1"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        if sqlite3_step(statement) == SQLITE_ROW {
            if let blob = sqlite3_column_blob(statement, 0) {
                let bytes = sqlite3_column_bytes(statement, 0)
                let data = Data(bytes: blob, count: Int(bytes))
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    private func readTranscriptOutput(brainDir: URL, convId: String) -> (total: Int, content: Int, thinking: Int) {
        let transcriptURL = brainDir
            .appendingPathComponent(convId)
            .appendingPathComponent(".system_generated")
            .appendingPathComponent("logs")
            .appendingPathComponent("transcript.jsonl")

        guard FileManager.default.fileExists(atPath: transcriptURL.path),
              let content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            return (0, 0, 0)
        }

        var contentChars = 0
        var thinkingChars = 0

        let lines = content.split(separator: "\n")
        for line in lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "PLANNER_RESPONSE" else {
                continue
            }

            if let c = json["content"] as? String {
                contentChars += c.count
            }
            if let t = json["thinking"] as? String {
                thinkingChars += t.count
            }
        }

        let contentTokens = Int(round(Double(contentChars) / charsPerToken))
        let thinkingTokens = Int(round(Double(thinkingChars) / charsPerToken))
        return (contentTokens + thinkingTokens, contentTokens, thinkingTokens)
    }

    private func extractTag(from text: String, tag: String) -> String {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard let openRange = text.range(of: open) else { return "" }
        let afterOpen = openRange.upperBound
        if let closeRange = text.range(of: close, range: afterOpen..<text.endIndex) {
            return String(text[afterOpen..<closeRange.lowerBound])
        }
        return String(text[afterOpen...])
    }
}
