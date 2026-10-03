import { readFile, readdir } from "node:fs/promises";
import { join } from "node:path";

const root = new URL("..", import.meta.url);
const nodeModules = new URL("node_modules/", root);
const accepted = [
  /\bMIT\b/i,
  /\bISC\b/i,
  /\bBSD-2-Clause\b/i,
  /\bBSD-3-Clause\b/i,
  /\bApache-2\.0\b/i,
  /\b0BSD\b/i,
  /\bCC0-1\.0\b/i,
  /\bBlueOak-1\.0\.0\b/i
];

async function packageDirectories() {
  const entries = await readdir(nodeModules, { withFileTypes: true });
  const directories = [];

  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name === ".bin") {
      continue;
    }

    if (!entry.name.startsWith("@")) {
      directories.push(join(nodeModules.pathname, entry.name));
      continue;
    }

    const scopePath = join(nodeModules.pathname, entry.name);
    const scopedEntries = await readdir(scopePath, { withFileTypes: true });
    for (const scopedEntry of scopedEntries) {
      if (scopedEntry.isDirectory()) {
        directories.push(join(scopePath, scopedEntry.name));
      }
    }
  }

  return directories;
}

const inventory = [];
const rejected = [];

for (const directory of await packageDirectories()) {
  try {
    const packageJSON = JSON.parse(
      await readFile(join(directory, "package.json"), "utf8")
    );
    const license =
      typeof packageJSON.license === "string"
        ? packageJSON.license
        : "UNKNOWN";
    const item = {
      name: packageJSON.name ?? directory,
      version: packageJSON.version ?? "UNKNOWN",
      license
    };
    inventory.push(item);
    if (!accepted.some((pattern) => pattern.test(license))) {
      rejected.push(item);
    }
  } catch {
    // npm may create non-package support directories. They are not inventory
    // entries unless they carry a package.json.
  }
}

inventory.sort((left, right) =>
  `${left.name}@${left.version}`.localeCompare(
    `${right.name}@${right.version}`
  )
);

console.log(
  JSON.stringify(
    {
      packages: inventory.length,
      rejected,
      inventory
    },
    null,
    2
  )
);

if (rejected.length > 0) {
  process.exitCode = 1;
}
