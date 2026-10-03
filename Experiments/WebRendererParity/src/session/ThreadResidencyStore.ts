export type ResidentThreadState = "active" | "warm";

export interface ResidentThread {
  readonly sessionId: string;
  readonly state: ResidentThreadState;
  readonly activatedAt: number;
  readonly expiresAt: number | null;
}

export interface ResidencySnapshot {
  readonly activeSessionId: string;
  readonly generation: number;
  readonly switchCount: number;
  readonly residents: readonly ResidentThread[];
}

export interface ThreadResidencyStoreOptions {
  readonly warmTtlMs?: number;
}

type Listener = () => void;
type EvictionTimer = ReturnType<typeof setTimeout>;

const DEFAULT_WARM_TTL_MS = 30_000;

export class ThreadResidencyStore {
  readonly getSnapshot: () => ResidencySnapshot;
  readonly subscribe: (listener: Listener) => () => void;

  private readonly sessionIds: readonly string[];
  private readonly knownSessionIds: ReadonlySet<string>;
  private readonly warmTtlMs: number;
  private readonly residents = new Map<string, ResidentThread>();
  private readonly evictionTimers = new Map<string, EvictionTimer>();
  private readonly listeners = new Set<Listener>();

  private activeSessionId: string;
  private generation = 0;
  private switchCount = 0;
  private snapshot: ResidencySnapshot;
  private disposed = false;

  constructor(
    sessionIds: Iterable<string>,
    initialSessionId: string,
    options: ThreadResidencyStoreOptions = {}
  ) {
    const uniqueSessionIds = [...new Set(sessionIds)];
    if (uniqueSessionIds.length === 0) {
      throw new RangeError("ThreadResidencyStore requires at least one session");
    }
    if (
      uniqueSessionIds.some(
        (sessionId) => typeof sessionId !== "string" || sessionId.length === 0
      )
    ) {
      throw new TypeError("Session IDs must be non-empty strings");
    }
    if (!uniqueSessionIds.includes(initialSessionId)) {
      throw new RangeError(`Unknown initial session: ${initialSessionId}`);
    }

    const warmTtlMs = options.warmTtlMs ?? DEFAULT_WARM_TTL_MS;
    if (!Number.isFinite(warmTtlMs) || warmTtlMs < 0) {
      throw new RangeError("warmTtlMs must be a finite, non-negative number");
    }

    this.sessionIds = uniqueSessionIds;
    this.knownSessionIds = new Set(uniqueSessionIds);
    this.warmTtlMs = warmTtlMs;
    this.activeSessionId = initialSessionId;
    this.residents.set(initialSessionId, {
      sessionId: initialSessionId,
      state: "active",
      activatedAt: Date.now(),
      expiresAt: null
    });
    this.snapshot = this.createSnapshot();

    this.getSnapshot = () => this.snapshot;
    this.subscribe = (listener) => {
      if (this.disposed) {
        return () => {};
      }

      this.listeners.add(listener);
      return () => {
        this.listeners.delete(listener);
      };
    };
  }

  switchTo(sessionId: string): void {
    if (this.disposed) {
      return;
    }
    if (!this.knownSessionIds.has(sessionId)) {
      throw new RangeError(`Unknown session: ${sessionId}`);
    }
    if (sessionId === this.activeSessionId) {
      return;
    }

    const switchedAt = Date.now();
    const previousSessionId = this.activeSessionId;
    const previousResident = this.residents.get(previousSessionId);
    const expiresAt = switchedAt + this.warmTtlMs;

    this.residents.set(previousSessionId, {
      sessionId: previousSessionId,
      state: "warm",
      activatedAt: previousResident?.activatedAt ?? switchedAt,
      expiresAt
    });
    this.cancelEviction(previousSessionId);
    this.scheduleEviction(previousSessionId, expiresAt);

    this.cancelEviction(sessionId);
    this.residents.set(sessionId, {
      sessionId,
      state: "active",
      activatedAt: switchedAt,
      expiresAt: null
    });

    this.activeSessionId = sessionId;
    this.generation += 1;
    this.switchCount += 1;
    this.publish();
  }

  releaseInactive(): void {
    if (this.disposed) {
      return;
    }

    let changed = false;
    for (const [sessionId, resident] of this.residents) {
      if (resident.state !== "warm") {
        continue;
      }

      this.cancelEviction(sessionId);
      this.residents.delete(sessionId);
      changed = true;
    }

    if (changed) {
      this.publish();
    }
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }

    this.disposed = true;
    for (const timer of this.evictionTimers.values()) {
      clearTimeout(timer);
    }
    this.evictionTimers.clear();
    this.listeners.clear();
  }

  private scheduleEviction(sessionId: string, expectedExpiresAt: number): void {
    const timer = setTimeout(() => {
      this.evictionTimers.delete(sessionId);
      if (this.disposed) {
        return;
      }

      const resident = this.residents.get(sessionId);
      if (
        resident?.state !== "warm" ||
        resident.expiresAt !== expectedExpiresAt
      ) {
        return;
      }

      this.residents.delete(sessionId);
      this.publish();
    }, this.warmTtlMs);

    this.evictionTimers.set(sessionId, timer);
  }

  private cancelEviction(sessionId: string): void {
    const timer = this.evictionTimers.get(sessionId);
    if (timer === undefined) {
      return;
    }

    clearTimeout(timer);
    this.evictionTimers.delete(sessionId);
  }

  private publish(): void {
    this.snapshot = this.createSnapshot();
    for (const listener of [...this.listeners]) {
      listener();
    }
  }

  private createSnapshot(): ResidencySnapshot {
    const residents = this.sessionIds.flatMap((sessionId) => {
      const resident = this.residents.get(sessionId);
      return resident === undefined ? [] : [Object.freeze({ ...resident })];
    });

    return Object.freeze({
      activeSessionId: this.activeSessionId,
      generation: this.generation,
      switchCount: this.switchCount,
      residents: Object.freeze(residents)
    });
  }
}
