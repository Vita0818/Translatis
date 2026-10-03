type MarkdownNode = {
  type?: string;
  value?: string;
  children?: MarkdownNode[];
  [key: string]: unknown;
};

function convertHtmlNodes(node: MarkdownNode): void {
  if (node.type === "html") {
    const literal = node.value ?? "";
    for (const key of Object.keys(node)) {
      if (key !== "position") {
        delete node[key];
      }
    }
    node.type = "text";
    node.value = literal;
    return;
  }

  for (const child of node.children ?? []) {
    convertHtmlNodes(child);
  }
}

export default function remarkLiteralHtml() {
  return (tree: MarkdownNode) => {
    convertHtmlNodes(tree);
  };
}

