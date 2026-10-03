import {
  Compartment,
  EditorState,
  StateEffect,
  StateField,
  type Extension
} from "@codemirror/state";
import {
  Decoration,
  EditorView,
  type DecorationSet
} from "@codemirror/view";
import {
  defaultHighlightStyle,
  syntaxHighlighting
} from "@codemirror/language";
import { languages } from "@codemirror/language-data";
import { useEffect, useRef, useState } from "react";

const STREAM_SETTLE_MILLISECONDS = 500;
const setPendingFrom = StateEffect.define<number | null>();
const loadedLanguageNames = new Set<string>();
let activeEditorViews = 0;

const pendingTailField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, transaction) {
    let next = value.map(transaction.changes);

    for (const effect of transaction.effects) {
      if (!effect.is(setPendingFrom)) {
        continue;
      }

      const from = effect.value;
      next =
        from !== null && from < transaction.state.doc.length
          ? Decoration.set([
              Decoration.mark({ class: "cm-pending-tail" }).range(
                Math.max(0, from),
                transaction.state.doc.length
              )
            ])
          : Decoration.none;
    }

    return next;
  },
  provide: (field) => EditorView.decorations.from(field)
});

const languageAliases: Record<string, string> = {
  bash: "shell",
  c: "c++",
  "c#": "c#",
  cpp: "c++",
  cxx: "c++",
  html: "html",
  js: "javascript",
  jsx: "javascript",
  md: "markdown",
  py: "python",
  rb: "ruby",
  rs: "rust",
  sh: "shell",
  ts: "typescript",
  tsx: "typescript",
  yml: "yaml",
  zsh: "shell"
};

async function languageExtension(name: string): Promise<Extension | null> {
  const input = name.trim().toLowerCase();
  if (!input || input === "text" || input === "plaintext") {
    return null;
  }

  const normalized = languageAliases[input] ?? input;
  const description = languages.find((candidate) => {
    const names = [candidate.name, ...(candidate.alias ?? [])].map((value) =>
      value.toLowerCase()
    );
    return names.includes(normalized) || names.includes(input);
  });

  if (!description) {
    return null;
  }

  const extension = await description.load();
  loadedLanguageNames.add(description.name.toLowerCase());
  return extension;
}

export function getCodeRendererDiagnostics(): {
  activeViews: number;
  loadedLanguages: readonly string[];
} {
  return {
    activeViews: activeEditorViews,
    loadedLanguages: [...loadedLanguageNames].sort()
  };
}

export function canonicalizeFencedCode(value: string): string {
  return value.endsWith("\n") ? value.slice(0, -1) : value;
}

async function copyText(value: string): Promise<void> {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }

  const textarea = document.createElement("textarea");
  textarea.value = value;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "fixed";
  textarea.style.opacity = "0";
  document.body.append(textarea);
  textarea.select();
  document.execCommand("copy");
  textarea.remove();
}

type ParseStatus = "loading" | "highlighted" | "plain";

type CodeBlockProps = {
  code: string;
  language?: string;
  isStreaming: boolean;
  sourceStart?: number;
  sourceEnd?: number;
};

export function CodeBlock({
  code,
  language = "",
  isStreaming,
  sourceStart,
  sourceEnd
}: CodeBlockProps) {
  const hostRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<EditorView | null>(null);
  const languageCompartmentRef = useRef(new Compartment());
  const previousCodeRef = useRef("");
  const previousLanguageRef = useRef("");
  const previousStreamingRef = useRef(false);
  const highlightedLengthRef = useRef(0);
  const generationRef = useRef(0);
  const languageRequestRef = useRef(0);
  const settleTimerRef = useRef<number | null>(null);
  const animationFrameRef = useRef<number | null>(null);
  const copiedTimerRef = useRef<number | null>(null);
  const [highlightedLength, setHighlightedLength] = useState(0);
  const [generation, setGeneration] = useState(0);
  const [parseStatus, setParseStatus] = useState<ParseStatus>("plain");
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!hostRef.current) {
      return;
    }

    const state = EditorState.create({
      doc: code,
      extensions: [
        EditorState.readOnly.of(true),
        EditorView.editable.of(false),
        EditorView.contentAttributes.of({
          "aria-label": `Code block${language ? `: ${language}` : ""}`,
          tabindex: "0",
          spellcheck: "false"
        }),
        syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
        pendingTailField,
        languageCompartmentRef.current.of([])
      ]
    });

    const view = new EditorView({
      state,
      parent: hostRef.current
    });
    activeEditorViews += 1;
    viewRef.current = view;

    return () => {
      if (settleTimerRef.current !== null) {
        window.clearTimeout(settleTimerRef.current);
      }
      if (animationFrameRef.current !== null) {
        window.cancelAnimationFrame(animationFrameRef.current);
      }
      view.destroy();
      activeEditorViews = Math.max(0, activeEditorViews - 1);
      viewRef.current = null;
      previousCodeRef.current = "";
      previousLanguageRef.current = "";
      previousStreamingRef.current = false;
      highlightedLengthRef.current = 0;
    };
  }, []);

  useEffect(() => {
    const view = viewRef.current;
    if (!view) {
      return;
    }

    const request = ++languageRequestRef.current;
    view.dispatch({
      effects: languageCompartmentRef.current.reconfigure([])
    });

    if (!language.trim()) {
      setParseStatus("plain");
      return;
    }

    setParseStatus("loading");
    void languageExtension(language)
      .then((extension) => {
        if (
          request !== languageRequestRef.current ||
          !viewRef.current ||
          viewRef.current !== view
        ) {
          return;
        }

        view.dispatch({
          effects: languageCompartmentRef.current.reconfigure(
            extension ?? []
          )
        });
        setParseStatus(extension ? "highlighted" : "plain");
      })
      .catch(() => {
        if (request === languageRequestRef.current) {
          setParseStatus("plain");
        }
      });
  }, [language]);

  useEffect(() => {
    const view = viewRef.current;
    if (!view) {
      return;
    }

    const previousCode = previousCodeRef.current;
    const previousLanguage = previousLanguageRef.current;
    const changed =
      previousCode !== code ||
      previousLanguage !== language ||
      previousStreamingRef.current !== isStreaming;

    if (!changed) {
      return;
    }

    const currentGeneration = generationRef.current + 1;
    generationRef.current = currentGeneration;
    setGeneration(currentGeneration);

    if (settleTimerRef.current !== null) {
      window.clearTimeout(settleTimerRef.current);
      settleTimerRef.current = null;
    }
    if (animationFrameRef.current !== null) {
      window.cancelAnimationFrame(animationFrameRef.current);
      animationFrameRef.current = null;
    }

    const appendOnly =
      previousLanguage === language && code.startsWith(previousCode);
    const stableLength = appendOnly
      ? Math.min(highlightedLengthRef.current, previousCode.length)
      : 0;
    const pendingFrom =
      isStreaming && stableLength < code.length ? stableLength : null;

    const effects = [setPendingFrom.of(pendingFrom)];
    const documentLength = view.state.doc.length;
    const changes =
      previousCode === code
        ? undefined
        : previousLanguage === language &&
            code.startsWith(previousCode) &&
            documentLength === previousCode.length
          ? {
              from: previousCode.length,
              insert: code.slice(previousCode.length)
            }
          : {
              from: 0,
              to: documentLength,
              insert: code
            };
    view.dispatch({
      changes,
      effects
    });

    if (pendingFrom !== null) {
      highlightedLengthRef.current = pendingFrom;
      setHighlightedLength(pendingFrom);
      settleTimerRef.current = window.setTimeout(() => {
        if (
          generationRef.current !== currentGeneration ||
          !viewRef.current
        ) {
          return;
        }
        viewRef.current.dispatch({ effects: setPendingFrom.of(null) });
        highlightedLengthRef.current = code.length;
        setHighlightedLength(code.length);
        settleTimerRef.current = null;
      }, STREAM_SETTLE_MILLISECONDS);
    } else {
      animationFrameRef.current = window.requestAnimationFrame(() => {
        if (generationRef.current !== currentGeneration || !viewRef.current) {
          return;
        }
        viewRef.current.dispatch({ effects: setPendingFrom.of(null) });
        highlightedLengthRef.current = code.length;
        setHighlightedLength(code.length);
        animationFrameRef.current = null;
      });
    }

    previousCodeRef.current = code;
    previousLanguageRef.current = language;
    previousStreamingRef.current = isStreaming;
  }, [code, isStreaming, language]);

  useEffect(
    () => () => {
      languageRequestRef.current += 1;
      if (copiedTimerRef.current !== null) {
        window.clearTimeout(copiedTimerRef.current);
      }
    },
    []
  );

  const handleCopy = async () => {
    await copyText(code);
    setCopied(true);
    if (copiedTimerRef.current !== null) {
      window.clearTimeout(copiedTimerRef.current);
    }
    copiedTimerRef.current = window.setTimeout(() => {
      setCopied(false);
      copiedTimerRef.current = null;
    }, 1500);
  };

  const pendingLength = Math.max(0, code.length - highlightedLength);
  const label = language.trim() || "text";

  return (
    <section
      className="code-block"
      data-code-block
      data-language={language}
      data-highlighted-length={highlightedLength}
      data-pending-length={pendingLength}
      data-generation={generation}
      data-parse-status={parseStatus}
      data-source-start={sourceStart}
      data-source-end={sourceEnd}
    >
      <div className="code-toolbar">
        <span className="code-language">{label}</span>
        <button
          className="copy-button"
          type="button"
          aria-label="Copy"
          onClick={() => void handleCopy()}
        >
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
      <div className="code-scroller">
        <div ref={hostRef} data-testid="code-viewer" />
      </div>
    </section>
  );
}
