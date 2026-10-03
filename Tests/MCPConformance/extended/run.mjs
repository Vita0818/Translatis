import http from "node:http";
import { spawn } from "node:child_process";

const client = process.env.TRANSLATIS_MCP_CONFORMANCE_CLIENT;
if (!client) throw new Error("TRANSLATIS_MCP_CONFORMANCE_CLIENT is required");

const scenarios = [
  "translatis/task-complete",
  "translatis/task-timeout",
  "translatis/task-cancel"
];

for (const scenario of scenarios) {
  const observed = [];
  const taskID = `remote-${scenario.split("/").at(-1)}`;
  const peer = http.createServer((request, response) => {
    void handle(request, response, scenario, taskID, observed);
  });
  await new Promise((resolve, reject) => {
    peer.once("error", reject);
    peer.listen(0, "127.0.0.1", resolve);
  });
  const address = peer.address();
  if (!address || typeof address === "string") {
    throw new Error("fixture did not expose a loopback port");
  }
  try {
    const result = await runClient(
      client,
      scenario,
      `http://127.0.0.1:${address.port}/mcp`
    );
    if (result.code !== 0) {
      throw new Error(
        `${scenario} client failed (${result.code}): ${result.stderr}`
      );
    }
    const methods = observed.map((entry) => entry.method);
    assertSubsequence(
      methods,
      scenario === "translatis/task-complete"
        ? ["tools/call", "tasks/get", "tasks/result"]
        : ["tools/call", "tasks/get", "tasks/cancel"],
      scenario
    );
    if (methods.includes("notifications/cancelled")) {
      throw new Error(`${scenario} used ordinary cancellation for a mapped task`);
    }
    const taskRequests = observed.filter((entry) =>
      ["tasks/get", "tasks/result", "tasks/cancel"].includes(entry.method)
    );
    if (taskRequests.some((entry) => entry.taskID !== taskID)) {
      throw new Error(`${scenario} crossed the exact remote task identity`);
    }
  } finally {
    await new Promise((resolve) => peer.close(resolve));
  }
}

console.log(
  "Translatis MCP extended interoperability complete: task creation, poll, result, timeout, and cancellation"
);

async function handle(request, response, scenario, taskID, observed) {
  if (request.method === "GET") {
    response.writeHead(405);
    response.end();
    return;
  }
  if (request.method === "DELETE") {
    response.writeHead(200);
    response.end();
    return;
  }
  if (request.method !== "POST") {
    response.writeHead(405);
    response.end();
    return;
  }

  const body = await boundedBody(request, 1024 * 1024);
  const message = JSON.parse(body);
  const method = message.method ?? "<response>";
  observed.push({
    method,
    taskID: message.params?.taskId
  });

  if (message.id === undefined) {
    response.writeHead(202, { "MCP-Session-Id": "task-session" });
    response.end();
    return;
  }

  const now = "2025-11-25T10:30:00Z";
  let result;
  switch (method) {
    case "initialize":
      result = {
        protocolVersion: "2025-11-25",
        serverInfo: { name: "translatis-task-peer", version: "1.0.0" },
        capabilities: {
          tools: {},
          tasks: {
            cancel: {},
            requests: { tools: { call: {} } }
          }
        }
      };
      break;
    case "tools/list":
      result = {
        tools: [{
          name: "long_task",
          description: "W10 task fixture",
          inputSchema: { type: "object", additionalProperties: false },
          execution: { taskSupport: "required" }
        }]
      };
      break;
    case "tools/call":
      if (!message.params?.task) {
        throw new Error(`${scenario} omitted task augmentation metadata`);
      }
      result = {
        task: taskWire(taskID, "working", now)
      };
      break;
    case "tasks/get":
      result = taskWire(
        taskID,
        scenario === "translatis/task-complete" ? "completed" : "working",
        now
      );
      break;
    case "tasks/result":
      result = {
        content: [{ type: "text", text: "task complete" }],
        isError: false,
        _meta: {
          "io.modelcontextprotocol/related-task": { taskId: taskID }
        }
      };
      break;
    case "tasks/cancel":
      result = taskWire(taskID, "cancelled", now);
      break;
    default:
      response.writeHead(400, { "Content-Type": "application/json" });
      response.end(JSON.stringify({
        jsonrpc: "2.0",
        id: message.id,
        error: { code: -32601, message: `unsupported ${method}` }
      }));
      return;
  }

  response.writeHead(200, {
    "Content-Type": "application/json",
    "MCP-Session-Id": "task-session"
  });
  response.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
}

function taskWire(taskId, status, timestamp) {
  return {
    taskId,
    status,
    createdAt: timestamp,
    lastUpdatedAt: timestamp,
    ttl: 60000,
    pollInterval: 75
  };
}

async function boundedBody(request, maximum) {
  const chunks = [];
  let count = 0;
  for await (const chunk of request) {
    count += chunk.length;
    if (count > maximum) throw new Error("fixture request exceeded cap");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

function runClient(command, scenario, endpoint) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, ["standard-extended", endpoint], {
      env: {
        ...process.env,
        MCP_CONFORMANCE_SCENARIO: scenario
      },
      stdio: ["ignore", "pipe", "pipe"]
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (value) => { stdout += value; });
    child.stderr.on("data", (value) => { stderr += value; });
    child.once("error", reject);
    child.once("close", (code) => resolve({ code, stdout, stderr }));
  });
}

function assertSubsequence(actual, expected, label) {
  let cursor = 0;
  for (const value of actual) {
    if (value === expected[cursor]) cursor += 1;
  }
  if (cursor !== expected.length) {
    throw new Error(
      `${label} missing ordered chain ${expected.join(" -> ")}; observed=${actual.join(",")}`
    );
  }
}
