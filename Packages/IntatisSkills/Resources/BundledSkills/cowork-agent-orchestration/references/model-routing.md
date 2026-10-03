# Model routing reference

Research snapshot: 2026-08-02.

Read this resource only when considering an explicit child
`inference_profile_id`. It is a routing aid, not a billing engine, benchmark, model
catalog, or permission grant.

## Authority and freshness

The current invocation's `list_inference_profiles` result is authoritative for what
Intatis may select. It exposes only host-approved, secret-free IDs, labels, model IDs,
variants, and configuration-declared capabilities. Capabilities on that exact line
are authoritative for routing; `unspecified` never proves support. This reference
cannot establish that a route is configured, reachable, or permitted.

Vendor positioning and list prices change. The examples below are a dated snapshot
of official vendor material, not an independent quality ranking. Never synthesize a
profile from these names, and never infer an endpoint, credential, wire protocol,
trust domain, context limit, lifecycle, price, or capability from a family name. If
an exact listed profile cannot be mapped confidently, say that freshness/cost is
unknown and inherit the issuer's exact revision, except when a required multimodal
capability forces selection of another explicitly capable listed profile.

## Selection order

Use this order. Lower items cannot repair a failure above them:

1. **Required capabilities:** keep only profiles explicitly declaring every input,
   output, tool, generation, or editing capability the WorkTask needs.
2. **Active lifecycle and availability:** reject known retired/deprecated routes;
   prefer stable/GA over preview when both are adequate.
3. **Task adequacy:** keep only tiers likely to meet the task's quality and context
   demands without relying on repeated repair.
4. **Release recency:** among adequate active configured candidates, prefer the newer
   generation when the exact identity can be matched to current official evidence.
5. **Expected total cost and latency:** apply `cost-first`,
   `cost-efficient-balanced`, or `efficiency-first`. Include coordination, retries,
   validation, and delay rather than comparing token prices alone.

For an unrecognized custom model ID, a private alias, or a provider whose official
facts do not match the configured exact ID, do not invent a release date or price.
Declared capabilities still apply, but freshness and cost remain unknown.

## Multimodal capability gate

| Task requirement | Required declaration | Pairing rule when main lacks it |
| --- | --- | --- |
| Inspect an image, screenshot, diagram, scan, or visual PDF page | `vision_input` | Route the visual inspection to a secondary exact profile with `vision_input`. |
| Understand recorded audio | `audio_input` or the exact supported transcription path | Route the audio evidence to a declared-capable secondary. |
| Transcribe a live stream | `realtime_transcription` | Use a secondary that explicitly declares realtime transcription. |
| Generate an image/audio/video | `image_generation`, `audio_output`, or `video_generation` | Delegate creation to the matching declared-capable secondary/service. |
| Edit an existing image/video | `image_editing` or `video_editing`; also require the relevant input capability when inspection is necessary | Delegate the edit and its source artifact to a profile declaring every required capability. |

The secondary is mandatory when the main profile lacks the required declaration,
even if the main remains the best planner or coder. Default the secondary to
read-only and no coordination authority. A successful route also requires the real
attachment/artifact to be available to that secondary; if Intatis cannot transfer
it, report the handoff as blocked rather than accepting a text-only guess.

## Choose a capability tier before a vendor

| Task shape | Usually adequate tier | Escalate when |
| --- | --- | --- |
| Counting, extraction, formatting, known-pattern search, deterministic test execution | Light / high-throughput | Inputs are noisy, success is hard to verify, or errors have material cost. |
| Bounded implementation, ordinary review, structured research, test-backed bug fix | Balanced general/coding | The fault is ambiguous, spans subsystems, or repeated repair would exceed one stronger pass. |
| Architecture, subtle concurrency/security reasoning, cross-module migration, disputed synthesis | Frontier / strong reasoning | Keep the strongest suitable profile on the critical path; use lighter workers only for bounded evidence. |
| Independent verification | Balanced or strong, preferably with a clearly suitable separate profile | The review is mechanical and fully checkable, in which case light may suffice. |

Model cost is only one part of expected total cost:

```text
expected total cost = model work + coordination + retries/repair + delay cost
```

Do not spend a child invocation to save a few tokens on work the coordinator can
finish and verify immediately.

## Priority profiles

### `cost-first`

- Choose the least expensive clearly adequate listed profile.
- Within the same adequate low-cost tier, prefer the newer active generation.
- Do not buy a large price step solely to obtain a newer release when the cheaper
  profile is verifiably adequate.
- Favor light/mini/flash-lite/haiku/luna/small-style profiles for narrow,
  deterministic work.
- Keep uncertain design and final integration with the coordinator rather than
  letting cheap workers make irreversible decisions.
- Prefer sequential execution unless independent parallel work reduces total billed
  attempts or avoids an expensive retry.

### `cost-efficient-balanced`

- Use a newer stable balanced general or coding profile by default when the price
  and expected retry/repair cost remain proportionate.
- Reserve frontier profiles for ambiguity, high error cost, long-horizon planning,
  or final arbitration.
- Route bounded discovery, inventory, and test evidence to lighter profiles when the
  result has explicit acceptance checks.
- Optimize for one correct workflow, not the cheapest individual request.

### `efficiency-first`

- Optimize the critical path for wall-clock completion and first-pass correctness.
- Prefer the newest stable, strongest clearly suitable profile for decomposition,
  integration, and high-coupling decisions; retain cost as a guardrail.
- Parallelize independent read-only investigations and non-overlapping write tasks
  within scheduler and lease limits.
- A latency-optimized or high-throughput mid-tier model may beat a slower frontier
  model for bounded workers; “strongest” is not automatically “fastest.”

## Formal recommendation matrix

This is the default dated shortlist for recognizable exact model IDs from the
providers below. It is deliberately broader than any one user's configuration. The
runtime candidate set is always:

```text
listed exact profiles
  intersect profiles declaring every required capability
  intersect active, reachable, host-approved routes
```

The matrix cannot add a profile to that set. Each priority column is an intra-provider
anchor, not a claim that the provider or model is globally best. When several
providers remain, compare the actual configured route's expected total cost,
latency, task fit, and retry risk. A current host price or user-supplied budget is
stronger evidence than the dated public list prices below. An open-weight model has
no universal API price: use the configured host's price and lifecycle or mark both
unknown.

Prefer stable/current aliases or pinned active snapshots. A Preview entry is never a
default production recommendation merely because it is newer; use it only when the
user explicitly selected Preview, the task explicitly calls for evaluating it, or it
is the only adequate approved route and the instability is accepted. In every cell,
the exact profile must still pass the capability hard gate.

| Provider | `cost-first` anchor | `cost-efficient-balanced` anchor | `efficiency-first` anchor | Multimodal companion anchor |
| --- | --- | --- | --- | --- |
| OpenAI | GPT-5.6 Luna for bounded, verifiable work | GPT-5.6 Terra | GPT-5.6 Sol | The same current family only when the exact profile declares `vision_input`; use dedicated media routes for generation/editing. |
| Anthropic | Claude Haiku 4.5 | Claude Sonnet 5 | Claude Opus 5; Claude Fable 5 for the longest-running highest-capability agent work | Current Claude families have official image-input evidence, but the exact profile must declare `vision_input`. |
| Google | Gemini 3.5 Flash-Lite | Gemini 3.6 Flash | Gemini 3.1 Pro Preview for the highest-coupling reasoning/coding work after explicit Preview acceptance; otherwise Gemini 3.6 Flash | Gemini 3.1 Pro Preview, 3.6 Flash, or 3.5 Flash-Lite only when the exact declaration covers every required image, video, audio, or PDF input. |
| Meta | Muse Spark 1.1 only when its exact configured route has a known cost that fits the budget and Public Preview is accepted; otherwise no Meta cost anchor | Muse Spark 1.1 after explicit Public Preview acceptance | Muse Spark 1.1 after explicit Public Preview acceptance | Muse Spark 1.1 only when the exact profile declares every required input capability; use dedicated Muse media routes for generation. Do not invent an API model ID from the display name. |
| xAI | Grok Build 0.1 for bounded coding/engineering; otherwise Grok 4.3 | Grok 4.3 | Grok 4.5 | Grok Build 0.1, Grok 4.3, or Grok 4.5 only with exact `vision_input`; use dedicated Imagine/Voice routes for media generation or audio. |
| Mistral | Mistral Small 4 | Mistral Medium 3.5 | Mistral Medium 3.5 | Small 4 or Medium 3.5 when the exact route declares `vision_input`. |
| DeepSeek | `DeepSeek-V4-Flash-0731` (version behind API model `deepseek-v4-flash`) | `DeepSeek-V4-Flash-0731`, preferred over V4-Pro for agentic work | `DeepSeek-V4-Flash-0731` as the current upper recommendation over V4-Pro after Public Beta acceptance | No current V4 language-model anchor: pair a different exact profile that declares the required multimodal capability. |
| Kimi / Moonshot AI | Kimi K2.7 Code for bounded coding, or Kimi K2.6 for general/visual work | Kimi K2.7 Code for coding or Kimi K2.6 for general multimodal work | Kimi K3 | Kimi K3 or K2.6 when exact declarations prove the required input; do not infer K2.7 Code modalities from its name. |
| Z.ai | GLM-4.7-FlashX, or GLM-4.7-Flash where that exact free route is active and adequate | GLM-5.1 | GLM-5.2 | GLM-4.6V-Flash/FlashX for low cost or GLM-5V-Turbo for stronger visual work, only when listed and declared capable. |
| MiniMax | MiniMax M3 with low/no reasoning for narrow work | MiniMax M3 with reasoning appropriate to the task | MiniMax M3 on the normal or explicitly approved priority service tier | MiniMax M3 for declared image/video input; use its separate image, video, speech, or music routes for generation. |
| Qwen / Alibaba Cloud | Qwen3.6-Flash | Qwen3.7-Plus | Qwen3.7-Max as the stable default; Qwen3.8-Max-Preview only after explicit Preview acceptance | Qwen3.6-Flash or Qwen3.7-Plus; Qwen3.8-Max-Preview only under the Preview rule. Never assume Qwen3.7-Max vision without an exact declaration. |

DeepSeek naming is intentionally version-explicit: the recommendation is
`DeepSeek-V4-Flash-0731`. The official DeepSeek API request still uses
`model: "deepseek-v4-flash"`, whose current documented `MODEL VERSION` is
`DeepSeek-V4-Flash-0731`. Treat that wire name only as an alias for the documented
0731 version; never omit the `-0731` suffix from this recommendation, and do not
assume an unrelated third-party alias resolves to 0731 without exact host evidence.

Apply the matrix as follows:

1. Select the priority column from the task/user policy.
2. Remove every cell entry that is absent from `list_inference_profiles`, cannot be
   mapped confidently to the exact configured model ID, or lacks a required declared
   capability.
3. Remove retired/deprecated routes and normally remove Preview/experimental routes.
4. For `cost-first`, compare the remaining route's real effective price when known;
   unknown host pricing is not evidence of being cheapest. For the balanced mode,
   compare expected retries/repair and coordination overhead. For
   `efficiency-first`, put the strongest stable suitable candidate on the critical
   path while retaining cost as a guardrail.
5. If no matrix entry survives but another exact configured profile is adequate, use
   that profile and treat freshness/cost as unknown. If no adequate exact profile
   survives, inherit or report the capability blocker as required by the main Skill.

## Official family anchors

Prices are standard text token list prices in USD per million input/output tokens
unless noted. Cached, batch, priority, long-context, regional, promotional, and tool
charges can differ.

| Vendor family (snapshot) | Official positioning, paraphrased | Modality evidence, not routing authority | Routing anchor and snapshot list price |
| --- | --- | --- | --- |
| OpenAI GPT-5.6 Sol / Terra / Luna | Sol targets complex professional reasoning and coding; Terra balances capability and cost; Luna targets cost-sensitive high-volume work. | Family pages list text and image input, but the exact configured profile must still declare `vision_input`. | Sol: frontier at 5/30. Terra: balanced at 2/12. Luna: cost-first at 0.20/1.20. |
| Anthropic Claude Fable 5 / Opus 5 / Sonnet 5 / Haiku 4.5 | Fable targets long-running high-capability agents; Opus targets complex agentic coding; Sonnet combines speed and intelligence; Haiku is the fastest/lowest-cost tier. | Current Claude model documentation lists text and image input; require `vision_input` on the exact configured profile. | Fable 10/50; Opus 5/25; Sonnet promotional 2/10 through 2026-08-31 then 3/15; Haiku 1/5. |
| Google Gemini 3.1 Pro Preview / 3.6 Flash / 3.5 Flash-Lite | 3.1 Pro is Google's advanced-intelligence, complex-problem-solving, agentic and coding Preview route. 3.6 Flash is the stable balanced route; Flash-Lite is the stable high-throughput low-cost route. | The family has official multimodal evidence, but only exact declared capabilities count. Preview status remains a lifecycle constraint. | 3.1 Pro Preview: 2/12 for prompts <=200K and 4/18 above 200K; 3.6 Flash 1.50/7.50; 3.5 Flash-Lite 0.30/2.50. |
| Meta Muse Spark 1.1 | Meta positions Muse Spark 1.1 as its July 2026 multimodal reasoning model for agentic work, tool/computer use, coding, orchestration, and long context. Developer access is through the Meta Model API Public Preview. | Official material describes visual, video, and audio understanding, but the exact configured profile must declare each required capability. | The cited public pages do not expose a stable comparable token price or a public exact API model string. Use the configured route's price/lifecycle and a confidently mapped exact profile, or mark them unknown. |
| xAI Grok Build 0.1 / Grok 4.3 / Grok 4.5 | Build 0.1 targets agentic coding/engineering; 4.3 is a fast reliable general model; 4.5 is the current flagship. | These model pages list text and image input, while generation/editing and voice use dedicated APIs. Require exact declarations. | Build 1/2; 4.3 1.25/2.50; 4.5 2/6 for short context. Long-context, media, search, and priority charges differ. |
| Mistral Medium 3.5 (26.04) / Small 4 (26.03) | Medium 3.5 is a newer frontier-class cost-efficient agentic/coding model; Small 4 is a low-cost hybrid instruct/reasoning/coding model. | Both current family pages list text and image input; require `vision_input` on the exact configured profile. | Medium 1.50/7.50; Small 0.15/0.60. Use exact current docs for Devstral/Magistral variants. |
| DeepSeek-V4-Flash-0731 / DeepSeek-V4-Pro | The 2026-07-31 official Flash update says its agent benchmarks far exceed V4-Pro-Preview. It also has Responses API support, lower price, and higher published concurrency, so this snapshot ranks `DeepSeek-V4-Flash-0731` above V4-Pro for agentic tasks once Public Beta is accepted. The API model string remains `deepseek-v4-flash`, while the documented model version is explicitly `DeepSeek-V4-Flash-0731`. | Official V4 API compatibility documentation rejects image inputs. A visual task requires another exact profile declaring `vision_input`. | Cache-miss input/output: Flash-0731 0.14/0.28; Pro 0.435/0.87. Peak policy may differ. |
| Kimi K3 / K2.7 Code / K2.6 | K3 is the July 2026 flagship for long-horizon coding, knowledge work, reasoning, native vision, and 1M context. K2.7 Code is coding-focused; K2.6 is a lower-cost general multimodal model. | K3 and K2.6 have official visual-input evidence. Exact configuration remains decisive, especially for K2.7 Code and video handling. | Uncached input/output: K3 3/15; K2.7 Code 0.95/4; K2.6 0.95/4. Cache-hit and hosted/open-weight prices differ. |
| Z.ai GLM-5.2 / GLM-5.1 / GLM-4.7-FlashX / GLM-5V-Turbo | GLM-5.2 is the June 2026 long-horizon flagship with 1M context; 5.1 is the priced stable high-capability coding route; 4.7-FlashX is the light/high-speed route. Vision uses separate V families. | The flagship text rows do not prove vision. Use an exact configured GLM-V route declaring `vision_input` for visual work. | Public pricing snapshot: GLM-5.1 1.4/4.4; GLM-4.7-FlashX 0.07/0.40; GLM-5V-Turbo 1.2/4. GLM-5.2 public pay-as-you-go price was not stated in the cited pricing page, so treat it as unknown. |
| MiniMax M3 | M3 is the June 2026 frontier coding/agentic model with native image/video input and a 1M context; thinking can be toggled. | Native multimodal evidence does not grant a route. Dedicated APIs handle image/video/audio/music generation. | Standard <=512K current listed rate 0.30/1.20; >512K 0.60/2.40. Priority is 1.5x and dedicated media is charged separately. |
| Qwen3.8-Max-Preview / Qwen3.7-Max / Qwen3.7-Plus / Qwen3.6-Flash | 3.8 Max Preview is the newest preview with vision; 3.7 Max is the stable frontier agent/reasoning tier; 3.7 Plus balances performance/cost; 3.6 Flash is the low-cost tier. | Official visual-reasoning docs cover 3.7 Plus and 3.6 Flash. Preview evidence covers 3.8 Max Preview. Do not infer vision for another exact route. | Representative Singapore list prices: 3.7 Max 2.50/7.50; 3.7 Plus <=256K 0.40/1.60; 3.6 Flash <=256K 0.25/1.50. 3.8 Max Preview is Token-Plan Preview, not a comparable standard pay-as-you-go anchor. |

Treat name cues only as weak evidence outside the exact rows above. For example,
“small” can still describe a capable coding model, and “pro” does not prove tool or
wire compatibility. A newer release is preferred only after the exact host line
proves required capabilities and the required task quality is met.

## Variant and task matching

- Prefer low/no reasoning for mechanical, short, fully verifiable work.
- Prefer medium reasoning for ordinary implementation and synthesis.
- Prefer high reasoning for ambiguous root-cause analysis, architecture, security,
  concurrency, or costly irreversible decisions.
- Use a coding-specialized profile for implementation only when its exact listed
  identity clearly indicates that specialization; keep cross-domain planning with a
  capable general coordinator.
- Do not select a profile merely for a large advertised context window. The current
  safe profile list does not prove effective request limits or route compatibility.
- If a preview/deprecated alias is the only apparent match, inherit unless the user or
  host explicitly selected it and the exact approved profile is present.

## Examples

- Count files and return paths: do it directly if already cheap; otherwise a light,
  read-only inherited or explicit cost profile is enough.
- Implement one test-backed feature across a few coupled files: balanced direct work
  usually beats delegation overhead.
- Audit three independent modules: a balanced coordinator can create three bounded
  read-only WorkTasks and use light/balanced workers, then verify and synthesize.
- Diagnose a rare race and design the fix: use a strong profile on the critical path;
  parallelize reproduction and code-history evidence if independent.
- Analyze screenshots while the main profile is text-only: keep planning/synthesis on
  the main profile, but spawn or reuse a read-only `vision_input` companion and give
  it the actual images plus a bounded evidence request. If the images cannot be
  transferred, report the multimodal branch blocked.
- Produce an independent security review: use a clearly suitable balanced/strong
  reviewer with read-only access and no coordinator lease.

## Official sources

- OpenAI models: https://developers.openai.com/api/docs/models
- OpenAI latest-model guidance: https://developers.openai.com/api/docs/guides/latest-model
- Anthropic models: https://platform.claude.com/docs/en/about-claude/models/overview
- Anthropic pricing: https://platform.claude.com/docs/en/about-claude/pricing
- Anthropic deprecations: https://platform.claude.com/docs/en/about-claude/model-deprecations
- Google Gemini models: https://ai.google.dev/gemini-api/docs/models
- Google Gemini latest-model guidance: https://ai.google.dev/gemini-api/docs/latest-model
- Google Gemini pricing: https://ai.google.dev/gemini-api/docs/pricing
- DeepSeek models and pricing: https://api-docs.deepseek.com/quick_start/pricing/
- DeepSeek release updates: https://api-docs.deepseek.com/updates
- DeepSeek Anthropic-format compatibility: https://api-docs.deepseek.com/guides/anthropic_api/
- Mistral current models: https://docs.mistral.ai/models
- Mistral Medium 3.5: https://docs.mistral.ai/models/model-cards/mistral-medium-3-5-26-04
- Mistral Small 4: https://mistral.ai/news/mistral-small-4/
- xAI models: https://docs.x.ai/developers/models
- xAI pricing: https://docs.x.ai/developers/pricing
- Meta Muse Spark 1.1 release: https://ai.meta.com/blog/introducing-muse-spark-meta-model-api/
- Meta Muse Spark / Model API access: https://ai.meta.com/llama
- Kimi current API models and pricing: https://platform.kimi.ai/
- Kimi K3 official model repository: https://github.com/MoonshotAI/Kimi-K3
- Kimi API pricing: https://platform.kimi.ai/docs/pricing/chat
- Z.ai GLM-5.2 release: https://z.ai/blog/glm-5.2
- Z.ai models: https://docs.z.ai/guides/overview/overview
- Z.ai pricing: https://docs.z.ai/guides/overview/pricing
- MiniMax M3 release: https://www.minimax.io/blog/minimax-m3
- MiniMax pay-as-you-go pricing: https://platform.minimax.io/docs/guides/pricing-paygo
- Qwen/Alibaba Cloud current model overview: https://www.alibabacloud.com/help/en/model-studio/models
- Qwen/Alibaba Cloud pricing: https://www.alibabacloud.com/help/en/model-studio/model-pricing
- Qwen3.8 Max Preview status: https://modelstudio.alibabacloud.com/intl/blog/model-studio-token-plan-individual/
- Qwen visual reasoning models: https://www.alibabacloud.com/help/en/model-studio/visual-reasoning
