import katex from "katex";

const MAX_CACHE_ENTRIES = 256;
const MAX_CACHE_KEY_LENGTH = 4096;
const MAX_CACHE_CHARACTERS = 512 * 1024;

type MathResult =
  | {
      kind: "html";
      html: string;
      parseError: boolean;
    }
  | {
      kind: "literal";
      message: string;
    };

type MathCacheEntry = {
  result: MathResult;
  characters: number;
};

const renderCache = new Map<string, MathCacheEntry>();
let cachedCharacters = 0;

function resultCharacters(result: MathResult): number {
  return result.kind === "html" ? result.html.length : result.message.length;
}

function deleteCacheEntry(key: string): void {
  const entry = renderCache.get(key);
  if (!entry) {
    return;
  }
  cachedCharacters = Math.max(0, cachedCharacters - entry.characters);
  renderCache.delete(key);
}

function cacheResult(key: string, result: MathResult): void {
  if (key.length > MAX_CACHE_KEY_LENGTH) {
    return;
  }

  const characters = key.length + resultCharacters(result);
  if (characters > MAX_CACHE_CHARACTERS) {
    return;
  }

  deleteCacheEntry(key);
  renderCache.set(key, { result, characters });
  cachedCharacters += characters;

  while (
    renderCache.size > MAX_CACHE_ENTRIES ||
    cachedCharacters > MAX_CACHE_CHARACTERS
  ) {
    const oldest = renderCache.keys().next().value;
    if (typeof oldest !== "string") {
      break;
    }
    deleteCacheEntry(oldest);
  }
}

function katexOptions(displayMode: boolean) {
  return {
    displayMode,
    output: "htmlAndMathml" as const,
    trust: false,
    maxExpand: 1000,
    maxSize: 10,
    strict: "warn" as const
  };
}

function renderMath(source: string, displayMode: boolean): MathResult {
  const key = `${displayMode ? "block" : "inline"}\u0000${source}`;
  const cached = renderCache.get(key);
  if (cached) {
    renderCache.delete(key);
    renderCache.set(key, cached);
    return cached.result;
  }

  try {
    const result: MathResult = {
      kind: "html",
      html: katex.renderToString(source, {
        ...katexOptions(displayMode),
        throwOnError: true
      }),
      parseError: false
    };
    cacheResult(key, result);
    return result;
  } catch (error) {
    if (error instanceof katex.ParseError) {
      const result: MathResult = {
        kind: "html",
        html: katex.renderToString(source, {
          ...katexOptions(displayMode),
          strict: "ignore",
          throwOnError: false
        }),
        parseError: true
      };
      cacheResult(key, result);
      return result;
    }

    const result: MathResult = {
      kind: "literal",
      message: error instanceof Error ? error.message : "Unknown KaTeX error"
    };
    cacheResult(key, result);
    return result;
  }
}

type MathRendererProps = {
  source: string;
  displayMode: boolean;
  isStreaming: boolean;
};

export function MathRenderer({
  source,
  displayMode,
  isStreaming
}: MathRendererProps) {
  const result = renderMath(source, displayMode);
  const Element = "span";

  if (result.kind === "literal") {
    const open = displayMode ? "\\[" : "\\(";
    const close = displayMode ? "\\]" : "\\)";
    return (
      <Element
        className={`math-view ${displayMode ? "math-display" : "math-inline"} math-literal-fallback`}
        data-math-source={source}
        data-math-status="literal-fallback"
        title={result.message}
      >
        {open}
        {source}
        {close}
      </Element>
    );
  }

  return (
    <Element
      className={[
        "math-view",
        displayMode ? "math-display" : "math-inline",
        result.parseError ? "has-parse-error" : "",
        result.parseError && isStreaming ? "is-streaming-error" : ""
      ]
        .filter(Boolean)
        .join(" ")}
      data-math-source={source}
      data-math-status={result.parseError ? "parse-error" : "rendered"}
      dangerouslySetInnerHTML={{ __html: result.html }}
    />
  );
}

export function resetMathCacheForTests(): void {
  renderCache.clear();
  cachedCharacters = 0;
}

export function getMathCacheDiagnostics(): {
  entries: number;
  characters: number;
  maximumCharacters: number;
} {
  return {
    entries: renderCache.size,
    characters: cachedCharacters,
    maximumCharacters: MAX_CACHE_CHARACTERS
  };
}
