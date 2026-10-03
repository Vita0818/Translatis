import {
  act,
  cleanup,
  fireEvent,
  render,
  screen,
  waitFor
} from "@testing-library/react";
import { StrictMode } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CodeBlock } from "../src/renderer/CodeBlock";
import { MarkdownRenderer } from "../src/renderer/MarkdownRenderer";
import {
  getMathCacheDiagnostics,
  resetMathCacheForTests
} from "../src/renderer/MathRenderer";

afterEach(() => {
  cleanup();
  resetMathCacheForTests();
  vi.useRealTimers();
});

describe("Markdown contract", () => {
  it("renders GFM structure, hard breaks, and source positions", () => {
    const source = [
      "## 标题",
      "",
      "第一行",
      "第二行",
      "",
      "| A | B |",
      "| --- | --- |",
      "| 1 | 2 |",
      "",
      "- [x] done",
      "- [ ] todo",
      "",
      "~~删除~~ ~保留~",
      "",
      "`x < y`"
    ].join("\n");

    const { container } = render(
      <MarkdownRenderer source={source} isStreaming={false} />
    );

    const heading = screen.getByRole("heading", {
      level: 2,
      name: "标题"
    });
    expect(heading).toHaveAttribute("data-source-start", "0");

    const paragraph = screen.getByText("第一行", { exact: false });
    expect(paragraph.querySelector("br")).not.toBeNull();
    expect(screen.getByRole("table")).toBeInTheDocument();
    expect(screen.getAllByRole("columnheader")).toHaveLength(2);
    expect(screen.getAllByRole("checkbox")).toHaveLength(2);
    expect(screen.getAllByRole("checkbox")[0]).toBeChecked();
    expect(screen.getAllByRole("checkbox")[1]).not.toBeChecked();
    expect(screen.getAllByRole("checkbox")[0]).toBeDisabled();
    expect(container.querySelector("del")).toHaveTextContent("删除");
    expect(container.querySelectorAll("del")).toHaveLength(1);
    expect(container).toHaveTextContent("~保留~");
    expect(container.querySelector(".inline-code")).toHaveTextContent("x < y");
  });

  it("shows raw HTML as literal text without creating active elements", () => {
    const source = [
      "before <b>bold</b> after",
      "",
      "<script>window.__rendererPwned = true</script>",
      "",
      "<img src=x onerror=\"window.__rendererPwned = true\">"
    ].join("\n");
    const { container } = render(
      <MarkdownRenderer source={source} isStreaming={false} />
    );

    expect(container).toHaveTextContent("<b>bold</b>");
    expect(container).toHaveTextContent(
      "<script>window.__rendererPwned = true</script>"
    );
    expect(container.querySelector("b")).toBeNull();
    expect(container.querySelector("script")).toBeNull();
    expect(container.querySelector("img")).toBeNull();
    expect(
      (window as typeof window & { __rendererPwned?: boolean })
        .__rendererPwned
    ).toBeUndefined();
  });

  it("blocks dangerous Markdown links and never loads Markdown images", () => {
    const source = [
      "[safe](https://example.com)",
      "[bad](javascript:alert(1))",
      "![remote](https://example.com/image.png)"
    ].join("\n\n");
    const { container } = render(
      <MarkdownRenderer source={source} isStreaming={false} />
    );

    expect(screen.getByRole("link", { name: "safe" })).toHaveAttribute(
      "href",
      "https://example.com"
    );
    expect(screen.queryByRole("link", { name: "bad" })).toBeNull();
    expect(screen.getByText("bad")).toHaveClass("blocked-link");
    expect(container.querySelector("img")).toBeNull();
    expect(screen.getByRole("note")).toHaveTextContent("[Image: remote]");
  });
});

describe("math contract", () => {
  it("renders parenthesis inline and bracket/double-dollar display math", () => {
    const source = [
      "\\(x^2\\)",
      "",
      "\\[y^2\\]",
      "",
      "$$z^2$$",
      "",
      "$single$"
    ].join("\n");
    const { container } = render(
      <MarkdownRenderer source={source} isStreaming={false} />
    );

    expect(container.querySelectorAll(".math-inline")).toHaveLength(1);
    expect(container.querySelectorAll(".math-display")).toHaveLength(2);
    expect(container.querySelectorAll(".katex")).toHaveLength(3);
    expect(container.querySelectorAll(".katex-display")).toHaveLength(2);
    expect(container.querySelectorAll(".katex-mathml math")).toHaveLength(3);
    expect(
      container.querySelectorAll(
        'annotation[encoding="application/x-tex"]'
      )[0]
    ).toHaveTextContent("x^2");
    expect(container).toHaveTextContent("$single$");

    const cache = getMathCacheDiagnostics();
    expect(cache.entries).toBe(3);
    expect(cache.characters).toBeGreaterThan(0);
    expect(cache.characters).toBeLessThanOrEqual(cache.maximumCharacters);
  });

  it("uses a visible parse fallback when complete", () => {
    const { container } = render(
      <MarkdownRenderer
        source={"\\(\\notARealKatexCommand{x}\\)"}
        isStreaming={false}
      />
    );

    expect(container.querySelector("[data-math-status='parse-error']")).not
      .toBeNull();
    expect(
      container.querySelector(
        'annotation[encoding="application/x-tex"]'
      )
    ).toHaveTextContent(
      "\\notARealKatexCommand{x}"
    );
  });

  it("does not consume math syntax inside inline or fenced code", () => {
    const source = [
      "`\\(inline-code\\)`",
      "",
      "```text",
      "$$block-code$$",
      "\\(still-code\\)",
      "```"
    ].join("\n");
    const { container } = render(
      <MarkdownRenderer source={source} isStreaming={false} />
    );

    expect(container.querySelectorAll(".katex")).toHaveLength(0);
    expect(container.querySelector(".inline-code")).toHaveTextContent(
      "\\(inline-code\\)"
    );
    expect(container.querySelector("[data-code-block]")).toHaveTextContent(
      "$$block-code$$"
    );
  });
});

describe("code block contract", () => {
  it("settles an initial non-streaming block through Strict Mode replay", async () => {
    const code = "const strict = true;";
    const { container } = render(
      <StrictMode>
        <CodeBlock code={code} language="typescript" isStreaming={false} />
      </StrictMode>
    );
    const block = container.querySelector("[data-code-block]");

    await waitFor(() => {
      expect(block).toHaveAttribute(
        "data-highlighted-length",
        String(code.length)
      );
      expect(block).toHaveAttribute("data-pending-length", "0");
    });
  });

  it("loads a known language and keeps unknown languages plain", async () => {
    const source = [
      "```python",
      "print('hello')",
      "```",
      "",
      "```definitely-not-a-language",
      "<tag>& value</tag>",
      "```"
    ].join("\n");
    const { container } = render(
      <MarkdownRenderer source={source} isStreaming={false} />
    );
    const blocks = container.querySelectorAll<HTMLElement>("[data-code-block]");

    expect(blocks).toHaveLength(2);
    expect(blocks[0]).toHaveAttribute("data-language", "python");
    expect(blocks[1]).toHaveAttribute(
      "data-language",
      "definitely-not-a-language"
    );

    await waitFor(() => {
      expect(blocks[0]).toHaveAttribute("data-parse-status", "highlighted");
      expect(blocks[1]).toHaveAttribute("data-parse-status", "plain");
    });
    expect(blocks[0].querySelector(".cm-content")).toHaveTextContent(
      "print('hello')"
    );
    expect(blocks[1].querySelector(".cm-content")).toHaveTextContent(
      "<tag>& value</tag>"
    );
    expect(blocks[1].querySelector("tag")).toBeNull();
  });

  it("copies canonical raw code rather than highlighted DOM", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText }
    });

    render(
      <CodeBlock
        code={"const answer = 42;"}
        language="typescript"
        isStreaming={false}
      />
    );
    fireEvent.click(screen.getByRole("button", { name: "Copy" }));

    await waitFor(() => {
      expect(writeText).toHaveBeenCalledWith("const answer = 42;");
    });
  });

  it("keeps an appended streaming tail pending until the trailing window", async () => {
    vi.useFakeTimers();
    const { container, rerender } = render(
      <CodeBlock code="a" language="" isStreaming={false} />
    );
    const block = container.querySelector<HTMLElement>("[data-code-block]");
    expect(block).not.toBeNull();

    await act(async () => {
      vi.runOnlyPendingTimers();
    });
    expect(block).toHaveAttribute("data-highlighted-length", "1");

    rerender(<CodeBlock code="ab" language="" isStreaming />);
    expect(block).toHaveAttribute("data-highlighted-length", "1");
    expect(block).toHaveAttribute("data-pending-length", "1");

    await act(async () => {
      vi.advanceTimersByTime(499);
    });
    expect(block).toHaveAttribute("data-pending-length", "1");

    await act(async () => {
      vi.advanceTimersByTime(1);
    });
    expect(block).toHaveAttribute("data-highlighted-length", "2");
    expect(block).toHaveAttribute("data-pending-length", "0");
  });

  it("applies consecutive streaming appends without recreating the editor", () => {
    const { container, rerender } = render(
      <CodeBlock code="a" language="" isStreaming />
    );
    const editor = container.querySelector(".cm-editor");

    expect(editor).not.toBeNull();
    expect(container.querySelector(".cm-content")).toHaveTextContent("a");

    rerender(<CodeBlock code="ab" language="" isStreaming />);
    expect(container.querySelector(".cm-content")).toHaveTextContent("ab");
    expect(container.querySelector(".cm-editor")).toBe(editor);

    rerender(<CodeBlock code="abc" language="" isStreaming />);
    expect(container.querySelector(".cm-content")).toHaveTextContent("abc");
    expect(container.querySelector(".cm-editor")).toBe(editor);
  });

  it("replaces non-append streaming content in the existing editor", () => {
    const { container, rerender } = render(
      <CodeBlock code="alpha" language="" isStreaming />
    );
    const editor = container.querySelector(".cm-editor");

    expect(editor).not.toBeNull();

    rerender(<CodeBlock code="replacement" language="" isStreaming />);
    expect(container.querySelector(".cm-content")).toHaveTextContent(
      "replacement"
    );
    expect(container.querySelector(".cm-content")).not.toHaveTextContent(
      "alpha"
    );
    expect(container.querySelector(".cm-editor")).toBe(editor);
  });
});
