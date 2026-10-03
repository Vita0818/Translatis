type MathNode = {
  type?: string;
  data?: {
    hName?: string;
    hProperties?: Record<string, unknown>;
  };
  position?: {
    start?: { offset?: number };
    end?: { offset?: number };
  };
  children?: MathNode[];
};

function normalizeDisplayDelimiters(node: MathNode, source: string): void {
  if (node.type === "inlineMath") {
    const start = node.position?.start?.offset;
    const end = node.position?.end?.offset;
    const raw =
      typeof start === "number" && typeof end === "number"
        ? source.slice(start, end)
        : "";

    if (raw.startsWith("$$") || raw.startsWith("\\[")) {
      node.data = {
        ...node.data,
        hName: "code",
        hProperties: {
          ...node.data?.hProperties,
          className: ["language-math", "math-display"]
        }
      };
    }
  }

  for (const child of node.children ?? []) {
    normalizeDisplayDelimiters(child, source);
  }
}

export default function remarkChatMathSemantics() {
  return (tree: MathNode, file: { value?: unknown }) => {
    const source =
      typeof file.value === "string"
        ? file.value
        : String(file.value ?? "");
    normalizeDisplayDelimiters(tree, source);
  };
}

