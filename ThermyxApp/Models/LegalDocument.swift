import Foundation

/// A bundled legal document, parsed into blocks the app can lay out natively.
///
/// SwiftUI's built-in Markdown handling covers inline emphasis but not
/// headings, lists, tables, or rules — and these documents use all four. This
/// parses the subset the documents actually use, so the source of truth stays
/// a readable Markdown file that a lawyer can review outside the app.
struct LegalDocument: Identifiable, Equatable {
    enum Kind: String, CaseIterable, Identifiable, Hashable {
        case privacy
        case terms

        var id: String { rawValue }

        var title: String {
            switch self {
            case .privacy: return "Privacy Policy"
            case .terms: return "Terms of Service"
            }
        }

        var shortTitle: String {
            switch self {
            case .privacy: return "Privacy"
            case .terms: return "Terms"
            }
        }

        var resourceName: String {
            switch self {
            case .privacy: return "privacy-policy"
            case .terms: return "terms-of-service"
            }
        }
    }

    enum Block: Equatable, Identifiable {
        case title(String)
        case heading(String)
        case subheading(String)
        case paragraph(String)
        case bullet(String)
        case table(header: [String], rows: [[String]])
        case rule
        /// A paragraph typeset in all caps in the source, used for the
        /// warranty and liability clauses. Rendered as emphasised body rather
        /// than shouted, which is more readable and just as prominent.
        case legalese(String)

        var id: String {
            switch self {
            case .title(let t): return "t-\(t)"
            case .heading(let t): return "h-\(t)"
            case .subheading(let t): return "s-\(t)"
            case .paragraph(let t): return "p-\(t.prefix(40))-\(t.count)"
            case .bullet(let t): return "b-\(t.prefix(40))-\(t.count)"
            case .table(let header, let rows): return "tb-\(header.joined())-\(rows.count)"
            case .rule: return "rule-\(UUID().uuidString)"
            case .legalese(let t): return "l-\(t.prefix(40))-\(t.count)"
            }
        }
    }

    let kind: Kind
    let blocks: [Block]

    var id: String { kind.rawValue }

    // MARK: - Loading

    static func load(_ kind: Kind) -> LegalDocument {
        // A missing document renders a message rather than trapping: the rest
        // of the app, including the safety screens, must keep working.
        guard let url = Bundle.main.url(forResource: kind.resourceName, withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else {
            return LegalDocument(kind: kind, blocks: [
                .paragraph("This document could not be loaded. Please reinstall Thermyx, or contact us for a copy.")
            ])
        }
        return LegalDocument(kind: kind, blocks: parse(raw))
    }

    // MARK: - Parsing

    static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullet: [String] = []
        var tableHeader: [String] = []
        var tableRows: [[String]] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: " ")
            paragraph.removeAll()
            // A paragraph that is mostly capitals is a warranty or liability
            // clause; it keeps its prominence but not its shouting.
            let letters = text.filter(\.isLetter)
            let caps = letters.filter(\.isUppercase).count
            let isLegalese = !letters.isEmpty && Double(caps) / Double(letters.count) > 0.7
            blocks.append(isLegalese ? .legalese(text) : .paragraph(text))
        }

        // A bullet in the source wraps over several lines; every line after the
        // first belongs to the same bullet, not to a new paragraph.
        func flushBullet() {
            guard !bullet.isEmpty else { return }
            blocks.append(.bullet(bullet.joined(separator: " ")))
            bullet.removeAll()
        }

        func flushTable() {
            guard !tableHeader.isEmpty else { return }
            blocks.append(.table(header: tableHeader, rows: tableRows))
            tableHeader.removeAll()
            tableRows.removeAll()
        }

        func flushAll() {
            flushBullet()
            flushParagraph()
            flushTable()
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushAll()
                continue
            }

            if line.hasPrefix("|") {
                flushBullet()
                flushParagraph()
                let parts: [String] = line
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let cells: [String] = Array(parts.dropFirst().dropLast())
                // The |---|---| separator row carries no content.
                if cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } && !$0.isEmpty }) { continue }
                if tableHeader.isEmpty { tableHeader = cells } else { tableRows.append(cells) }
                continue
            } else {
                flushTable()
            }

            if line == "---" {
                flushAll()
                blocks.append(.rule)
            } else if line.hasPrefix("### ") {
                flushAll()
                blocks.append(.subheading(String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                flushAll()
                blocks.append(.heading(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flushAll()
                blocks.append(.title(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                flushBullet()
                flushParagraph()
                bullet.append(String(line.dropFirst(2)))
            } else if !bullet.isEmpty {
                bullet.append(line)
            } else {
                paragraph.append(line)
            }
        }
        flushAll()
        return blocks
    }
}

extension String {
    /// Inline Markdown emphasis, falling back to the plain string if the
    /// document contains something the parser does not understand.
    var thermyxInlineMarkdown: AttributedString {
        (try? AttributedString(
            markdown: self,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(self)
    }
}
