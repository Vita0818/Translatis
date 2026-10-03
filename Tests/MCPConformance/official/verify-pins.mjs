import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const directory = dirname(fileURLToPath(import.meta.url));
const [metadata, lock, packageManifest] = await Promise.all([
  readJSON(join(directory, "conformance-tool.json")),
  readJSON(join(directory, "package-lock.json")),
  readJSON(join(directory, "package.json"))
]);

const expectedPackage = "@modelcontextprotocol/conformance";
if (
  metadata.package !== expectedPackage ||
  metadata.version !== "0.1.16" ||
  metadata.integrity !==
    "sha512-GI7qiN0r39/MH2srVUR3AXaEN0YLCro20lIBbnvc1frBhszenxvUifBuTzxeVQVagILfBzCIcnungUOma8OrgA==" ||
  metadata.gitHead !== "21a9a2febd7100d7c17ac1021ee7f2ed9f66a1e0" ||
  metadata.license !== "MIT"
) {
  throw new Error("official conformance provenance metadata changed");
}
if (packageManifest.devDependencies?.[expectedPackage] !== metadata.version) {
  throw new Error("package.json does not use the exact conformance version");
}
if (lock.lockfileVersion !== 3) {
  throw new Error("package-lock.json must use lockfileVersion 3");
}
const locked =
  lock.packages?.["node_modules/@modelcontextprotocol/conformance"];
if (
  locked?.version !== metadata.version ||
  locked?.resolved !== metadata.tarball ||
  locked?.integrity !== metadata.integrity
) {
  throw new Error("official conformance package lock identity mismatch");
}

const installedPath = join(
  directory,
  "node_modules",
  "@modelcontextprotocol",
  "conformance",
  "package.json"
);
try {
  const installed = await readJSON(installedPath);
  if (
    installed.name !== expectedPackage ||
    installed.version !== metadata.version ||
    installed.license !== metadata.license
  ) {
    throw new Error("installed conformance package identity mismatch");
  }
} catch (error) {
  if (error?.code === "ENOENT") {
    throw new Error(
      "pinned conformance dependencies are not installed; run npm ci --ignore-scripts"
    );
  }
  throw error;
}

console.log(
  `verified ${metadata.package}@${metadata.version} (${metadata.gitHead})`
);

async function readJSON(path) {
  return JSON.parse(await readFile(path, "utf8"));
}
