import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ThreadResidencyStore } from "../src/session/ThreadResidencyStore";

const SESSION_IDS = ["session-a", "session-b", "session-c"] as const;
const START_TIME = Date.parse("2026-01-01T00:00:00.000Z");

describe("ThreadResidencyStore", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(START_TIME);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("starts with one active resident and a stable initial snapshot", () => {
    const store = new ThreadResidencyStore(SESSION_IDS, "session-a");
    const snapshot = store.getSnapshot();

    expect(snapshot).toEqual({
      activeSessionId: "session-a",
      generation: 0,
      switchCount: 0,
      residents: [
        {
          sessionId: "session-a",
          state: "active",
          activatedAt: START_TIME,
          expiresAt: null
        }
      ]
    });
    expect(store.getSnapshot()).toBe(snapshot);

    store.dispose();
  });

  it("warms the previous thread and advances generation on a true switch", () => {
    const store = new ThreadResidencyStore(SESSION_IDS, "session-a");
    const listener = vi.fn();
    store.subscribe(listener);
    const initialSnapshot = store.getSnapshot();

    vi.advanceTimersByTime(250);
    store.switchTo("session-b");

    expect(store.getSnapshot()).not.toBe(initialSnapshot);
    expect(store.getSnapshot()).toEqual({
      activeSessionId: "session-b",
      generation: 1,
      switchCount: 1,
      residents: [
        {
          sessionId: "session-a",
          state: "warm",
          activatedAt: START_TIME,
          expiresAt: START_TIME + 30_250
        },
        {
          sessionId: "session-b",
          state: "active",
          activatedAt: START_TIME + 250,
          expiresAt: null
        }
      ]
    });
    expect(listener).toHaveBeenCalledTimes(1);

    store.dispose();
  });

  it("cancels the original eviction when switching back quickly", () => {
    const store = new ThreadResidencyStore(SESSION_IDS, "session-a");

    store.switchTo("session-b");
    vi.advanceTimersByTime(10_000);
    store.switchTo("session-a");

    expect(store.getSnapshot().generation).toBe(2);
    expect(store.getSnapshot().switchCount).toBe(2);
    expect(vi.getTimerCount()).toBe(1);

    vi.advanceTimersByTime(20_000);
    expect(store.getSnapshot().residents).toEqual([
      {
        sessionId: "session-a",
        state: "active",
        activatedAt: START_TIME + 10_000,
        expiresAt: null
      },
      {
        sessionId: "session-b",
        state: "warm",
        activatedAt: START_TIME,
        expiresAt: START_TIME + 40_000
      }
    ]);

    vi.advanceTimersByTime(10_000);
    expect(store.getSnapshot().residents).toEqual([
      {
        sessionId: "session-a",
        state: "active",
        activatedAt: START_TIME + 10_000,
        expiresAt: null
      }
    ]);

    store.dispose();
  });

  it("evicts a warm thread after the configured 30 second TTL", () => {
    const store = new ThreadResidencyStore(SESSION_IDS, "session-a");
    const listener = vi.fn();
    store.subscribe(listener);

    store.switchTo("session-b");
    const switchedSnapshot = store.getSnapshot();

    vi.advanceTimersByTime(29_999);
    expect(store.getSnapshot()).toBe(switchedSnapshot);
    expect(store.getSnapshot().residents).toHaveLength(2);

    vi.advanceTimersByTime(1);
    expect(store.getSnapshot()).not.toBe(switchedSnapshot);
    expect(store.getSnapshot().residents).toEqual([
      {
        sessionId: "session-b",
        state: "active",
        activatedAt: START_TIME,
        expiresAt: null
      }
    ]);
    expect(listener).toHaveBeenCalledTimes(2);

    store.dispose();
  });

  it("releases every inactive resident immediately and clears its timer", () => {
    const store = new ThreadResidencyStore(SESSION_IDS, "session-a");
    const listener = vi.fn();
    store.subscribe(listener);

    store.switchTo("session-b");
    store.releaseInactive();
    const releasedSnapshot = store.getSnapshot();

    expect(releasedSnapshot.residents).toEqual([
      {
        sessionId: "session-b",
        state: "active",
        activatedAt: START_TIME,
        expiresAt: null
      }
    ]);
    expect(vi.getTimerCount()).toBe(0);
    expect(listener).toHaveBeenCalledTimes(2);

    store.releaseInactive();
    expect(store.getSnapshot()).toBe(releasedSnapshot);

    vi.advanceTimersByTime(60_000);
    expect(store.getSnapshot()).toBe(releasedSnapshot);
    expect(listener).toHaveBeenCalledTimes(2);

    store.dispose();
  });

  it("clears timers and listeners on dispose", () => {
    const store = new ThreadResidencyStore(SESSION_IDS, "session-a");
    const listener = vi.fn();
    store.subscribe(listener);

    store.switchTo("session-b");
    const snapshotAtDispose = store.getSnapshot();
    store.dispose();

    expect(vi.getTimerCount()).toBe(0);
    vi.advanceTimersByTime(60_000);
    store.switchTo("session-a");
    store.releaseInactive();

    expect(store.getSnapshot()).toBe(snapshotAtDispose);
    expect(listener).toHaveBeenCalledTimes(1);

    const lateListener = vi.fn();
    const unsubscribe = store.subscribe(lateListener);
    unsubscribe();
    expect(lateListener).not.toHaveBeenCalled();
  });

  it("keeps same-session switches as exact no-ops", () => {
    const store = new ThreadResidencyStore(SESSION_IDS, "session-a", {
      warmTtlMs: 30_000
    });
    const listener = vi.fn();
    store.subscribe(listener);
    const initialSnapshot = store.getSnapshot();

    store.switchTo("session-a");

    expect(store.getSnapshot()).toBe(initialSnapshot);
    expect(store.getSnapshot().generation).toBe(0);
    expect(store.getSnapshot().switchCount).toBe(0);
    expect(listener).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(0);

    store.dispose();
  });
});
