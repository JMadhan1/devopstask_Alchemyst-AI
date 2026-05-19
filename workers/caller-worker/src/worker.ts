import { Logger, registerWorker } from "iii-sdk";

// III_URL is injected at runtime by the systemd unit on caller-vm.
// It points to the engine's private IP: ws://10.0.1.X:49134
const iii = registerWorker(process.env.III_URL ?? "ws://localhost:49134");
const logger = new Logger();

// ── Cross-language RPC bridge ─────────────────────────────────────────────────
// Receives a messages payload, fans it out to the Python inference worker,
// and returns the result.

iii.registerFunction(
  "inference::get_response",
  async (payload: { messages: Record<string, any>[] } & Record<string, any>) => {
    logger.info("inference::get_response called", payload);

    const result = await iii.trigger({
      function_id: "inference::run_inference",
      payload,
    });

    return result;
  },
);

// ── HTTP endpoint: POST /v1/chat/completions ──────────────────────────────────
// OpenAI-compatible shape so existing tooling works without changes.

iii.registerFunction(
  "http::run_inference_over_http",
  async (payload: {
    body: { messages: Record<string, any>[]; max_tokens?: number };
  }) => {
    logger.info("POST /v1/chat/completions received");

    const result = await iii.trigger({
      function_id: "inference::get_response",
      payload: payload.body,
    });

    return {
      status_code: 200,
      headers: { "Content-Type": "application/json" },
      body: {
        object: "chat.completion",
        choices: [
          {
            index: 0,
            message: {
              role: "assistant",
              // result.response is the decoded model output from inference_worker.py
              content: (result as any)?.response ?? JSON.stringify(result),
            },
            finish_reason: "stop",
          },
        ],
        model: (result as any)?.model ?? "gemma-3-gguf",
      },
    };
  },
);

iii.registerTrigger({
  type: "http",
  function_id: "http::run_inference_over_http",
  config: { api_path: "/v1/chat/completions", http_method: "POST" },
});

logger.info(
  "caller-worker connected to %s — listening on POST /v1/chat/completions",
  process.env.III_URL ?? "ws://localhost:49134",
);
