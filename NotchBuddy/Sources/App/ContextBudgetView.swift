import SwiftUI

// MARK: - Budget Colors Extension

extension AntigravityBudget {
    var accentColor: Color {
        switch statusColor.lowercased() {
        case "red": return Color(hex: "#F4505E")
        case "orange": return Color(hex: "#F29B38")
        case "purple": return Color(hex: "#A78BFA")
        default: return Color(hex: "#22C55E")
        }
    }
}

// MARK: - Context Budget Header Pill

struct ContextBudgetPill: View {
    let budget: AntigravityBudget
    @State private var isHovered = false
    @State private var showingPopover = false

    var body: some View {
        Button(action: { showingPopover.toggle() }) {
            HStack(spacing: 5) {
                Circle()
                    .fill(budget.accentColor)
                    .frame(width: 6, height: 6)

                Text(budget.formattedCurrent)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))

                Text("\(Int(budget.percentage))%")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(Color(hex: "#8E939C"))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isHovered ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
            )
            .overlay(
                Capsule()
                    .stroke(isHovered ? Color.white.opacity(0.20) : Color.white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            ContextBudgetPopover(budget: budget)
        }
        .help("Budget de contexte Antigravity (\(budget.formattedCurrent) / \(budget.formattedMax))")
    }
}

// MARK: - Context Budget Popover

struct ContextBudgetPopover: View {
    let budget: AntigravityBudget

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(budget.accentColor)

                Text("Context Budget")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(hex: "#F5F6F8"))

                Spacer()

                Text(budget.statusLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(budget.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(budget.accentColor.opacity(0.15))
                    .clipShape(Capsule())
            }

            // Progress bar
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 6)

                        Capsule()
                            .fill(budget.accentColor)
                            .frame(width: max(6, geo.size.width * CGFloat(min(1.0, budget.percentage / 100.0))), height: 6)
                    }
                }
                .frame(height: 6)

                HStack {
                    Text("\(budget.formattedCurrent) used")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                    Spacer()
                    Text("\(budget.formattedMax) max (\(budget.formattedPercentage))")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                }
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // Breakdown
            VStack(spacing: 6) {
                BudgetMetricRow(label: "Prompt & Système", value: formatNumber(budget.inputTokens), detail: "Règles, skills, MCP")
                if budget.rulesTokens > 0 || budget.skillsTokens > 0 {
                    HStack(spacing: 8) {
                        if budget.rulesTokens > 0 {
                            SubMetricTag(label: "Rules", count: formatCompact(budget.rulesTokens))
                        }
                        if budget.skillsTokens > 0 {
                            SubMetricTag(label: "Skills", count: formatCompact(budget.skillsTokens))
                        }
                        if budget.mcpTokens > 0 {
                            SubMetricTag(label: "MCP", count: formatCompact(budget.mcpTokens))
                        }
                    }
                    .padding(.leading, 12)
                }

                BudgetMetricRow(label: "Génération & Réponses", value: formatNumber(budget.outputTokens), detail: "Contenu produit")
                if budget.thinkingTokens > 0 {
                    HStack(spacing: 8) {
                        SubMetricTag(label: "Thinking", count: formatCompact(budget.thinkingTokens))
                        if budget.contentTokens > 0 {
                            SubMetricTag(label: "Contenu", count: formatCompact(budget.contentTokens))
                        }
                    }
                    .padding(.leading, 12)
                }
            }

            // Footer Actions
            HStack(spacing: 8) {
                Button(action: {
                    if let url = URL(string: "http://127.0.0.1:3456") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 10))
                        Text("Dashboard")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: {
                    AntigravityContextService.shared.refresh()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .padding(5)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Actualiser le budget")
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 260)
        .background(Color(hex: "#16181D"))
    }

    private func formatNumber(_ num: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: num)) ?? "\(num)"
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

// MARK: - Subcomponents

struct BudgetMetricRow: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Color(hex: "#C5C8CD"))
            }
            Spacer()
            Text(value)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
        }
    }
}

struct SubMetricTag: View {
    let label: String
    let count: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundColor(Color(hex: "#8E939C"))
            Text(count)
                .foregroundColor(Color(hex: "#C5C8CD"))
                .fontWeight(.medium)
        }
        .font(.system(size: 9.5))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Integration Card Section

struct ContextBudgetCardSection: View {
    let budget: AntigravityBudget

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle()
                    .fill(budget.accentColor)
                    .frame(width: 5, height: 5)

                Text("Context Budget")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#C5C8CD"))

                Spacer()

                Text("\(budget.formattedCurrent) / \(budget.formattedMax) (\(Int(budget.percentage))%)")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#8E939C"))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 3.5)

                    Capsule()
                        .fill(budget.accentColor)
                        .frame(width: max(4, geo.size.width * CGFloat(min(1.0, budget.percentage / 100.0))), height: 3.5)
                }
            }
            .frame(height: 3.5)
        }
        .padding(.leading, 108)
        .padding(.trailing, 24)
        .padding(.top, 4)
    }
}
