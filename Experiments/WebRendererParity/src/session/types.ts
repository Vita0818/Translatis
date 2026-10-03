export type ConversationRole = "user" | "assistant";

export interface ConversationMessage {
  readonly id: string;
  readonly role: ConversationRole;
  readonly source: string;
  readonly isStreaming?: boolean;
}

export interface ConversationSession {
  readonly id: string;
  readonly title: string;
  readonly description: string;
  readonly messages: readonly ConversationMessage[];
}
