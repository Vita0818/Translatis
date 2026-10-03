import { mkdir, readFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const directory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(directory, "../../..");
const manifest = JSON.parse(
  await readFile(join(directory, "scenario-manifest.json"), "utf8")
);
const runner = join(directory, "node_modules", ".bin", "conformance");
const client = process.env.TRANSLATIS_MCP_CONFORMANCE_CLIENT;
if (!client) {
  throw new Error("TRANSLATIS_MCP_CONFORMANCE_CLIENT is required");
}
if (
  manifest.schemaVersion !== 1 ||
  manifest.runnerVersion !== "0.1.16" ||
  manifest.profiles.length !== 2
) {
  throw new Error("invalid conformance scenario manifest");
}

const requestedProfile = process.argv[2];
const profiles = requestedProfile
  ? manifest.profiles.filter((entry) => entry.profile === requestedProfile)
  : manifest.profiles;
if (requestedProfile && profiles.length !== 1) {
  throw new Error(`unknown profile ${requestedProfile}`);
}

const resultsRoot = join(repositoryRoot, ".build", "mcp-conformance-results");
await mkdir(resultsRoot, { recursive: true });
let total = 0;

for (const entry of profiles) {
  assertUnique(entry.scenarios, `${entry.profile} scenarios`);
  const official = officialScenarios(entry.protocolVersion);
  assertSameSet(
    entry.scenarios,
    official,
    `${entry.profile}/${entry.protocolVersion}`
  );

  const executed = [];
  for (const scenario of entry.scenarios) {
    const result = spawnSync(
      runner,
      [
        "client",
        "--command",
        `${client} ${entry.profile}`,
        "--scenario",
        scenario,
        "--spec-version",
        entry.protocolVersion,
        "--timeout",
        "45000",
        "--output-dir",
        join(resultsRoot, entry.profile)
      ],
      {
        cwd: repositoryRoot,
        stdio: "inherit",
        env: process.env
      }
    );
    if (result.error) {
      throw result.error;
    }
    if (result.status !== 0) {
      throw new Error(
        `official conformance failed: ${entry.profile}/${scenario} (exit ${result.status})`
      );
    }
    executed.push(scenario);
    total += 1;
  }
  assertSameSet(
    executed,
    entry.scenarios,
    `${entry.profile} executed scenarios`
  );
}

console.log(
  `official MCP client conformance complete: ${total} scenarios, zero expected failures`
);

function officialScenarios(version) {
  const result = spawnSync(
    runner,
    ["list", "--client", "--spec-version", version],
    { cwd: repositoryRoot, encoding: "utf8", env: process.env }
  );
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(
      `official scenario enumeration failed for ${version}: ${result.stderr}`
    );
  }
  const scenarios = result.stdout
    .split(/\r?\n/)
    .map((line) => line.match(/^\s+-\s+([^\s[]+)/)?.[1])
    .filter(Boolean);
  if (scenarios.length === 0) {
    throw new Error(`official runner returned no scenarios for ${version}`);
  }
  return scenarios;
}

function assertUnique(values, label) {
  if (new Set(values).size !== values.length) {
    throw new Error(`${label} contains duplicates`);
  }
}

function assertSameSet(actual, expected, label) {
  const left = [...new Set(actual)].sort();
  const right = [...new Set(expected)].sort();
  if (
    left.length !== right.length ||
    left.some((value, index) => value !== right[index])
  ) {
    const missing = right.filter((value) => !left.includes(value));
    const extra = left.filter((value) => !right.includes(value));
    throw new Error(
      `${label} scenario coverage mismatch; missing=${missing.join(",") || "none"}; extra=${extra.join(",") || "none"}`
    );
  }
}
