import fs from "node:fs";
import http from "node:http";

const statsPath = process.argv[2];
if (!statsPath) {
  throw new Error("stats path is required");
}

let catalogGeneration = 0;
const sessionID = "intatis-cli-lifecycle";

const server = http.createServer(async (request, response) => {
  const method = request.method ?? "UNKNOWN";

  if (method === "GET") {
    record("GET");
    response.writeHead(405);
    response.end();
    return;
  }

  if (method === "DELETE") {
    record("DELETE");
    response.writeHead(200);
    response.end();
    return;
  }

  if (method !== "POST") {
    record(method);
    response.writeHead(405);
    response.end();
    return;
  }

  const chunks = [];
  let byteCount = 0;
  for await (const chunk of request) {
    byteCount += chunk.length;
    if (byteCount > 1024 * 1024) {
      response.writeHead(413);
      response.end();
      return;
    }
    chunks.push(chunk);
  }

  const message = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  record(message.method ?? "<response>");
  if (message.id === undefined) {
    response.writeHead(202, {
      "MCP-Session-Id": sessionID
    });
    response.end();
    return;
  }

  let result;
  switch (message.method) {
    case "initialize":
      result = {
        protocolVersion: "2025-06-18",
        serverInfo: {
          name: "intatis-cli-lifecycle",
          version: "1.0.0"
        },
        capabilities: {
          tools: { listChanged: true }
        }
      };
      break;
    case "tools/list":
      catalogGeneration += 1;
      result = {
        tools: [{
          name: "lifecycle_echo",
          title: `Lifecycle Echo ${catalogGeneration}`,
          description: "Real loopback tool used by the Intatis CLI owner E2E.",
          inputSchema: {
            type: "object",
            properties: {
              value: { type: "string" }
            },
            required: ["value"],
            additionalProperties: false
          }
        }]
      };
      break;
    case "tools/call":
      result = {
        content: [{
          type: "text",
          text: String(message.params?.arguments?.value ?? "")
        }],
        isError: false
      };
      break;
    default:
      response.writeHead(400, {
        "Content-Type": "application/json",
        "MCP-Session-Id": sessionID
      });
      response.end(JSON.stringify({
        jsonrpc: "2.0",
        id: message.id,
        error: {
          code: -32601,
          message: `unsupported ${message.method}`
        }
      }));
      return;
  }

  response.writeHead(200, {
    "Content-Type": "application/json",
    "MCP-Session-Id": sessionID
  });
  response.end(JSON.stringify({
    jsonrpc: "2.0",
    id: message.id,
    result
  }));
});

server.listen(0, "127.0.0.1", () => {
  const address = server.address();
  if (!address || typeof address === "string") {
    throw new Error("loopback port unavailable");
  }
  process.stdout.write(`${address.port}\n`);
});

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
  });
}

function record(value) {
  fs.appendFileSync(statsPath, `${value}\n`, {
    encoding: "utf8",
    mode: 0o600
  });
}
