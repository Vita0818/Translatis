import {
  memo,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type RefObject
} from "react";
import { MarkdownRenderer } from "../renderer/MarkdownRenderer";
import type { ConversationMessage } from "../session/types";

type ViewportMessageProps = {
  message: ConversationMessage;
  scrollRootRef: RefObject<HTMLElement | null>;
};

function ViewportMessageComponent({
  message,
  scrollRootRef
}: ViewportMessageProps) {
  const hostRef = useRef<HTMLElement>(null);
  const measuredHeightRef = useRef(96);
  const [isNearViewport, setIsNearViewport] = useState(true);

  useLayoutEffect(() => {
    const host = hostRef.current;
    if (!host || !isNearViewport) {
      return;
    }

    const measure = () => {
      measuredHeightRef.current = Math.max(
        72,
        Math.ceil(host.getBoundingClientRect().height)
      );
    };

    measure();

    if (typeof ResizeObserver === "undefined") {
      return;
    }

    const observer = new ResizeObserver(measure);
    observer.observe(host);
    return () => observer.disconnect();
  }, [isNearViewport, message.id]);

  useEffect(() => {
    const host = hostRef.current;
    if (!host || typeof IntersectionObserver === "undefined") {
      return;
    }

    const observer = new IntersectionObserver(
      (entries) => {
        const entry = entries[0];
        if (entry) {
          setIsNearViewport(entry.isIntersecting);
        }
      },
      {
        root: scrollRootRef.current,
        rootMargin: "900px 0px",
        threshold: 0
      }
    );

    observer.observe(host);
    return () => observer.disconnect();
  }, [message.id, scrollRootRef]);

  const isUser = message.role === "user";

  return (
    <article
      ref={hostRef}
      className={`conversation-message message-${message.role}`}
      data-message-id={message.id}
      data-message-mounted={isNearViewport ? "true" : "false"}
      style={
        isNearViewport
          ? undefined
          : { minHeight: `${measuredHeightRef.current}px` }
      }
    >
      <div className="message-gutter" aria-hidden="true">
        {isUser ? "Y" : "R"}
      </div>
      <div className="message-content">
        <p className="message-author">
          {isUser ? "You" : "Renderer"}
          {message.isStreaming ? (
            <span className="streaming-indicator">streaming</span>
          ) : null}
        </p>
        {isNearViewport ? (
          <MarkdownRenderer
            source={message.source}
            isStreaming={message.isStreaming ?? false}
          />
        ) : (
          <div className="message-placeholder" aria-hidden="true">
            Content released outside the viewport
          </div>
        )}
      </div>
    </article>
  );
}

export const ViewportMessage = memo(
  ViewportMessageComponent,
  (previous, next) =>
    previous.message.id === next.message.id &&
    previous.message.role === next.message.role &&
    previous.message.source === next.message.source &&
    previous.message.isStreaming === next.message.isStreaming &&
    previous.scrollRootRef === next.scrollRootRef
);
