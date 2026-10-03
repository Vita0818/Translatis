import type {
  ConversationMessage,
  ConversationSession
} from "./types";

const lines = (...sourceLines: readonly string[]) => sourceLines.join("\n");

const markdownMessages: readonly ConversationMessage[] = [
  {
    id: "markdown-01",
    role: "user",
    source: "Draft a compact release note with headings and a short summary."
  },
  {
    id: "markdown-02",
    role: "assistant",
    source: lines(
      "## Release note",
      "",
      "The local preview now keeps **structured Markdown** readable while a long conversation is open."
    )
  },
  {
    id: "markdown-03",
    role: "user",
    source: "Add a table comparing the three validation stages."
  },
  {
    id: "markdown-04",
    role: "assistant",
    source: lines(
      "| Stage | Purpose | Result |",
      "| --- | --- | --- |",
      "| Parse | Preserve structure | Ready |",
      "| Render | Display safely | Ready |",
      "| Inspect | Record diagnostics | Pending |"
    )
  },
  {
    id: "markdown-05",
    role: "user",
    source: "Turn the remaining work into a task list."
  },
  {
    id: "markdown-06",
    role: "assistant",
    source: lines(
      "- [x] Keep headings and lists",
      "- [x] Keep tables and inline code",
      "- [ ] Run the long-thread inspection",
      "- [ ] Record the final observation"
    )
  },
  {
    id: "markdown-07",
    role: "user",
    source: "Show how raw HTML should be described without activating it."
  },
  {
    id: "markdown-08",
    role: "assistant",
    source: lines(
      "Raw markup remains text:",
      "",
      "<button data-action=\"example\">inactive sample</button>",
      "",
      "The preview must not create an interactive element from that source."
    )
  },
  {
    id: "markdown-09",
    role: "user",
    source: "Add a correction and a brief quoted note."
  },
  {
    id: "markdown-10",
    role: "assistant",
    source: lines(
      "~~Ship immediately~~ Validate the complete thread first.",
      "",
      "> A renderer result is useful only when the original source stays recoverable."
    )
  },
  {
    id: "markdown-11",
    role: "user",
    source: "Include a local relative link and one inline identifier."
  },
  {
    id: "markdown-12",
    role: "assistant",
    source: lines(
      "Open the [local checklist](./validation-checklist.md) and inspect `renderGeneration`.",
      "",
      "No remote image is needed for this fixture."
    )
  },
  {
    id: "markdown-13",
    role: "user",
    source: "Organize the failure response as a nested list."
  },
  {
    id: "markdown-14",
    role: "assistant",
    source: lines(
      "1. Preserve the source.",
      "   - Keep the message identifier.",
      "   - Keep the visible fallback.",
      "2. Isolate the failure.",
      "   - Continue rendering later messages.",
      "   - Expose a bounded diagnostic."
    )
  },
  {
    id: "markdown-15",
    role: "user",
    source: "Finish with a concise acceptance checklist."
  },
  {
    id: "markdown-16",
    role: "assistant",
    source: lines(
      "### Acceptance",
      "",
      "- Older messages can be loaded.",
      "- The active thread remains readable.",
      "- Literal markup stays inert.",
      "- Session changes do not reuse stale presentation state."
    )
  }
];

const latexMessages: readonly ConversationMessage[] = [
  {
    id: "latex-01",
    role: "user",
    source: "Start with an inline quadratic identity."
  },
  {
    id: "latex-02",
    role: "assistant",
    source: "A compact identity is \\((a+b)^2=a^2+2ab+b^2\\)."
  },
  {
    id: "latex-03",
    role: "user",
    source: "Now show a displayed finite sum."
  },
  {
    id: "latex-04",
    role: "assistant",
    source: lines(
      "\\[",
      "\\sum_{k=1}^{n} k = \\frac{n(n+1)}{2}",
      "\\]"
    )
  },
  {
    id: "latex-05",
    role: "user",
    source: "Write a matrix example with named entries."
  },
  {
    id: "latex-06",
    role: "assistant",
    source: lines(
      "$$",
      "A = \\begin{bmatrix} a_{11} & a_{12} \\\\ a_{21} & a_{22} \\end{bmatrix}",
      "$$"
    )
  },
  {
    id: "latex-07",
    role: "user",
    source: "Include a limit and keep the explanation outside the formula."
  },
  {
    id: "latex-08",
    role: "assistant",
    source: lines(
      "The sequence approaches one:",
      "",
      "\\[\\lim_{n\\to\\infty}\\left(1+\\frac{1}{n}\\right)^n=e\\]"
    )
  },
  {
    id: "latex-09",
    role: "user",
    source: "Show a Gaussian integral."
  },
  {
    id: "latex-10",
    role: "assistant",
    source: lines(
      "\\[",
      "\\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx=\\sqrt{\\pi}",
      "\\]"
    )
  },
  {
    id: "latex-11",
    role: "user",
    source: "Add a piecewise function."
  },
  {
    id: "latex-12",
    role: "assistant",
    source: lines(
      "$$",
      "f(x)=\\begin{cases}x^2,&x\\ge 0\\\\-x,&x<0\\end{cases}",
      "$$"
    )
  },
  {
    id: "latex-13",
    role: "user",
    source: "Keep formula-like text inside code literal."
  },
  {
    id: "latex-14",
    role: "assistant",
    source: lines(
      "The code span `\\(not-rendered\\)` remains literal.",
      "",
      "Outside code, \\(x+y\\) is mathematical content."
    )
  },
  {
    id: "latex-15",
    role: "user",
    source: "Close with one aligned derivation."
  },
  {
    id: "latex-16",
    role: "assistant",
    source: lines(
      "\\[",
      "\\begin{aligned}",
      "(x+1)^3 &= (x+1)(x^2+2x+1) \\\\",
      "&=x^3+3x^2+3x+1",
      "\\end{aligned}",
      "\\]"
    )
  }
];

const codeMessages: readonly ConversationMessage[] = [
  {
    id: "code-01",
    role: "user",
    source: "Define a small immutable message type in TypeScript."
  },
  {
    id: "code-02",
    role: "assistant",
    source: lines(
      "```typescript",
      "type Message = {",
      "  readonly id: string;",
      "  readonly source: string;",
      "};",
      "```"
    )
  },
  {
    id: "code-03",
    role: "user",
    source: "Add a function that appends one message without mutation."
  },
  {
    id: "code-04",
    role: "assistant",
    source: lines(
      "```typescript",
      "function appendMessage(",
      "  messages: readonly Message[],",
      "  next: Message",
      "): readonly Message[] {",
      "  return [...messages, next];",
      "}",
      "```"
    )
  },
  {
    id: "code-05",
    role: "user",
    source: "Show a narrow unit test for the helper."
  },
  {
    id: "code-06",
    role: "assistant",
    source: lines(
      "```typescript",
      "it(\"appends without changing the input\", () => {",
      "  const input = [{ id: \"m1\", source: \"first\" }];",
      "  const output = appendMessage(input, { id: \"m2\", source: \"second\" });",
      "",
      "  expect(input).toHaveLength(1);",
      "  expect(output).toHaveLength(2);",
      "});",
      "```"
    )
  },
  {
    id: "code-07",
    role: "user",
    source: "Add a discriminated result type."
  },
  {
    id: "code-08",
    role: "assistant",
    source: lines(
      "```typescript",
      "type Result<T> =",
      "  | { readonly ok: true; readonly value: T }",
      "  | { readonly ok: false; readonly reason: string };",
      "```"
    )
  },
  {
    id: "code-09",
    role: "user",
    source: "Demonstrate the same idea in Swift."
  },
  {
    id: "code-10",
    role: "assistant",
    source: lines(
      "```swift",
      "enum Result<Value> {",
      "    case success(Value)",
      "    case failure(String)",
      "}",
      "```"
    )
  },
  {
    id: "code-11",
    role: "user",
    source: "Include an unknown language block for the plain fallback."
  },
  {
    id: "code-12",
    role: "assistant",
    source: lines(
      "```fixture-language",
      "BEGIN SAMPLE",
      "message_count = 12",
      "END SAMPLE",
      "```"
    )
  },
  {
    id: "code-13",
    role: "user",
    source: "Explain why the code is never executed by this preview."
  },
  {
    id: "code-14",
    role: "assistant",
    source: lines(
      "The blocks are display-only inputs.",
      "",
      "- They are parsed for presentation.",
      "- They are never passed to a shell.",
      "- Copy uses the canonical source text."
    )
  },
  {
    id: "code-15",
    role: "user",
    source: "Finish with a small reducer and preserve the generic type."
  },
  {
    id: "code-16",
    role: "assistant",
    source: lines(
      "```typescript",
      "function collectSuccessful<T>(",
      "  results: readonly Result<T>[],",
      "): readonly T[] {",
      "  return results.flatMap((result) =>",
      "    result.ok ? [result.value] : []",
      "  );",
      "}",
      "```"
    )
  }
];

export const MARKDOWN_SESSION: ConversationSession = {
  id: "markdown-long-thread",
  title: "Markdown long thread",
  description: "Synthetic headings, tables, lists, and literal markup.",
  messages: markdownMessages
};

export const LATEX_SESSION: ConversationSession = {
  id: "latex-long-thread",
  title: "LaTeX long thread",
  description: "Synthetic inline and display mathematics with literal-code cases.",
  messages: latexMessages
};

export const CODE_SESSION: ConversationSession = {
  id: "code-long-thread",
  title: "Code long thread",
  description: "Synthetic TypeScript, Swift, and plain-code fallback messages.",
  messages: codeMessages
};

export const SESSION_FIXTURES: readonly ConversationSession[] = Object.freeze([
  MARKDOWN_SESSION,
  LATEX_SESSION,
  CODE_SESSION
]);

export const SESSION_BY_ID: ReadonlyMap<string, ConversationSession> = new Map(
  SESSION_FIXTURES.map((session) => [session.id, session])
);
