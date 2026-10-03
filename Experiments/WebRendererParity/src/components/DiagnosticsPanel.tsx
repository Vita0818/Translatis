import { useEffect, useState } from "react";
import type {
  ResidencySnapshot,
  ResidentThread
} from "../session/ThreadResidencyStore";

export type DomMetrics = {
  domNodes: number;
  mountedMessages: number;
  mathNodes: number;
  codeEditorDom: number;
  activeCodeViews: number;
  mathCacheEntries: number;
  mathCacheCharacters: number;
  loadedLanguages: readonly string[];
};

type DiagnosticsPanelProps = {
  sessionIds: readonly string[];
  residency: ResidencySnapshot;
  metrics: DomMetrics;
};

function stateFor(
  sessionId: string,
  residents: readonly ResidentThread[]
): ResidentThread | undefined {
  return residents.find((resident) => resident.sessionId === sessionId);
}

function remainingSeconds(resident: ResidentThread, now: number) {
  if (resident.expiresAt === null) {
    return null;
  }
  return Math.max(0, Math.ceil((resident.expiresAt - now) / 1000));
}

export function DiagnosticsPanel({
  sessionIds,
  residency,
  metrics
}: DiagnosticsPanelProps) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    const intervalId = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => window.clearInterval(intervalId);
  }, []);

  return (
    <aside className="diagnostics-panel" aria-label="Lifecycle diagnostics">
      <div className="diagnostics-heading">
        <div>
          <p className="eyebrow">Lifecycle</p>
          <h2>Live diagnostics</h2>
        </div>
        <span className="diagnostics-pulse" aria-label="Sampling active" />
      </div>

      <dl className="metric-grid">
        <div>
          <dt>DOM nodes</dt>
          <dd>{metrics.domNodes.toLocaleString()}</dd>
        </div>
        <div>
          <dt>Mounted messages</dt>
          <dd>{metrics.mountedMessages}</dd>
        </div>
        <div>
          <dt>Math nodes</dt>
          <dd>{metrics.mathNodes}</dd>
        </div>
        <div>
          <dt>Editor view / DOM</dt>
          <dd>
            {metrics.activeCodeViews}/{metrics.codeEditorDom}
          </dd>
        </div>
        <div>
          <dt>Math cache</dt>
          <dd>{metrics.mathCacheEntries}</dd>
        </div>
        <div>
          <dt>Cache characters</dt>
          <dd>{metrics.mathCacheCharacters.toLocaleString()}</dd>
        </div>
      </dl>

      <section className="residency-section">
        <div className="section-title-row">
          <h3>Thread residency</h3>
          <span>{residency.switchCount} switches</span>
        </div>
        <ul className="residency-list">
          {sessionIds.map((sessionId) => {
            const resident = stateFor(sessionId, residency.residents);
            const state = resident?.state ?? "cold";
            const seconds = resident
              ? remainingSeconds(resident, now)
              : null;
            return (
              <li key={sessionId}>
                <span className={`residency-dot state-${state}`} />
                <span>{sessionId}</span>
                <strong>{state}</strong>
                {seconds !== null ? <small>{seconds}s</small> : null}
              </li>
            );
          })}
        </ul>
      </section>

      <section className="loaded-language-section">
        <div className="section-title-row">
          <h3>Loaded grammars</h3>
          <span>{metrics.loadedLanguages.length}</span>
        </div>
        <p>
          {metrics.loadedLanguages.length > 0
            ? metrics.loadedLanguages.join(", ")
            : "None yet"}
        </p>
      </section>

      <section className="lifecycle-note">
        <h3>What this proves</h3>
        <p>
          Switching replaces the keyed message subtree. Warm entries retain
          local thread metadata for 30 seconds; they do not keep hidden message
          DOM or CodeMirror views. Shared, bounded math entries and dynamically
          imported grammar modules are reported separately.
        </p>
      </section>
    </aside>
  );
}
