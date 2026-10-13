import type { Env } from "../env";

/**
 * One interface for every model provider the in-app assistant can use. Each request asks
 * for a single JSON object matching `schema`; the caller validates it again with zod.
 * Requests go through Cloudflare AI Gateway; keys come from Worker secrets only.
 */

export type JsonSchema = Record<string, unknown>;

export interface AiRequest {
  /** Short identifier for logs and the gateway (e.g. "parse_task"). */
  name: string;
  system: string;
  prompt: string;
  /** JSON Schema of the object to return: every object closed, every property required. */
  schema: JsonSchema;
  maxTokens?: number;
}

export interface AiUsage {
  input: number;
  output: number;
}

export interface AiResult {
  json: unknown;
  usage: AiUsage;
}

export interface AiProvider {
  readonly name: string;
  complete(request: AiRequest): Promise<AiResult>;
}

/** The provider failed, refused, was cut off, or returned something that is not JSON. */
export class AiError extends Error {
  override name = "AiError";
}

type Fetch = typeof fetch;

interface ProviderOptions {
  apiKey: string;
  /** AI Gateway base, e.g. https://gateway.ai.cloudflare.com/v1/<account>/<gateway>. */
  gatewayUrl: string;
  /** For an authenticated gateway. */
  gatewayToken?: string;
  model?: string;
  fetch?: Fetch;
}

/**
 * Claude Haiku 5.5: the cheapest current Claude model, strong in Arabic, and it supports
 * structured outputs. Thinking stays adaptive at low effort, which keeps cost down while
 * leaving room to resolve dates.
 */
export const ANTHROPIC_MODEL = "claude-haiku-5-5";
export const DEEPSEEK_MODEL = "deepseek-chat";
const DEFAULT_MAX_TOKENS = 4096;

function base(url: string): string {
  return url.replace(/\/+$/, "");
}

function parseJson(text: string): unknown {
  // Tolerates a fenced block, which DeepSeek sometimes adds even in JSON mode.
  const trimmed = text.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  try {
    return JSON.parse(trimmed);
  } catch {
    throw new AiError("Model output is not JSON");
  }
}

async function post(doFetch: Fetch, url: string, headers: Record<string, string>, body: unknown): Promise<unknown> {
  let response: Response;
  try {
    response = await doFetch(url, { method: "POST", headers, body: JSON.stringify(body) });
  } catch (err) {
    throw new AiError(`Provider unreachable: ${(err as Error).message}`);
  }
  if (!response.ok) {
    const detail = (await response.text().catch(() => "")).slice(0, 300);
    throw new AiError(`Provider returned ${response.status}: ${detail}`);
  }
  try {
    return await response.json();
  } catch {
    throw new AiError("Provider response is not JSON");
  }
}

function gatewayHeaders(o: ProviderOptions): Record<string, string> {
  return o.gatewayToken ? { "cf-aig-authorization": `Bearer ${o.gatewayToken}` } : {};
}

/** Anthropic Messages API through the gateway, with structured output (`output_config.format`). */
export class AnthropicProvider implements AiProvider {
  readonly name = "anthropic";
  constructor(private readonly o: ProviderOptions) {}

  async complete(request: AiRequest): Promise<AiResult> {
    const body = {
      model: this.o.model ?? ANTHROPIC_MODEL,
      max_tokens: request.maxTokens ?? DEFAULT_MAX_TOKENS,
      system: request.system,
      messages: [{ role: "user", content: request.prompt }],
      output_config: { effort: "low", format: { type: "json_schema", schema: request.schema } },
    };
    const headers = {
      "content-type": "application/json",
      "x-api-key": this.o.apiKey,
      "anthropic-version": "2023-06-01",
      ...gatewayHeaders(this.o),
    };
    const data = (await post(this.o.fetch ?? fetch, `${base(this.o.gatewayUrl)}/anthropic/v1/messages`, headers, body)) as {
      stop_reason?: string;
      content?: { type: string; text?: string }[];
      usage?: { input_tokens?: number; output_tokens?: number };
    };
    if (data.stop_reason === "refusal") throw new AiError("Model declined the request");
    if (data.stop_reason === "max_tokens") throw new AiError("Model output was cut off");
    // A response can begin with thinking blocks; read text blocks by type.
    const text = (data.content ?? [])
      .filter((b) => b.type === "text")
      .map((b) => b.text ?? "")
      .join("");
    return {
      json: parseJson(text),
      usage: { input: data.usage?.input_tokens ?? 0, output: data.usage?.output_tokens ?? 0 },
    };
  }
}

/** DeepSeek's OpenAI-compatible chat completions through the gateway, in JSON mode. */
export class DeepSeekProvider implements AiProvider {
  readonly name = "deepseek";
  constructor(private readonly o: ProviderOptions) {}

  async complete(request: AiRequest): Promise<AiResult> {
    // JSON mode has no schema parameter, so the schema goes in the system message.
    const system = `${request.system}\n\nReply with one JSON object only, matching this JSON Schema:\n${JSON.stringify(request.schema)}`;
    const body = {
      model: this.o.model ?? DEEPSEEK_MODEL,
      max_tokens: request.maxTokens ?? DEFAULT_MAX_TOKENS,
      messages: [
        { role: "system", content: system },
        { role: "user", content: request.prompt },
      ],
      response_format: { type: "json_object" },
    };
    const headers = {
      "content-type": "application/json",
      authorization: `Bearer ${this.o.apiKey}`,
      ...gatewayHeaders(this.o),
    };
    const data = (await post(this.o.fetch ?? fetch, `${base(this.o.gatewayUrl)}/deepseek/chat/completions`, headers, body)) as {
      choices?: { finish_reason?: string; message?: { content?: string | null } }[];
      usage?: { prompt_tokens?: number; completion_tokens?: number };
    };
    const choice = data.choices?.[0];
    if (!choice) throw new AiError("Provider returned no choices");
    if (choice.finish_reason === "length") throw new AiError("Model output was cut off");
    return {
      json: parseJson(choice.message?.content ?? ""),
      usage: { input: data.usage?.prompt_tokens ?? 0, output: data.usage?.completion_tokens ?? 0 },
    };
  }
}

/** Not configured: every call fails, which the routes report as `ai_unavailable`. */
class MissingProvider implements AiProvider {
  constructor(
    readonly name: string,
    private readonly reason: string,
  ) {}
  async complete(): Promise<AiResult> {
    throw new AiError(this.reason);
  }
}

/** The provider named by `AI_PROVIDER`, with its key from the Worker's secrets. */
export function providerFromEnv(env: Env, doFetch?: Fetch): AiProvider {
  const common = { gatewayUrl: env.AI_GATEWAY_URL, gatewayToken: env.AI_GATEWAY_TOKEN, model: env.AI_MODEL, fetch: doFetch };
  const name = (env.AI_PROVIDER ?? "anthropic").trim().toLowerCase();
  if (!env.AI_GATEWAY_URL) return new MissingProvider(name, "AI_GATEWAY_URL is not set");
  if (name === "anthropic") {
    return env.ANTHROPIC_API_KEY
      ? new AnthropicProvider({ ...common, apiKey: env.ANTHROPIC_API_KEY })
      : new MissingProvider(name, "ANTHROPIC_API_KEY is not set");
  }
  if (name === "deepseek") {
    return env.DEEPSEEK_API_KEY
      ? new DeepSeekProvider({ ...common, apiKey: env.DEEPSEEK_API_KEY })
      : new MissingProvider(name, "DEEPSEEK_API_KEY is not set");
  }
  return new MissingProvider(name, `Unknown AI_PROVIDER "${name}"`);
}
