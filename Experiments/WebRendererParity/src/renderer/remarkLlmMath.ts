import {
  mathFromMarkdown,
  mathToMarkdown
} from "mdast-util-math";
import { math } from "micromark-extension-llm-math";
import type { Processor } from "unified";

type ParserData = {
  micromarkExtensions?: unknown[];
  fromMarkdownExtensions?: unknown[];
  toMarkdownExtensions?: unknown[];
};

const options = {
  singleDollarTextMath: false
} as const;

/**
 * Register the LLM-oriented math tokenizer explicitly.
 *
 * Keeping this adapter local avoids relying on a bundler alias inside
 * remark-math, which can differ between Vite's browser and test pipelines.
 */
export default function remarkLlmMath(this: Processor): void {
  const data = this.data() as ParserData;

  const micromarkExtensions =
    data.micromarkExtensions ?? (data.micromarkExtensions = []);
  const fromMarkdownExtensions =
    data.fromMarkdownExtensions ?? (data.fromMarkdownExtensions = []);
  const toMarkdownExtensions =
    data.toMarkdownExtensions ?? (data.toMarkdownExtensions = []);

  micromarkExtensions.push(math(options));
  fromMarkdownExtensions.push(mathFromMarkdown());
  toMarkdownExtensions.push(mathToMarkdown(options));
}
