#if canImport(SwiftUI)
import Foundation
import SwiftUI

public struct IntatisUserInputOptionPresentation: Identifiable, Equatable,
    Sendable
{
    public let label: String
    public let description: String

    public var id: String { label }

    public init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

public struct IntatisUserInputQuestionPresentation: Identifiable, Equatable,
    Sendable
{
    public let id: String
    public let question: String
    public let options: [IntatisUserInputOptionPresentation]
    public let allowsOther: Bool

    public init(
        id: String,
        question: String,
        options: [IntatisUserInputOptionPresentation],
        allowsOther: Bool
    ) {
        self.id = id
        self.question = question
        self.options = options
        self.allowsOther = allowsOther
    }
}

/// Request-local presentation state for the official structured-question
/// callback. The opaque `id` is only used to bind the visible response to the
/// live host continuation; it is not rendered or persisted by SharedUI.
public struct IntatisUserInputPresentation: Identifiable, Equatable, Sendable {
    public let id: String
    public let requesterName: String?
    public let questions: [IntatisUserInputQuestionPresentation]

    public init(
        id: String,
        requesterName: String? = nil,
        questions: [IntatisUserInputQuestionPresentation]
    ) {
        self.id = id
        self.requesterName = requesterName
        self.questions = questions
    }
}

public struct IntatisUserInputSubmission: Equatable, Sendable {
    public let requestID: String
    public let answers: [String: [String]]

    public init(requestID: String, answers: [String: [String]]) {
        self.requestID = requestID
        self.answers = answers
    }
}

enum IntatisUserInputSelection: Equatable, Hashable, Sendable {
    case option(String)
    case other
}

struct IntatisUserInputDraft: Equatable, Sendable {
    private(set) var selections: [String: IntatisUserInputSelection] = [:]
    private(set) var otherAnswers: [String: String] = [:]

    func selection(for questionID: String) -> IntatisUserInputSelection? {
        selections[questionID]
    }

    mutating func setSelection(
        _ selection: IntatisUserInputSelection?,
        for questionID: String
    ) {
        selections[questionID] = selection
    }

    func otherAnswer(for questionID: String) -> String {
        otherAnswers[questionID] ?? ""
    }

    mutating func setOtherAnswer(_ answer: String, for questionID: String) {
        otherAnswers[questionID] = answer
    }

    func submission(
        for presentation: IntatisUserInputPresentation
    ) -> IntatisUserInputSubmission? {
        var answers: [String: [String]] = [:]
        for question in presentation.questions {
            guard let selection = selections[question.id] else { return nil }
            switch selection {
            case .option(let label):
                guard question.options.contains(where: {
                    $0.label == label
                }) else {
                    return nil
                }
                answers[question.id] = [label]
            case .other:
                guard question.allowsOther else { return nil }
                let answer = otherAnswer(for: question.id)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !answer.isEmpty else { return nil }
                answers[question.id] = [answer]
            }
        }
        guard answers.count == presentation.questions.count,
              !answers.isEmpty else {
            return nil
        }
        return IntatisUserInputSubmission(
            requestID: presentation.id,
            answers: answers)
    }
}

/// Compact native question surface used immediately above the ordinary
/// composer. Each official question uses one native single-selection list of
/// numbered full-row choices; the pinned Codex tool describes its options as
/// mutually exclusive. `Other…` is the official free-form alternative.
public struct IntatisUserInputView: View {
    private let presentation: IntatisUserInputPresentation
    private let onSubmit: ((IntatisUserInputSubmission) -> Void)?
    @State private var draft = IntatisUserInputDraft()
    @State private var activeQuestionIndex = 0

    public init(
        presentation: IntatisUserInputPresentation,
        onSubmit: ((IntatisUserInputSubmission) -> Void)?
    ) {
        self.presentation = presentation
        self.onSubmit = onSubmit
    }

    public var body: some View {
        Group {
            if let question = activeQuestion {
                questionContainer(question)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .accessibilityIdentifier("user-input.request")
    }

    private var cleanedRequesterName: String? {
        guard let requesterName = presentation.requesterName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !requesterName.isEmpty else {
            return nil
        }
        return requesterName
    }

    private var activeQuestion: IntatisUserInputQuestionPresentation? {
        guard presentation.questions.indices.contains(activeQuestionIndex)
        else { return nil }
        return presentation.questions[activeQuestionIndex]
    }

    private func questionContainer(
        _ question: IntatisUserInputQuestionPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let requesterName = cleanedRequesterName {
                    Text(requesterName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("user-input.requester")
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(question.question)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 12)

                    if presentation.questions.count > 1 {
                        questionNavigation
                    }
                }
            }
            .padding(14)

            Divider()

            choiceList(question)

            if draft.selection(for: question.id) == .other {
                Divider()
                TextField(
                    IntatisLocalization.string("Other…"),
                    text: otherAnswerBinding(for: question.id),
                    axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .controlSize(.large)
                    .lineLimit(1...3)
                    .padding(12)
                    .accessibilityIdentifier(
                        "user-input.other.\(question.id)")
            }

            Divider()

            HStack {
                Spacer(minLength: 0)
                submitButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.secondary.opacity(0.28), lineWidth: 1)
        }
        .clipShape(
            RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityIdentifier("user-input.question.\(question.id)")
    }

    private func choiceList(
        _ question: IntatisUserInputQuestionPresentation
    ) -> some View {
        let rowCount = question.options.count
            + (question.allowsOther ? 1 : 0)
        return List(selection: selectionBinding(for: question.id)) {
            ForEach(Array(question.options.enumerated()), id: \.element.id) {
                index, option in
                choiceRow(
                    number: index + 1,
                    label: option.label,
                    description: option.description)
                    .tag(IntatisUserInputSelection.option(option.label))
            }
            if question.allowsOther {
                choiceRow(
                    number: question.options.count + 1,
                    label: IntatisLocalization.string("Other…"),
                    description: nil)
                    .tag(IntatisUserInputSelection.other)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 44)
        .scrollDisabled(true)
        .frame(height: CGFloat(rowCount * 44))
        .accessibilityLabel(question.question)
    }

    private func choiceRow(
        number: Int,
        label: String,
        description: String?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.body.weight(.medium))

                if let description,
                   !description.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var questionNavigation: some View {
        HStack(spacing: 5) {
            Button {
                activeQuestionIndex = max(0, activeQuestionIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(activeQuestionIndex == 0)

            Text(IntatisLocalization.format(
                "%lld of %lld",
                Int64(activeQuestionIndex + 1),
                Int64(presentation.questions.count)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                activeQuestionIndex = min(
                    presentation.questions.count - 1,
                    activeQuestionIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(
                activeQuestionIndex == presentation.questions.count - 1)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityElement(children: .contain)
    }

    private var submitButton: some View {
        let submission = draft.submission(for: presentation)
        return Button {
            guard let submission else { return }
            onSubmit?(submission)
        } label: {
            HStack(spacing: 6) {
                Text(IntatisLocalization.string("Send"))
                Text("⌘↩")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(submission == nil || onSubmit == nil)
        .help(IntatisLocalization.string("Send"))
        .accessibilityLabel(IntatisLocalization.string("Send"))
        .accessibilityIdentifier("user-input.submit")
    }

    private func selectionBinding(
        for questionID: String
    ) -> Binding<IntatisUserInputSelection?> {
        Binding(
            get: { draft.selection(for: questionID) },
            set: { draft.setSelection($0, for: questionID) })
    }

    private func otherAnswerBinding(for questionID: String) -> Binding<String> {
        Binding(
            get: { draft.otherAnswer(for: questionID) },
            set: { draft.setOtherAnswer($0, for: questionID) })
    }
}
#endif
