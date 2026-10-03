const allowedSchemes = new Set([
  "http",
  "https",
  "mailto",
  "tel",
  "sms",
  "sandbox"
]);

const controlOrSpace = /[\u0000-\u0020\u007f]/;
const explicitScheme = /^([a-z][a-z0-9+.-]*):/i;

export function safeUrlTransform(value: string): string {
  const candidate = value.trim();

  if (candidate.length === 0 || controlOrSpace.test(candidate)) {
    return "";
  }

  // Do not let an apparent local path become a scheme-relative remote URL
  // after browser normalization.
  if (
    candidate.startsWith("\\") ||
    candidate.startsWith("//") ||
    candidate.startsWith("/\\")
  ) {
    return "";
  }

  if (
    candidate.startsWith("#") ||
    candidate.startsWith("/") ||
    candidate.startsWith("./") ||
    candidate.startsWith("../") ||
    candidate.startsWith("?")
  ) {
    return candidate;
  }

  const scheme = explicitScheme.exec(candidate);
  if (!scheme) {
    return candidate;
  }

  return allowedSchemes.has(scheme[1].toLowerCase()) ? candidate : "";
}

export function isSandboxUrl(value: string): boolean {
  return value.trim().toLowerCase().startsWith("sandbox:");
}
