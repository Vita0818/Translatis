import { useEffect, useMemo, useRef, useState } from "react";
import type { ConversationSession } from "../session/types";
import { ViewportMessage } from "./ViewportMessage";

const INITIAL_MESSAGE_COUNT = 12;
const MESSAGE_PAGE_SIZE = 10;

type ConversationPaneProps = {
  session: ConversationSession;
  generation: number;
};

export function ConversationPane({
  session,
  generation
}: ConversationPaneProps) {
  const scrollRootRef = useRef<HTMLDivElement>(null);
  const nearBottomRef = useRef(true);
  const scrollFrameRef = useRef<number | null>(null);
  const [visibleCount, setVisibleCount] = useState(INITIAL_MESSAGE_COUNT);

  useEffect(() => {
    setVisibleCount(INITIAL_MESSAGE_COUNT);
    nearBottomRef.current = true;
  }, [generation, session.id]);

  const visibleMessages = useMemo(
    () => session.messages.slice(-visibleCount),
    [session.messages, visibleCount]
  );
  const hiddenCount = Math.max(0, session.messages.length - visibleMessages.length);
  const lastMessage = visibleMessages.at(-1);

  useEffect(() => {
    const root = scrollRootRef.current;
    if (!root || !nearBottomRef.current) {
      return;
    }

    if (scrollFrameRef.current !== null) {
      window.cancelAnimationFrame(scrollFrameRef.current);
    }
    scrollFrameRef.current = window.requestAnimationFrame(() => {
      if (scrollRootRef.current) {
        scrollRootRef.current.scrollTop = scrollRootRef.current.scrollHeight;
      }
      scrollFrameRef.current = null;
    });

    return () => {
      if (scrollFrameRef.current !== null) {
        window.cancelAnimationFrame(scrollFrameRef.current);
        scrollFrameRef.current = null;
      }
    };
  }, [
    generation,
    lastMessage?.id,
    lastMessage?.isStreaming,
    lastMessage?.source.length
  ]);

  return (
    <section
      className="conversation-pane"
      data-message-subtree
      data-session-id={session.id}
      data-generation={generation}
      aria-label={`${session.title} conversation`}
    >
      <header className="conversation-heading">
        <div>
          <p className="eyebrow">Active conversation</p>
          <h2>{session.title}</h2>
          <p>{session.description}</p>
        </div>
        <span className="generation-badge">generation {generation}</span>
      </header>

      <div
        ref={scrollRootRef}
        className="conversation-scroll"
        onScroll={(event) => {
          const element = event.currentTarget;
          const distance =
            element.scrollHeight - element.scrollTop - element.clientHeight;
          nearBottomRef.current = distance < 160;
        }}
      >
        {hiddenCount > 0 ? (
          <button
            className="load-older"
            type="button"
            onClick={() =>
              setVisibleCount((current) =>
                Math.min(session.messages.length, current + MESSAGE_PAGE_SIZE)
              )
            }
          >
            Load {Math.min(MESSAGE_PAGE_SIZE, hiddenCount)} older messages
          </button>
        ) : (
          <p className="history-start">Beginning of local sample</p>
        )}

        <div className="message-list">
          {visibleMessages.map((message) => (
            <ViewportMessage
              key={message.id}
              message={message}
              scrollRootRef={scrollRootRef}
            />
          ))}
        </div>
      </div>
    </section>
  );
}
