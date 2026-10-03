import Foundation

public enum AgentExecutionBudgetError: Error, Equatable, Sendable, LocalizedError {
    case exhausted(limit: Int, consumed: Int)
    case requestTooLarge(limit: Int, available: Int, estimatedInput: Int)
    case invalidReservation

    public var errorDescription: String? {
        switch self {
        case .exhausted(let limit, let consumed):
            return "Agent token budget exhausted (\(consumed)/\(limit) tokens)."
        case .requestTooLarge(let limit, let available, let estimatedInput):
            return "Agent request needs about \(estimatedInput) input tokens, but only \(available) of the \(limit)-token session budget remain."
        case .invalidReservation:
            return "Agent token budget reservation is missing or was already settled."
        }
    }
}

public struct AgentTokenBudgetReservation: Sendable, Hashable {
    fileprivate let id: UUID
    public let reservedTokens: Int
    /// `nil` for a tracking-only reservation admitted while enforcement was
    /// disabled; providers receive no output ceiling in that mode.
    public let maxOutputTokens: Int?

    fileprivate init(id: UUID, reservedTokens: Int, maxOutputTokens: Int?) {
        self.id = id
        self.reservedTokens = reservedTokens
        self.maxOutputTokens = maxOutputTokens
    }
}

/// Shared by every AgentLoop in one Cowork session. Requests reserve a bounded
/// slice before provider dispatch, so concurrent agents cannot all spend the same
/// remaining balance. This remains a *soft* budget across arbitrary providers:
/// providers can omit usage or ignore `max_tokens`, and tokenization is provider-
/// specific. The reservation closes the in-process race and supplies a best-effort
/// provider output ceiling while enforcement is enabled; disabled requests retain
/// a tracking reservation without a ceiling so a later enable cannot overlook
/// them. Final accounting still uses reported/estimated usage.
public actor AgentTokenBudgetMeter {
    /// `nil` disables admission enforcement for new requests without replacing
    /// this session-lifetime actor. Tracking and enabled reservations both remain
    /// visible across disable/re-enable transitions.
    public private(set) var limit: Int?
    private var consumed: Int
    private var reservations: [UUID: Int]
    private let preferredOutputTokensPerRequest: Int

    public init(limit: Int? = nil,
                consumed: Int = 0,
                preferredOutputTokensPerRequest: Int = 2_048) {
        self.limit = Self.normalized(limit)
        self.consumed = max(0, consumed)
        self.reservations = [:]
        self.preferredOutputTokensPerRequest = max(1, preferredOutputTokensPerRequest)
    }

    public func checkAvailable() throws {
        guard let limit else { return }
        guard availableTokens > 0 else {
            throw AgentExecutionBudgetError.exhausted(limit: limit, consumed: consumed)
        }
    }

    /// When enforcement is disabled this still returns a tracking reservation,
    /// but with `maxOutputTokens == nil`: the provider remains unbounded while an
    /// enable transition can still see the in-flight request and cannot spend its
    /// logical slice twice. Every reservation remains owned by this same actor
    /// until it is settled or released, across disable/re-enable/limit changes.
    public func reserve(estimatedInputTokens: Int) throws -> AgentTokenBudgetReservation {
        let input = max(1, estimatedInputTokens)
        guard let limit else {
            let reserved = Self.saturatingAdd(input, preferredOutputTokensPerRequest)
            let id = UUID()
            reservations[id] = reserved
            return AgentTokenBudgetReservation(
                id: id,
                reservedTokens: reserved,
                maxOutputTokens: nil)
        }
        let available = availableTokens
        guard available > input else {
            throw AgentExecutionBudgetError.requestTooLarge(
                limit: limit,
                available: available,
                estimatedInput: input)
        }
        let output = min(preferredOutputTokensPerRequest, available - input)
        let reserved = input + output
        let id = UUID()
        reservations[id] = reserved
        return AgentTokenBudgetReservation(
            id: id,
            reservedTokens: reserved,
            maxOutputTokens: output)
    }

    @discardableResult
    public func settle(_ reservation: AgentTokenBudgetReservation,
                       reportedTokens: Int?,
                       estimatedTokens: Int) throws -> Int {
        guard reservations.removeValue(forKey: reservation.id) != nil else {
            throw AgentExecutionBudgetError.invalidReservation
        }
        consumed = Self.saturatingAdd(
            consumed,
            max(1, reportedTokens ?? estimatedTokens))
        if let limit, consumed > limit {
            throw AgentExecutionBudgetError.exhausted(limit: limit, consumed: consumed)
        }
        return consumed
    }

    public func release(_ reservation: AgentTokenBudgetReservation) {
        reservations.removeValue(forKey: reservation.id)
    }

    /// Backward-compatible immediate accounting for callers without a provider
    /// dispatch phase. New AgentLoop code should use reserve/settle.
    @discardableResult
    public func charge(reportedTokens: Int?, estimatedTokens: Int) throws -> Int {
        let amount = max(1, reportedTokens ?? estimatedTokens)
        if let limit, amount > availableTokens {
            consumed = Self.saturatingAdd(consumed, amount)
            throw AgentExecutionBudgetError.exhausted(limit: limit, consumed: consumed)
        }
        consumed = Self.saturatingAdd(consumed, amount)
        return consumed
    }

    /// Reconfigures the same session meter in place. `nil` disables enforcement
    /// for future admissions, but neither consumption nor in-flight reservations
    /// are discarded. A durable replay can lag a live settlement, so it may only
    /// raise (never rewind) the actor's current accounting.
    public func reconfigure(tokenBudget: Int?, durableConsumed: Int? = nil) {
        limit = Self.normalized(tokenBudget)
        if let durableConsumed {
            consumed = max(consumed, max(0, durableConsumed))
        }
    }

    public func snapshot() -> (limit: Int?, consumed: Int, reserved: Int, remaining: Int?) {
        let reserved = reservedTokens
        return (
            limit,
            consumed,
            reserved,
            limit.map { max(0, $0 - consumed - reserved) })
    }

    private var reservedTokens: Int {
        reservations.values.reduce(0, Self.saturatingAdd)
    }

    private var availableTokens: Int {
        guard let limit else { return Int.max }
        guard consumed < limit else { return 0 }
        let afterConsumption = limit - consumed
        let reserved = reservedTokens
        return reserved < afterConsumption ? afterConsumption - reserved : 0
    }

    private static func normalized(_ limit: Int?) -> Int? {
        limit.flatMap { $0 > 0 ? $0 : nil }
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}
