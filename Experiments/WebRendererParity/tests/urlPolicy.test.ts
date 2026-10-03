import { describe, expect, it } from "vitest";
import { safeUrlTransform } from "../src/renderer/urlPolicy";

describe("safeUrlTransform", () => {
  it.each([
    "https://example.com/path",
    "http://example.com",
    "mailto:test@example.com",
    "tel:+1234567",
    "sms:+1234567",
    "sandbox:/mnt/data/file.txt",
    "#section",
    "/relative",
    "./relative",
    "../relative",
    "?query=1"
  ])("allows %s", (value) => {
    expect(safeUrlTransform(value)).toBe(value);
  });

  it.each([
    "javascript:alert(1)",
    "JaVaScRiPt:alert(1)",
    "data:text/html,payload",
    "file:///tmp/secret",
    "ftp://example.com/file",
    "blob:https://example.com/id",
    "//example.com/path",
    "\\\\example.com\\path",
    "/\\example.com/path",
    " javascript:alert(1)",
    "java\nscript:alert(1)",
    "\u0000https://example.com"
  ])("blocks %s", (value) => {
    expect(safeUrlTransform(value)).toBe("");
  });
});
