import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore
} from "react";
import {
  ConversationPane
} from "./components/ConversationPane";
import {
  DiagnosticsPanel,
  type DomMetrics
} from "./components/DiagnosticsPanel";
import {
  getCodeRendererDiagnostics
} from "./renderer/CodeBlock";
import {
  getMathCacheDiagnostics
} from "./renderer/MathRenderer";
import { STREAMING_CODE } from "./sample";
import {
  SESSION_FIXTURES
} from "./session/sessionFixtures";
import {
  ThreadResidencyStore,
  type ResidencySnapshot
} from "./session/ThreadResidencyStore";
import type {
  ConversationMessage,
  ConversationSession
} from "./session/types";

const WARM_THREAD_TTL_MILLISECONDS = 30_000;
const DEFAULT_STRESS_CYCLES = 36;
const DEFAULT_STRESS_INTERVAL_MILLISECONDS = 120;

type HarnessSetInput = {
  source?: string;
  isStreaming?: boolean;
};

type HarnessStressInput = {
  cycles?: number;
  intervalMs?: number;
};

type RendererHarnessSnapshot = {
  activeSessionId: string;
  generation: number;
  switchCount: number;
  residentThreads: Array<{
    sessionId: string;
    state: "active" | "warm";
    expiresAt: number | null;
  }>;
  sourceLength: number;
  isStreaming: boolean;
  domNodes: number;
  mountedMessages: number;
  mathCount: number;
  activeCodeViews: number;
  loadedLanguages: readonly string[];
  mathCache: {
    entries: number;
    characters: number;
    maximumCharacters: number;
  };
  codeBlocks: Array<{
    language: string;
    highlightedLength: number;
    pendingLength: number;
    generation: number;
    parseStatus: string;
  }>;
};

type RendererHarness = {
  set(input: HarnessSetInput): void;
  switchSession(sessionId: string): void;
  stressSwitch(input?: HarnessStressInput): void;
  stopStress(): void;
  releaseInactive(): void;
  snapshot(): RendererHarnessSnapshot;
};

type ActiveStream = {
  generation: number;
  intervalId: number;
  messageId: string;
  sessionId: string;
  lastSource: string;
};

declare global {
  interface Window {
    rendererHarness?: RendererHarness;
  }
}

function cloneFixtures(): ConversationSession[] {
  return SESSION_FIXTURES.map((session) => ({
    ...session,
    messages: session.messages.map((message) => ({ ...message }))
  }));
}

function replaceMessage(
  sessions: ConversationSession[],
  sessionId: string,
  messageId: string,
  transform: (message: ConversationMessage) => ConversationMessage
): ConversationSession[] {
  return sessions.map((session) => {
    if (session.id !== sessionId) {
      return session;
    }
    return {
      ...session,
      messages: session.messages.map((message) =>
        message.id === messageId ? transform(message) : message
      )
    };
  });
}

function appendMessage(
  sessions: ConversationSession[],
  sessionId: string,
  message: ConversationMessage
): ConversationSession[] {
  return sessions.map((session) =>
    session.id === sessionId
      ? { ...session, messages: [...session.messages, message] }
      : session
  );
}

function readDomMetrics(): DomMetrics {
  const code = getCodeRendererDiagnostics();
  const math = getMathCacheDiagnostics();
  return {
    domNodes: document.querySelectorAll("*").length,
    mountedMessages: document.querySelectorAll(
      '[data-message-mounted="true"]'
    ).length,
    mathNodes: document.querySelectorAll("[data-math-source]").length,
    codeEditorDom: document.querySelectorAll(".cm-editor").length,
    activeCodeViews: code.activeViews,
    mathCacheEntries: math.entries,
    mathCacheCharacters: math.characters,
    loadedLanguages: code.loadedLanguages
  };
}

function sameMetrics(left: DomMetrics, right: DomMetrics) {
  return (
    left.domNodes === right.domNodes &&
    left.mountedMessages === right.mountedMessages &&
    left.mathNodes === right.mathNodes &&
    left.codeEditorDom === right.codeEditorDom &&
    left.activeCodeViews === right.activeCodeViews &&
    left.mathCacheEntries === right.mathCacheEntries &&
    left.mathCacheCharacters === right.mathCacheCharacters &&
    left.loadedLanguages.join("\u0000") ===
      right.loadedLanguages.join("\u0000")
  );
}

function boundedInteger(
  value: number | undefined,
  fallback: number,
  minimum: number,
  maximum: number
) {
  const integer =
    typeof value === "number" && Number.isFinite(value)
      ? Math.floor(value)
      : fallback;
  return Math.max(minimum, Math.min(maximum, integer));
}

function currentSourceLength(
  sessions: ConversationSession[],
  activeSessionId: string
) {
  const messages =
    sessions.find((session) => session.id === activeSessionId)?.messages ?? [];
  return messages.at(-1)?.source.length ?? 0;
}

export default function App() {
  const sessionIds = useMemo(
    () => SESSION_FIXTURES.map((session) => session.id),
    []
  );
  const residencyStore = useMemo(
    () =>
      new ThreadResidencyStore(sessionIds, sessionIds[0], {
        warmTtlMs: WARM_THREAD_TTL_MILLISECONDS
      }),
    [sessionIds]
  );
  const residency = useSyncExternalStore(
    (listener) => residencyStore.subscribe(listener),
    () => residencyStore.getSnapshot(),
    () => residencyStore.getSnapshot()
  );
  const residencyRef = useRef<ResidencySnapshot>(residency);
  const [sessions, setSessions] = useState<ConversationSession[]>(cloneFixtures);
  const sessionsRef = useRef(sessions);
  const [metrics, setMetrics] = useState<DomMetrics>({
    domNodes: 0,
    mountedMessages: 0,
    mathNodes: 0,
    codeEditorDom: 0,
    activeCodeViews: 0,
    mathCacheEntries: 0,
    mathCacheCharacters: 0,
    loadedLanguages: []
  });
  const [stressRemaining, setStressRemaining] = useState(0);
  const streamRef = useRef<ActiveStream | null>(null);
  const streamGenerationRef = useRef(0);
  const stressIntervalRef = useRef<number | null>(null);

  sessionsRef.current = sessions;
  residencyRef.current = residency;

  const activeSession =
    sessions.find((session) => session.id === residency.activeSessionId) ??
    sessions[0];

  const cancelStream = useCallback((reason?: string) => {
    const active = streamRef.current;
    if (!active) {
      return;
    }

    window.clearInterval(active.intervalId);
    streamRef.current = null;
    streamGenerationRef.current += 1;
    const suffix = reason ? `\n\`\`\`\n\n_${reason}_` : "\n```";
    setSessions((current) =>
      replaceMessage(
        current,
        active.sessionId,
        active.messageId,
        (message) => ({
          ...message,
          source: `${active.lastSource}${suffix}`,
          isStreaming: false
        })
      )
    );
  }, []);

  const switchSession = useCallback(
    (sessionId: string) => {
      if (!sessionIds.includes(sessionId)) {
        return;
      }
      if (residencyStore.getSnapshot().activeSessionId === sessionId) {
        return;
      }
      cancelStream("Stream cancelled by a session switch");
      residencyStore.switchTo(sessionId);
    },
    [cancelStream, residencyStore, sessionIds]
  );

  const stopStress = useCallback(() => {
    if (stressIntervalRef.current !== null) {
      window.clearInterval(stressIntervalRef.current);
      stressIntervalRef.current = null;
    }
    setStressRemaining(0);
  }, []);

  const runStress = useCallback(
    (input: HarnessStressInput = {}) => {
      stopStress();
      const cycles = boundedInteger(
        input.cycles,
        DEFAULT_STRESS_CYCLES,
        1,
        1_000
      );
      const intervalMs = boundedInteger(
        input.intervalMs,
        DEFAULT_STRESS_INTERVAL_MILLISECONDS,
        40,
        5_000
      );
      let remaining = cycles;
      let index = sessionIds.indexOf(
        residencyStore.getSnapshot().activeSessionId
      );
      setStressRemaining(remaining);

      stressIntervalRef.current = window.setInterval(() => {
        index = (index + 1) % sessionIds.length;
        switchSession(sessionIds[index]);
        remaining -= 1;
        setStressRemaining(remaining);
        if (remaining <= 0) {
          stopStress();
        }
      }, intervalMs);
    },
    [residencyStore, sessionIds, stopStress, switchSession]
  );

  const runStreamingDemo = useCallback(() => {
    cancelStream();
    const activeSessionId =
      residencyStore.getSnapshot().activeSessionId;
    const generation = ++streamGenerationRef.current;
    const messageId = `local-stream-${generation}`;
    const prefix = [
      "## Incremental code tail",
      "",
      "Only the appended suffix changes while this local sample streams.",
      "",
      "```typescript",
      ""
    ].join("\n");
    let offset = 0;

    setSessions((current) =>
      appendMessage(current, activeSessionId, {
        id: messageId,
        role: "assistant",
        source: prefix,
        isStreaming: true
      })
    );

    const intervalId = window.setInterval(() => {
      const active = streamRef.current;
      if (!active || active.generation !== generation) {
        return;
      }
      offset = Math.min(STREAMING_CODE.length, offset + 7);
      const nextSource = `${prefix}${STREAMING_CODE.slice(0, offset)}`;
      active.lastSource = nextSource;
      setSessions((current) =>
        replaceMessage(
          current,
          activeSessionId,
          messageId,
          (message) => ({
            ...message,
            source: nextSource,
            isStreaming: offset < STREAMING_CODE.length
          })
        )
      );

      if (offset === STREAMING_CODE.length) {
        window.clearInterval(active.intervalId);
        streamRef.current = null;
        setSessions((current) =>
          replaceMessage(
            current,
            activeSessionId,
            messageId,
            (message) => ({
              ...message,
              source: `${nextSource}\n\`\`\``,
              isStreaming: false
            })
          )
        );
      }
    }, 45);

    streamRef.current = {
      generation,
      intervalId,
      messageId,
      sessionId: activeSessionId,
      lastSource: prefix
    };
  }, [cancelStream, residencyStore]);

  useEffect(
    () => () => {
      if (streamRef.current) {
        window.clearInterval(streamRef.current.intervalId);
        streamRef.current = null;
      }
      if (stressIntervalRef.current !== null) {
        window.clearInterval(stressIntervalRef.current);
        stressIntervalRef.current = null;
      }
      residencyStore.dispose();
    },
    [residencyStore]
  );

  useEffect(() => {
    const sample = () => {
      const next = readDomMetrics();
      setMetrics((current) => (sameMetrics(current, next) ? current : next));
    };
    sample();
    const intervalId = window.setInterval(sample, 500);
    return () => window.clearInterval(intervalId);
  }, []);

  useEffect(() => {
    window.rendererHarness = {
      set(input) {
        cancelStream();
        const activeSessionId =
          residencyStore.getSnapshot().activeSessionId;
        setSessions((current) => {
          const session = current.find(
            (candidate) => candidate.id === activeSessionId
          );
          if (!session) {
            return current;
          }
          const target =
            [...session.messages]
              .reverse()
              .find((message) => message.role === "assistant") ??
            session.messages.at(-1);
          if (!target) {
            return current;
          }
          return replaceMessage(
            current,
            activeSessionId,
            target.id,
            (message) => ({
              ...message,
              source:
                typeof input.source === "string"
                  ? input.source
                  : message.source,
              isStreaming:
                typeof input.isStreaming === "boolean"
                  ? input.isStreaming
                  : message.isStreaming
            })
          );
        });
      },
      switchSession,
      stressSwitch: runStress,
      stopStress,
      releaseInactive() {
        residencyStore.releaseInactive();
      },
      snapshot() {
        const snapshot = residencyStore.getSnapshot();
        const activeSessionId = snapshot.activeSessionId;
        const codeBlocks = Array.from(
          document.querySelectorAll<HTMLElement>("[data-code-block]")
        ).map((element) => ({
          language: element.dataset.language ?? "",
          highlightedLength: Number(
            element.dataset.highlightedLength ?? "0"
          ),
          pendingLength: Number(element.dataset.pendingLength ?? "0"),
          generation: Number(element.dataset.generation ?? "0"),
          parseStatus: element.dataset.parseStatus ?? "unknown"
        }));
        const activeMessages =
          sessionsRef.current.find(
            (session) => session.id === activeSessionId
          )?.messages ?? [];
        return {
          activeSessionId,
          generation: snapshot.generation,
          switchCount: snapshot.switchCount,
          residentThreads: snapshot.residents.map((resident) => ({
            sessionId: resident.sessionId,
            state: resident.state,
            expiresAt: resident.expiresAt
          })),
          sourceLength: currentSourceLength(
            sessionsRef.current,
            activeSessionId
          ),
          isStreaming: activeMessages.some(
            (message) => message.isStreaming
          ),
          domNodes: document.querySelectorAll("*").length,
          mountedMessages: document.querySelectorAll(
            '[data-message-mounted="true"]'
          ).length,
          mathCount: document.querySelectorAll("[data-math-source]").length,
          activeCodeViews: getCodeRendererDiagnostics().activeViews,
          loadedLanguages:
            getCodeRendererDiagnostics().loadedLanguages,
          mathCache: getMathCacheDiagnostics(),
          codeBlocks
        };
      }
    };

    return () => {
      delete window.rendererHarness;
    };
  }, [
    cancelStream,
    residencyStore,
    runStress,
    stopStress,
    switchSession
  ]);

  return (
    <main
      className="conversation-lab"
      data-lab-main
      data-active-session={residency.activeSessionId}
    >
      <header className="lab-topbar">
        <div className="lab-identity">
          <div className="lab-mark" aria-hidden="true">
            R
          </div>
          <div>
            <h1>Conversation Renderer Lab</h1>
            <p>
              Local-only Markdown, KaTeX, CodeMirror, and session lifecycle
              experiment
            </p>
          </div>
        </div>
        <div className="lab-actions">
          <button
            type="button"
            onClick={() => residencyStore.releaseInactive()}
          >
            Release warm
          </button>
          <button
            type="button"
            onClick={runStreamingDemo}
          >
            Stream code
          </button>
          <button
            className="primary-action"
            type="button"
            onClick={() =>
              stressRemaining > 0 ? stopStress() : runStress()
            }
          >
            {stressRemaining > 0
              ? `Stop · ${stressRemaining} left`
              : "Stress switch"}
          </button>
        </div>
      </header>

      <div className="conversation-workspace">
        <nav className="session-sidebar" aria-label="Local sample sessions">
          <div className="sidebar-heading">
            <p className="eyebrow">Samples</p>
            <h2>Conversations</h2>
          </div>
          <ul className="session-list">
            {sessions.map((session) => {
              const resident = residency.residents.find(
                (candidate) => candidate.sessionId === session.id
              );
              const state = resident?.state ?? "cold";
              return (
                <li key={session.id}>
                  <button
                    className="session-button"
                    type="button"
                    aria-current={
                      session.id === residency.activeSessionId
                        ? "page"
                        : undefined
                    }
                    onClick={() => switchSession(session.id)}
                  >
                    <span
                      className={`session-state-dot state-${state}`}
                      aria-hidden="true"
                    />
                    <span>
                      <strong>{session.title}</strong>
                      <small>
                        {session.messages.length} messages · {state}
                      </small>
                    </span>
                  </button>
                </li>
              );
            })}
          </ul>
          <p className="sidebar-contract">
            <strong>Isolation contract</strong>
            No production target, remote image, raw HTML execution, session
            store, credential, tool, or code execution bridge.
          </p>
        </nav>

        <ConversationPane
          key={`${activeSession.id}:${residency.generation}`}
          session={activeSession}
          generation={residency.generation}
        />

        <DiagnosticsPanel
          sessionIds={sessionIds}
          residency={residency}
          metrics={metrics}
        />
      </div>
    </main>
  );
}
