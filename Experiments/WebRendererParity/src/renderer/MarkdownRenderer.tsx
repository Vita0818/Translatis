import {
  createContext,
  isValidElement,
  useContext,
  type AnchorHTMLAttributes,
  type ReactNode
} from "react";
import ReactMarkdown, { type Components } from "react-markdown";
import remarkBreaks from "remark-breaks";
import remarkGfm from "remark-gfm";
import { CodeBlock, canonicalizeFencedCode } from "./CodeBlock";
import { MathRenderer } from "./MathRenderer";
import { RendererErrorBoundary } from "./RendererErrorBoundary";
import remarkChatMathSemantics from "./remarkChatMathSemantics";
import remarkLlmMath from "./remarkLlmMath";
import remarkLiteralHtml from "./remarkLiteralHtml";
import { isSandboxUrl, safeUrlTransform } from "./urlPolicy";

const MAX_SOURCE_CHARACTERS = 512 * 1024;
const BlockCodeContext = createContext(false);
const StreamingContext = createContext(false);

type PositionedNode = {
  position?: {
    start?: { offset?: number };
    end?: { offset?: number };
  };
};

function sourcePosition(node?: PositionedNode) {
  return {
    "data-source-start": node?.position?.start?.offset,
    "data-source-end": node?.position?.end?.offset
  };
}

function classIncludes(className: string | undefined, value: string) {
  return className?.split(/\s+/).includes(value) ?? false;
}

function MarkdownCode({
  node,
  className,
  children,
  ...props
}: {
  node?: PositionedNode;
  className?: string;
  children?: ReactNode;
}) {
  const isBlock = useContext(BlockCodeContext);
  const isStreaming = useContext(StreamingContext);
  const value = String(children ?? "");

  if (
    classIncludes(className, "math-inline") ||
    classIncludes(className, "math-display")
  ) {
    return (
      <MathRenderer
        source={value}
        displayMode={classIncludes(className, "math-display")}
        isStreaming={isStreaming}
      />
    );
  }

  if (isBlock) {
    const language = /(?:^|\s)language-([^\s]+)/.exec(className ?? "")?.[1];
    const canonical = canonicalizeFencedCode(value);
    const displayMath =
      classIncludes(className, "math-display") || language === "math";

    if (displayMath) {
      return (
        <MathRenderer
          source={canonical}
          displayMode
          isStreaming={isStreaming}
        />
      );
    }

    return (
      <CodeBlock
        code={canonical}
        language={language}
        isStreaming={isStreaming}
        sourceStart={node?.position?.start?.offset}
        sourceEnd={node?.position?.end?.offset}
      />
    );
  }

  return (
    <code className="inline-code" {...sourcePosition(node)} {...props}>
      {children}
    </code>
  );
}

function MarkdownPre({
  node,
  children
}: {
  node?: PositionedNode;
  children?: ReactNode;
}) {
  const childClass =
    isValidElement<{ className?: string }>(children)
      ? children.props.className
      : undefined;
  const isMath =
    classIncludes(childClass, "math-display") ||
    classIncludes(childClass, "language-math");

  return (
    <BlockCodeContext.Provider value>
      <div
        className={isMath ? "math-block-slot" : "code-block-slot"}
        {...sourcePosition(node)}
      >
        {children}
      </div>
    </BlockCodeContext.Provider>
  );
}

function MarkdownLink({
  node,
  href,
  children,
  ...props
}: AnchorHTMLAttributes<HTMLAnchorElement> & {
  node?: PositionedNode;
}) {
  if (!href) {
    return (
      <span className="blocked-link" {...sourcePosition(node)}>
        {children}
      </span>
    );
  }

  const external = /^https?:/i.test(href);
  return (
    <a
      {...props}
      {...sourcePosition(node)}
      href={href}
      rel={external ? "noreferrer noopener" : undefined}
      target={external ? "_blank" : undefined}
      onClick={(event) => {
        if (isSandboxUrl(href)) {
          event.preventDefault();
          window.dispatchEvent(
            new CustomEvent("renderer-sandbox-link", {
              detail: { href }
            })
          );
        }
      }}
    >
      {children}
    </a>
  );
}

const markdownComponents: Components = {
  pre: MarkdownPre,
  code: MarkdownCode,
  a: MarkdownLink,
  img({ node, alt = "", src }) {
    return (
      <span
        className="image-placeholder"
        role="note"
        title={src ? `Remote image not loaded: ${src}` : "Image not loaded"}
        {...sourcePosition(node)}
      >
        [Image: {alt || "no alt text"}]
      </span>
    );
  },
  table({ node, children, ...props }) {
    return (
      <div className="table-scroller" {...sourcePosition(node)}>
        <table {...props}>{children}</table>
      </div>
    );
  },
  h1({ node, ...props }) {
    return <h1 {...sourcePosition(node)} {...props} />;
  },
  h2({ node, ...props }) {
    return <h2 {...sourcePosition(node)} {...props} />;
  },
  h3({ node, ...props }) {
    return <h3 {...sourcePosition(node)} {...props} />;
  },
  h4({ node, ...props }) {
    return <h4 {...sourcePosition(node)} {...props} />;
  },
  h5({ node, ...props }) {
    return <h5 {...sourcePosition(node)} {...props} />;
  },
  h6({ node, ...props }) {
    return <h6 {...sourcePosition(node)} {...props} />;
  },
  p({ node, ...props }) {
    return <p {...sourcePosition(node)} {...props} />;
  },
  blockquote({ node, ...props }) {
    return <blockquote {...sourcePosition(node)} {...props} />;
  },
  ul({ node, ...props }) {
    return <ul {...sourcePosition(node)} {...props} />;
  },
  ol({ node, ...props }) {
    return <ol {...sourcePosition(node)} {...props} />;
  }
};

export type MarkdownRendererProps = {
  source: string;
  isStreaming: boolean;
};

export function MarkdownRenderer({
  source,
  isStreaming
}: MarkdownRendererProps) {
  if (source.length > MAX_SOURCE_CHARACTERS) {
    return (
      <div className="renderer-error" role="alert">
        <strong>Input exceeds the 512 KiB experiment limit.</strong>
        <pre>{source}</pre>
      </div>
    );
  }

  return (
    <RendererErrorBoundary source={source}>
      <StreamingContext.Provider value={isStreaming}>
        <article
          className="markdown-body"
          data-renderer-root
          data-streaming={isStreaming ? "true" : "false"}
        >
          <ReactMarkdown
            remarkPlugins={[
              [remarkGfm, { singleTilde: false }],
              remarkBreaks,
              remarkLlmMath,
              remarkChatMathSemantics,
              remarkLiteralHtml
            ]}
            components={markdownComponents}
            urlTransform={safeUrlTransform}
          >
            {source}
          </ReactMarkdown>
        </article>
      </StreamingContext.Provider>
    </RendererErrorBoundary>
  );
}
