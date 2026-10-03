#if canImport(SwiftUI)
import Foundation
import IntatisCodexRuntime
import IntatisSharedUI

/// Main-actor bridge between an official App Server request and the app's
/// request-local SwiftUI presentation. It owns no Codex protocol behavior:
/// the runtime remains responsible for validation, JSON-RPC and turn resume.
@MainActor
final class CodexUserInputPresenter {
    private struct PendingRequest {
        let presentation: IntatisUserInputPresentation
        let continuation:
            CheckedContinuation<CodexRuntimeUserInputResponse, Error>
    }

    var onPresentationChange: ((IntatisUserInputPresentation?) -> Void)?

    private var order: [CodexRuntimeRequestID] = []
    private var pending: [CodexRuntimeRequestID: PendingRequest] = [:]

    func requestInput(
        _ request: CodexRuntimeUserInputRequest,
        requesterName: String?
    ) async throws -> CodexRuntimeUserInputResponse {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled,
                      pending[request.requestID] == nil else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let presentationID = UUID().uuidString
                let presentation = IntatisUserInputPresentation(
                    id: presentationID,
                    requesterName: requesterName,
                    questions: request.questions.map { question in
                        IntatisUserInputQuestionPresentation(
                            id: question.id,
                            question: question.question,
                            options: question.options.map { option in
                                IntatisUserInputOptionPresentation(
                                    label: option.label,
                                    description: option.description)
                            },
                            allowsOther: question.allowsOther)
                    })
                pending[request.requestID] = PendingRequest(
                    presentation: presentation,
                    continuation: continuation)
                order.append(request.requestID)
                publishCurrent()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID: request.requestID)
            }
        }
    }

    func submit(_ submission: IntatisUserInputSubmission) {
        guard let requestID = order.first(where: {
            pending[$0]?.presentation.id == submission.requestID
        }), let request = remove(requestID: requestID) else {
            return
        }
        request.continuation.resume(returning:
            CodexRuntimeUserInputResponse(answers: submission.answers))
    }

    func cancelAll() {
        let requests = order.compactMap { pending[$0] }
        order.removeAll(keepingCapacity: false)
        pending.removeAll(keepingCapacity: false)
        onPresentationChange?(nil)
        for request in requests {
            request.continuation.resume(throwing: CancellationError())
        }
    }

    private func cancel(requestID: CodexRuntimeRequestID) {
        guard let request = remove(requestID: requestID) else { return }
        request.continuation.resume(throwing: CancellationError())
    }

    private func remove(
        requestID: CodexRuntimeRequestID
    ) -> PendingRequest? {
        guard let request = pending.removeValue(forKey: requestID) else {
            return nil
        }
        order.removeAll { $0 == requestID }
        publishCurrent()
        return request
    }

    private func publishCurrent() {
        let presentation = order.first.flatMap { pending[$0]?.presentation }
        onPresentationChange?(presentation)
    }
}
#endif
