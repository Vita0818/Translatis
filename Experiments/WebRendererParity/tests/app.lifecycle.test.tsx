import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor
} from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import App from "../src/App";
import { SESSION_FIXTURES } from "../src/session/sessionFixtures";

afterEach(() => {
  cleanup();
});

describe("conversation lifecycle", () => {
  it("keeps the shell, disconnects the old message subtree, and warms metadata", async () => {
    const { container } = render(<App />);
    const shell = container.querySelector("[data-lab-main]");
    const oldSubtree = container.querySelector("[data-message-subtree]");
    const target = SESSION_FIXTURES[1];

    expect(shell).not.toBeNull();
    expect(oldSubtree).not.toBeNull();
    expect(container.querySelectorAll("[data-message-id]")).toHaveLength(12);

    act(() => {
      window.rendererHarness?.switchSession(target.id);
    });

    await waitFor(() => {
      expect(
        container.querySelector("[data-message-subtree]")
      ).toHaveAttribute("data-session-id", target.id);
    });

    expect(container.querySelector("[data-lab-main]")).toBe(shell);
    expect(oldSubtree?.isConnected).toBe(false);
    expect(container.querySelectorAll("[data-message-subtree]")).toHaveLength(1);

    const switched = window.rendererHarness?.snapshot();
    expect(switched?.generation).toBe(1);
    expect(switched?.residentThreads).toEqual([
      expect.objectContaining({
        sessionId: SESSION_FIXTURES[0].id,
        state: "warm"
      }),
      expect.objectContaining({
        sessionId: target.id,
        state: "active"
      })
    ]);

    act(() => {
      window.rendererHarness?.releaseInactive();
    });
    expect(window.rendererHarness?.snapshot().residentThreads).toEqual([
      expect.objectContaining({
        sessionId: target.id,
        state: "active"
      })
    ]);
  });

  it("paginates older messages without mounting a second session tree", () => {
    const { container } = render(<App />);

    expect(container.querySelectorAll("[data-message-id]")).toHaveLength(12);
    fireEvent.click(
      screen.getByRole("button", { name: "Load 4 older messages" })
    );

    expect(container.querySelectorAll("[data-message-id]")).toHaveLength(16);
    expect(container.querySelectorAll("[data-message-subtree]")).toHaveLength(1);
  });

  it("cancels a local stream before switching generations", async () => {
    const { container } = render(<App />);
    fireEvent.click(screen.getByRole("button", { name: "Stream code" }));

    await waitFor(() => {
      expect(window.rendererHarness?.snapshot().isStreaming).toBe(true);
    });

    act(() => {
      window.rendererHarness?.switchSession(SESSION_FIXTURES[2].id);
    });

    await waitFor(() => {
      expect(
        container.querySelector("[data-message-subtree]")
      ).toHaveAttribute("data-session-id", SESSION_FIXTURES[2].id);
    });
    expect(window.rendererHarness?.snapshot().isStreaming).toBe(false);
    expect(window.rendererHarness?.snapshot().generation).toBe(1);
  });

  it("destroys CodeMirror views when their session subtree disconnects", async () => {
    const { container } = render(<App />);

    act(() => {
      window.rendererHarness?.switchSession(SESSION_FIXTURES[2].id);
    });
    await waitFor(() => {
      expect(
        window.rendererHarness?.snapshot().activeCodeViews
      ).toBeGreaterThan(0);
    });
    const editor = container.querySelector(".cm-editor");
    expect(editor).not.toBeNull();

    act(() => {
      window.rendererHarness?.switchSession(SESSION_FIXTURES[0].id);
    });
    await waitFor(() => {
      expect(window.rendererHarness?.snapshot().activeCodeViews).toBe(0);
    });

    expect(editor?.isConnected).toBe(false);
    expect(container.querySelectorAll(".cm-editor")).toHaveLength(0);
  });
});
