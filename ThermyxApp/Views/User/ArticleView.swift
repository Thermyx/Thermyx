import AVFoundation
import SwiftUI
import UIKit

// MARK: - Reader preferences

/// How the reader looks: five colour themes, including sepia and a
/// yellow-on-black high-contrast one for low vision.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case night, dim, sepia, paper, contrast
    var id: String { rawValue }

    var label: String {
        switch self {
        case .night: return "Night"
        case .dim: return "Dim"
        case .sepia: return "Sepia"
        case .paper: return "Paper"
        case .contrast: return "Contrast"
        }
    }

    var background: Color {
        switch self {
        case .night: return .black
        case .dim: return Color(hex: 0x1B1C1F)
        case .sepia: return Color(hex: 0xF4ECD8)
        case .paper: return .white
        case .contrast: return .black
        }
    }

    var text: Color {
        switch self {
        case .night: return Color(hex: 0xF2F4F7)
        case .dim: return Color(hex: 0xE6E2DA)
        case .sepia: return Color(hex: 0x3B2F20)
        case .paper: return Color(hex: 0x111214)
        case .contrast: return Color(hex: 0xFFE45C)
        }
    }

    var muted: Color {
        switch self {
        case .night: return Color(hex: 0xA1A8B3)
        case .dim: return Color(hex: 0xA8A39A)
        case .sepia: return Color(hex: 0x6E5F49)
        case .paper: return Color(hex: 0x555B63)
        case .contrast: return .white
        }
    }

    var rule: Color {
        switch self {
        case .night: return Color(hex: 0x1C1E22)
        case .dim: return Color(hex: 0x2E3035)
        case .sepia: return Color(hex: 0xD9CDB1)
        case .paper: return Color(hex: 0xE3E5E8)
        case .contrast: return .white
        }
    }

    var panel: Color {
        switch self {
        case .night: return Color(hex: 0x0F1013)
        case .dim: return Color(hex: 0x24262A)
        case .sepia: return Color(hex: 0xEBE0C6)
        case .paper: return Color(hex: 0xF3F4F6)
        case .contrast: return Color(hex: 0x111111)
        }
    }

    var accent: Color {
        switch self {
        case .night, .dim: return Thermyx.Ink.ice
        case .sepia: return Color(hex: 0x9A4A12)
        case .paper: return Color(hex: 0x0B62A8)
        case .contrast: return Color(hex: 0x00E5FF)
        }
    }

    var isDark: Bool { self != .sepia && self != .paper }
}

enum ReaderTypeface: String, CaseIterable, Identifiable {
    case serif, sans
    var id: String { rawValue }
    var label: String { self == .serif ? "Serif" : "Sans" }
}

/// The reader's settings, kept across articles.
final class ReaderPreferences: ObservableObject {
    @AppStorage("reader.theme") var themeRaw = ReaderTheme.night.rawValue
    @AppStorage("reader.size") var size = 1.0
    @AppStorage("reader.typeface") var typefaceRaw = ReaderTypeface.serif.rawValue
    @AppStorage("reader.wide") var wide = false
    @AppStorage("reader.rate") var rate = Double(AVSpeechUtteranceDefaultSpeechRate)
    @AppStorage("reader.lineReader") var lineReader = false

    var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .night }
    var typeface: ReaderTypeface { ReaderTypeface(rawValue: typefaceRaw) ?? .serif }

    static let sizes: ClosedRange<Double> = 0.85...1.8

    func reset() {
        themeRaw = ReaderTheme.night.rawValue; size = 1; typefaceRaw = ReaderTypeface.serif.rawValue
        wide = false; rate = Double(AVSpeechUtteranceDefaultSpeechRate); lineReader = false
    }
}

// MARK: - Read aloud

/// Reads an article aloud, block by block, and says which block it's on so
/// the reader can highlight it and keep it in view.
@MainActor
final class ReaderSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var current: Int?
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false

    private let synthesizer = AVSpeechSynthesizer()
    private var segments: [(index: Int, text: String)] = []
    private var utterances: [ObjectIdentifier: Int] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// `segments` pairs a block index (−1 for the headline) with its text.
    func play(_ segments: [(index: Int, text: String)], rate: Double) {
        if isPaused { synthesizer.continueSpeaking(); isPaused = false; return }
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        self.segments = segments
        for segment in segments where !segment.text.isEmpty {
            let u = AVSpeechUtterance(string: segment.text)
            u.rate = Float(rate)
            u.postUtteranceDelay = 0.25
            u.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
            utterances[ObjectIdentifier(u)] = segment.index
            synthesizer.speak(u)
        }
        isSpeaking = true
    }

    func pause() {
        guard isSpeaking else { return }
        synthesizer.pauseSpeaking(at: .word)
        isPaused = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        utterances.removeAll()
        current = nil
        isSpeaking = false
        isPaused = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.current = self.utterances[id] }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard !self.synthesizer.isSpeaking else { return }
            self.current = nil
            self.isSpeaking = false
            self.isPaused = false
        }
    }
}

// MARK: - Article

/// One article, set like a newspaper feature: section kicker, headline,
/// standfirst, byline, photograph with credit, the story, and APA 7
/// references. The "Aa" panel sets size, colour, typeface and spacing; the
/// speaker reads it aloud; the line reader dims everything but a band.
struct ArticleView: View {
    let article: LearningArticle

    @Environment(\.dismiss) private var dismiss
    @StateObject private var prefs = ReaderPreferences()
    @StateObject private var speech = ReaderSpeech()
    @State private var showingSettings = false
    @ScaledMetric(relativeTo: .body) private var baseSize: CGFloat = 18

    private var theme: ReaderTheme { prefs.theme }
    private var bodySize: CGFloat { baseSize * prefs.size }
    private var lineGap: CGFloat { bodySize * (prefs.wide ? 0.62 : 0.42) }
    private var tracking: CGFloat { prefs.wide ? 0.6 : 0 }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                            .id(-1)
                            .modifier(SpokenHighlight(active: speech.current == -1, theme: theme))
                        photo
                            .padding(.top, 20)
                        VStack(alignment: .leading, spacing: bodySize * 0.9) {
                            ForEach(Array(article.blocks.enumerated()), id: \.offset) { index, block in
                                blockView(block)
                                    .id(index)
                                    .modifier(SpokenHighlight(active: speech.current == index, theme: theme))
                            }
                        }
                        .padding(.top, 24)
                        references
                            .padding(.top, 32)
                    }
                    .padding(.horizontal, Thermyx.Space.wide)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .onChange(of: speech.current) { _, index in
                    guard let index else { return }
                    withAnimation(SiteMotion.settle) { proxy.scrollTo(index, anchor: .center) }
                }
                .overlay {
                    if prefs.lineReader { LineReaderOverlay(theme: theme, bandHeight: bodySize * 3.6) }
                }
            }
        }
        .background(theme.background.ignoresSafeArea())
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingSettings) {
            ReaderSettingsSheet(prefs: prefs)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onDisappear { speech.stop() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 4) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                    Text("Learn").font(.custom(ThermyxFont.Family.medium, size: 17, relativeTo: .body))
                }
                .foregroundStyle(theme.accent)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Learn")
            Spacer()
            barButton(speech.isSpeaking && !speech.isPaused ? "pause.fill" : "speaker.wave.2",
                      label: speech.isSpeaking && !speech.isPaused ? "Pause reading aloud" : "Read aloud") {
                if speech.isSpeaking && !speech.isPaused { speech.pause() } else { speech.play(segments, rate: prefs.rate) }
            }
            .contextMenu {
                if speech.isSpeaking { Button("Stop reading", role: .destructive) { speech.stop() } }
            }
            barButton("text.line.first.and.arrowtriangle.forward", label: prefs.lineReader ? "Turn off line reader" : "Turn on line reader",
                      selected: prefs.lineReader) {
                withAnimation(SiteMotion.settle) { prefs.lineReader.toggle() }
            }
            barButton("textformat.size", label: "Text size and colour") { showingSettings = true }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .background(theme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.rule).frame(height: 1) }
    }

    private func barButton(_ symbol: String, label: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(selected ? theme.background : theme.text)
                .frame(width: 44, height: 44)
                .background(selected ? theme.accent : .clear, in: Circle().inset(by: 4))
                .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
    }

    /// What the narrator reads: headline and standfirst, then each block.
    private var segments: [(index: Int, text: String)] {
        [(-1, "\(article.title). \(article.dek)")] + article.blocks.enumerated().map { ($0.offset, Self.speakable($0.element.spoken)) }
    }

    /// Citations aren't read aloud: "(Charkoudian, 2003)" interrupts the
    /// sentence and they're listed at the end.
    static func speakable(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s?\([^()]*(\d{4}|n\.d\.)[^()]*\)"#, with: "", options: .regularExpression)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(article.section.label.uppercased())
                .font(.custom(ThermyxFont.Family.semibold, size: 12, relativeTo: .caption))
                .tracking(1.4)
                .foregroundStyle(theme == .contrast ? theme.accent : article.section.tint)
                .padding(.top, 18)
            Text(article.title)
                .font(face(bodySize * 1.75, weight: .bold))
                .tracking(prefs.typeface == .sans ? -0.6 : -0.3)
                .lineSpacing(2)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(article.dek)
                .font(face(bodySize * 1.08, italic: prefs.typeface == .serif))
                .lineSpacing(lineGap * 0.6)
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Thermyx Learn")
                    .font(.custom(ThermyxFont.Family.semibold, size: 13, relativeTo: .caption))
                    .foregroundStyle(theme.text)
                Text("· \(article.meta) · \(article.references.count) sources")
                    .font(.custom(ThermyxFont.Family.regular, size: 13, relativeTo: .caption))
                    .foregroundStyle(theme.muted)
            }
            .padding(.top, 2)
            // On every lesson, as the brief requires.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                Text("Educational, not a medical diagnosis tool. In an emergency, call 911.")
                    .font(.custom(ThermyxFont.Family.medium, size: 13, relativeTo: .caption))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(theme == .contrast ? theme.text : Thermyx.Ink.amber)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private var photo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(article.image.asset)
                .resizable()
                .scaledToFill()
                .frame(height: 230)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel(article.image.alt)
            VStack(alignment: .leading, spacing: 2) {
                Text(article.image.caption)
                    .font(.custom(ThermyxFont.Family.regular, size: 13, relativeTo: .caption))
                    .foregroundStyle(theme.muted)
                if let credit = PhotoCredit.for(article.image.asset) {
                    Text(credit.line)
                        .font(.custom(ThermyxFont.Family.medium, size: 11, relativeTo: .caption2))
                        .foregroundStyle(theme.muted.opacity(0.85))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Blocks

    @ViewBuilder
    private func blockView(_ block: LearningArticle.Block) -> some View {
        switch block.type {
        case .lede:
            lede(block.text ?? "")
        case .p:
            styled(block.text ?? "")
                .font(face(bodySize))
                .tracking(tracking)
                .lineSpacing(lineGap)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
        case .h:
            Text(block.text ?? "")
                .font(face(bodySize * 1.25, weight: .bold))
                .foregroundStyle(theme.text)
                .padding(.top, bodySize * 0.4)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        case .quote:
            HStack(alignment: .top, spacing: 14) {
                Rectangle().fill(Thermyx.Ink.ember).frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    Text("“\(block.text ?? "")”")
                        .font(face(bodySize * 1.45, weight: .semibold, italic: prefs.typeface == .serif))
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let source = block.source {
                        Text(source.uppercased())
                            .font(.custom(ThermyxFont.Family.semibold, size: 11, relativeTo: .caption2))
                            .tracking(1.1)
                            .foregroundStyle(theme.muted)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        case .steps:
            VStack(alignment: .leading, spacing: 12) {
                if let title = block.title {
                    Text(title)
                        .font(.custom(ThermyxFont.Family.semibold, size: bodySize * 0.9, relativeTo: .headline))
                        .foregroundStyle(theme.text)
                }
                ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(i + 1)")
                            .font(.custom(ThermyxFont.Family.monoMedium, size: bodySize * 0.8, relativeTo: .body))
                            .foregroundStyle(theme.accent)
                            .frame(minWidth: 18, alignment: .leading)
                        styled(item)
                            .font(face(bodySize * 0.95))
                            .tracking(tracking)
                            .lineSpacing(lineGap * 0.8)
                            .foregroundStyle(theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.rule, lineWidth: 1) }
        case .list:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(theme.accent).frame(width: 6, height: 6).offset(y: -bodySize * 0.18)
                        listItem(item)
                    }
                }
            }
        case .fact:
            VStack(alignment: .leading, spacing: 4) {
                Text(block.figure ?? "")
                    .font(.custom(ThermyxFont.Family.semibold, size: bodySize * 2.8, relativeTo: .largeTitle))
                    .tracking(-1.5)
                    .foregroundStyle(theme == .contrast ? theme.text : Thermyx.Ink.ember)
                Text(block.text ?? "")
                    .font(face(bodySize * 1.05, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let source = block.source {
                    Text(source)
                        .font(.custom(ThermyxFont.Family.regular, size: 12, relativeTo: .caption))
                        .foregroundStyle(theme.muted)
                }
            }
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Rectangle().fill(theme.rule).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(theme.rule).frame(height: 1) }
            .accessibilityElement(children: .combine)
        case .note:
            VStack(alignment: .leading, spacing: 6) {
                if let title = block.title {
                    Text(title)
                        .font(.custom(ThermyxFont.Family.semibold, size: bodySize * 0.85, relativeTo: .headline))
                        .foregroundStyle(theme == .contrast ? theme.text : Thermyx.Ink.amber)
                }
                styled(block.text ?? "")
                    .font(face(bodySize * 0.92))
                    .lineSpacing(lineGap * 0.8)
                    .foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme == .contrast ? theme.panel : Thermyx.Ink.amber.opacity(theme.isDark ? 0.10 : 0.14),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Thermyx.Ink.amber.opacity(0.4), lineWidth: 1) }
        }
    }

    /// The opening paragraph: a size up, its first sentence in bold.
    private func lede(_ text: String) -> some View {
        let split = Self.firstSentence(text)
        return (Text(split.first).fontWeight(.bold) + styled(split.rest))
            .font(face(bodySize * 1.12))
            .tracking(tracking)
            .lineSpacing(lineGap)
            .foregroundStyle(theme.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "Heat cramps: muscle pain…" with the term before the colon in bold.
    private func listItem(_ item: String) -> some View {
        let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
        let text = parts.count == 2 && parts[0].count < 28
            ? Text(parts[0] + ":").fontWeight(.semibold) + styled(parts[1])
            : styled(item)
        return text
            .font(face(bodySize * 0.95))
            .tracking(tracking)
            .lineSpacing(lineGap * 0.8)
            .foregroundStyle(theme.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func firstSentence(_ text: String) -> (first: String, rest: String) {
        guard let range = text.range(of: #"(?<=[a-z0-9)%])\. (?=[A-Z])"#, options: .regularExpression) else { return (text, "") }
        return (String(text[..<range.upperBound]), String(text[range.upperBound...]))
    }

    /// Body text with its citations set quieter, so "(Casa et al., 2015)"
    /// reads as a reference, not part of the sentence.
    private func styled(_ text: String) -> Text {
        let pattern = #"\([^()]*(\d{4}|n\.d\.)[^()]*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return Text(text) }
        let ns = text as NSString
        var result = Text("")
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                result = result + Text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            result = result + Text(ns.substring(with: match.range)).foregroundColor(theme.muted)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { result = result + Text(ns.substring(from: cursor)) }
        return result
    }

    private func face(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        switch prefs.typeface {
        case .serif:
            let font = Font.system(size: size, weight: weight, design: .serif)
            return italic ? font.italic() : font
        case .sans:
            let name: String
            switch weight {
            case .bold, .heavy, .black: name = ThermyxFont.Family.bold
            case .semibold: name = ThermyxFont.Family.semibold
            case .medium: name = ThermyxFont.Family.medium
            default: name = ThermyxFont.Family.regular
            }
            return .custom(name, size: size)
        }
    }

    // MARK: References

    private var references: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("References")
                .font(face(bodySize * 1.1, weight: .bold))
                .foregroundStyle(theme.text)
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)
            ForEach(article.references, id: \.self) { reference in
                ReferenceText(apa: reference, size: bodySize * 0.82, theme: theme, serif: prefs.typeface == .serif)
            }
            Text("Thermyx Learn is educational and is not a medical diagnosis tool. Talk to a clinician about your own health.")
                .font(.custom(ThermyxFont.Family.regular, size: 12, relativeTo: .caption))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .overlay(alignment: .top) { Rectangle().fill(theme.rule).frame(height: 1) }
    }
}

/// Tints the block being read aloud.
private struct SpokenHighlight: ViewModifier {
    let active: Bool
    let theme: ReaderTheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, active ? 8 : 0)
            .background(active ? theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, active ? -8 : 0)
            .animation(SiteMotion.settle, value: active)
    }
}

// MARK: - Line reader

/// Dims the page except for a band of a few lines, which can be dragged.
/// Helps readers who lose their place.
private struct LineReaderOverlay: View {
    let theme: ReaderTheme
    let bandHeight: CGFloat

    @State private var centre: CGFloat?
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let h = proxy.size.height
            let c = min(max((centre ?? h * 0.42) + drag, bandHeight / 2), h - bandHeight / 2)
            let dim = theme.background.opacity(theme == .contrast ? 0.85 : 0.72)
            ZStack(alignment: .top) {
                dim.frame(height: max(0, c - bandHeight / 2))
                dim.frame(height: max(0, h - c - bandHeight / 2)).offset(y: c + bandHeight / 2)
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.accent.opacity(0.7), lineWidth: 1.5)
                    .frame(height: bandHeight)
                    .offset(y: c - bandHeight / 2)
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.accent)
                            .frame(width: 30, height: 22)
                            .background(theme.panel, in: Capsule())
                            .offset(x: -8, y: c - bandHeight / 2 - 11)
                    }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($drag) { value, state, _ in state = value.translation.height }
                    .onEnded { value in centre = min(max((centre ?? h * 0.42) + value.translation.height, bandHeight / 2), h - bandHeight / 2) }
            )
            .allowsHitTesting(true)
        }
        .accessibilityHidden(true)
        .transition(.opacity)
    }
}

// MARK: - References text

/// An APA reference: hanging indent, italics from `*asterisks*`, and a
/// tappable DOI or URL. UIKit, because SwiftUI's Text can't hang an indent.
private struct ReferenceText: UIViewRepresentable {
    let apa: String
    let size: CGFloat
    let theme: ReaderTheme
    let serif: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = [.link]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.attributedText = attributed
        view.linkTextAttributes = [.foregroundColor: UIColor(theme.accent)]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fit.height))
    }

    private var attributed: NSAttributedString {
        let base = baseFont
        let italic = base.fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: size) } ?? base
        let style = NSMutableParagraphStyle()
        style.headIndent = 24
        style.firstLineHeadIndent = 0
        style.lineSpacing = 2
        let out = NSMutableAttributedString()
        // Split on asterisks: odd pieces are italic.
        for (i, piece) in apa.components(separatedBy: "*").enumerated() {
            out.append(NSAttributedString(string: piece, attributes: [
                .font: i % 2 == 1 ? italic : base,
                .foregroundColor: UIColor(theme.text),
                .paragraphStyle: style,
            ]))
        }
        return out
    }

    private var baseFont: UIFont {
        if serif, let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return UIFont(name: ThermyxFont.Family.regular, size: size) ?? .systemFont(ofSize: size)
    }
}

// MARK: - Settings sheet

/// "Aa": size, colour theme, typeface, spacing, narration speed, line reader.
private struct ReaderSettingsSheet: View {
    @ObservedObject var prefs: ReaderPreferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Reading")
                    .font(ThermyxFont.displaySmall)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .padding(.top, 20)

                VStack(alignment: .leading, spacing: 8) {
                    label("Text size")
                    HStack(spacing: 12) {
                        Image(systemName: "textformat.size.smaller").foregroundStyle(Thermyx.Ink.textMuted)
                        Slider(value: $prefs.size, in: ReaderPreferences.sizes, step: 0.05)
                            .tint(Thermyx.Ink.signal)
                            .accessibilityLabel("Text size")
                            .accessibilityValue("\(Int((prefs.size * 100).rounded())) percent")
                        Image(systemName: "textformat.size.larger").foregroundStyle(Thermyx.Ink.textMuted)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    label("Colours")
                    HStack(spacing: 10) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Button {
                                prefs.themeRaw = theme.rawValue
                            } label: {
                                VStack(spacing: 6) {
                                    Text("Aa")
                                        .font(.system(size: 20, weight: .semibold, design: .serif))
                                        .foregroundStyle(theme.text)
                                        .frame(width: 54, height: 54)
                                        .background(theme.background, in: Circle())
                                        .overlay {
                                            Circle().strokeBorder(prefs.theme == theme ? Thermyx.Ink.ice : Thermyx.Tint.neutralBorder,
                                                                  lineWidth: prefs.theme == theme ? 2.5 : 1)
                                        }
                                    Text(theme.label)
                                        .font(ThermyxFont.captionSmall)
                                        .foregroundStyle(prefs.theme == theme ? Thermyx.Ink.textPrimary : Thermyx.Ink.textMuted)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(theme.label) colours")
                            .accessibilityAddTraits(prefs.theme == theme ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }

                HStack {
                    label("Typeface")
                    Spacer()
                    ThermyxSegmentedControl(options: ReaderTypeface.allCases, label: \.label,
                                            selection: Binding(get: { prefs.typeface }, set: { prefs.typefaceRaw = $0.rawValue }))
                        .fixedSize()
                }

                Toggle(isOn: $prefs.wide) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wider spacing").font(ThermyxFont.body).foregroundStyle(Thermyx.Ink.textPrimary)
                        Text("More room between letters and lines. Some readers with dyslexia find it easier.")
                            .font(ThermyxFont.captionSmall).foregroundStyle(Thermyx.Ink.textMuted)
                    }
                }
                .tint(Thermyx.Ink.signal)

                Toggle(isOn: $prefs.lineReader) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Line reader").font(ThermyxFont.body).foregroundStyle(Thermyx.Ink.textPrimary)
                        Text("Dims the page except a band you can drag, to keep your place.")
                            .font(ThermyxFont.captionSmall).foregroundStyle(Thermyx.Ink.textMuted)
                    }
                }
                .tint(Thermyx.Ink.signal)

                VStack(alignment: .leading, spacing: 8) {
                    label("Reading-aloud speed")
                    HStack(spacing: 12) {
                        Image(systemName: "tortoise").foregroundStyle(Thermyx.Ink.textMuted)
                        Slider(value: $prefs.rate, in: Double(AVSpeechUtteranceMinimumSpeechRate + 0.2)...Double(AVSpeechUtteranceDefaultSpeechRate + 0.15))
                            .tint(Thermyx.Ink.signal)
                            .accessibilityLabel("Reading-aloud speed")
                        Image(systemName: "hare").foregroundStyle(Thermyx.Ink.textMuted)
                    }
                    Text("Takes effect the next time you press play.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                }

                Button("Reset to defaults") { prefs.reset() }
                    .buttonStyle(ThermyxSecondaryButtonStyle())
            }
            .padding(.horizontal, Thermyx.Space.wide)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .thermyxSheetBackground()
        .preferredColorScheme(.dark)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(ThermyxFont.sectionTitle)
            .foregroundStyle(Thermyx.Ink.textPrimary)
    }
}
