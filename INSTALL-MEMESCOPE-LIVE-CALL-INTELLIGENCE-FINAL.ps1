$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$recorderBlock = @'
  // Stage 20 Call Story cycle.
  // Tracks every call independently of the legacy TP lifecycle.
  try {
    const {
      runCallStoryCycle,
    } = await import(
      "@/lib/call-story"
    );

    await runCallStoryCycle(
      tokens,
      signals,
    );
  } catch (error) {
    console.error(
      "MemeScope Call Story cycle failed:",
      error,
    );
  }


'@
$callStoryImport = @'
import {
  compactUsd,
  getCallStoryForSignalRecord,
} from "@/lib/call-story";

'@
$newChannelText = @'
async function channelText(
  record: SignalRecord,
) {
  const story =
    await getCallStoryForSignalRecord(
      record.id,
    );

  const publicId =
    story?.publicId ||
    record.signalId;

  const reasons =
    story?.reasons?.length
      ? story.reasons.slice(0, 4)
      : record.planReason
          .replace(/\s+/g, " ")
          .trim()
          .split(/[.;]/)
          .map((value) => value.trim())
          .filter(Boolean)
          .slice(0, 4);

  const why = [
    story?.buyPressurePct === null ||
    story?.buyPressurePct === undefined
      ? null
      : `Buy Pressure: <b>${story.buyPressurePct.toFixed(0)}%</b>`,
    story?.volumeSpike === null ||
    story?.volumeSpike === undefined
      ? null
      : `Volume Expansion: <b>${story.volumeSpike.toFixed(1)}X</b>`,
    story?.liquidityUsd === null ||
    story?.liquidityUsd === undefined
      ? null
      : `Liquidity: <b>${compactUsd(story.liquidityUsd)}</b>`,
    story?.priceChange5m === null ||
    story?.priceChange5m === undefined
      ? null
      : `5m Momentum: <b>${pct(story.priceChange5m)}</b>`,
  ].filter(
    (value): value is string =>
      value !== null,
  );

  return [
    "🚨 <b>MEMESCOPE CALL</b>",
    "",
    `<b>$${escapeTelegramHtml(record.symbol)}</b> — ${escapeTelegramHtml(record.name)}`,
    `<code>${escapeTelegramHtml(publicId)}</code>`,
    "",
    "<b>CALL MC</b>",
    compactUsd(story?.callMarketCapUsd ?? null),
    "",
    "<b>ENTRY</b>",
    money(record.entryPriceUsd),
    "",
    "<b>SIGNAL SCORE</b>",
    `${Math.round(record.scoreAtEntry)} / 100`,
    "",
    "<b>TRACKING</b>",
    "● LIVE",
    why.length > 0 ? "" : null,
    why.length > 0 ? "<b>WHY IT TRIGGERED</b>" : null,
    ...why,
    reasons.length > 0 ? "" : null,
    reasons.length > 0
      ? reasons
          .map((reason) => `• ${escapeTelegramHtml(reason)}`)
          .join("\n")
      : null,
    "",
    "<b>CA</b>",
    `<code>${escapeTelegramHtml(record.tokenAddress)}</code>`,
    "",
    "<i>Original call will remain unchanged. MemeScope continues silent live tracking after publication.</i>",
  ]
    .filter(
      (value): value is string =>
        value !== null,
    )
    .join("\n");
}

'@
$newPublisherFunction = @'
export async function publishPendingTelegramSignals() {
  if (!telegramConfigured()) {
    return {
      configured: false,
      initialized: false,
      sent: 0,
      edited: 0,
      targetReplies: 0,
    };
  }

  await ensureTelegramPublisherSchema();

  const baseline =
    await initializeTelegramBaseline();

  if (baseline.initialized) {
    return {
      configured: true,
      initialized: true,
      baselineCount:
        baseline.baselineCount,
      sent: 0,
      edited: 0,
      targetReplies: 0,
    };
  }

  const sql =
    sqlClient();

  const { channelId } =
    telegramConfig();

  const rows =
    await sql`
      SELECT
        r.*,
        p.message_id AS telegram_message_id
      FROM memescope_signal_records r
      LEFT JOIN memescope_telegram_posts p
        ON p.signal_record_id = r.id
      WHERE r.opened_at > ${new Date(
        baseline.initializedAt,
      ).toISOString()}
      ORDER BY r.opened_at ASC
      LIMIT 150
    `;

  let sent = 0;

  for (const raw of rows) {
    const row =
      raw as DbRow;

    const record =
      normalizeRecord(row);

    const messageId =
      numOrNull(
        row.telegram_message_id,
      );

    if (messageId === null) {
      const message =
        await telegramSendMessage(
          channelId,
          await channelText(record),
          {
            replyMarkup:
              signalButtons(
                record,
              ),
          },
        );

      await sql`
        INSERT INTO memescope_telegram_posts (
          signal_record_id,
          signal_id,
          channel_id,
          message_id,
          baseline,
          first_sent_at,
          last_edited_at,
          last_status,
          last_current_gain_pct,
          last_peak_gain_pct,
          last_drawdown_pct
        )
        VALUES (
          ${record.id},
          ${record.signalId},
          ${channelId},
          ${message.message_id},
          FALSE,
          NOW(),
          NULL,
          ${record.status},
          ${record.currentGainPercent},
          ${record.peakGainPercent},
          ${record.maxDrawdownPercent}
        )
        ON CONFLICT (signal_record_id)
        DO UPDATE SET
          message_id = COALESCE(
            memescope_telegram_posts.message_id,
            EXCLUDED.message_id
          ),
          channel_id = EXCLUDED.channel_id,
          first_sent_at = COALESCE(
            memescope_telegram_posts.first_sent_at,
            NOW()
          ),
          last_status = EXCLUDED.last_status,
          last_current_gain_pct = EXCLUDED.last_current_gain_pct,
          last_peak_gain_pct = EXCLUDED.last_peak_gain_pct,
          last_drawdown_pct = EXCLUDED.last_drawdown_pct
      `;

      sent += 1;
      continue;
    }

    await sql`
      UPDATE memescope_telegram_posts
      SET
        last_status = ${record.status},
        last_current_gain_pct = ${record.currentGainPercent},
        last_peak_gain_pct = ${record.peakGainPercent},
        last_drawdown_pct = ${record.maxDrawdownPercent}
      WHERE signal_record_id = ${record.id}
    `;
  }

  return {
    configured: true,
    initialized: false,
    sent,
    edited: 0,
    targetReplies: 0,
  };
}

'@
$webhookCallStoryImport = @'
import {
  bindContentHq,
  getContentHqStatus,
  setContentOpportunityStatus,
} from "@/lib/call-story";

'@
$contentCallbackBlock = @'
  if (
    data.startsWith(
      "content:",
    )
  ) {
    const [
      ,
      action,
      rawId,
    ] = data.split(":");

    const opportunityId =
      Number(rawId);

    if (
      !Number.isInteger(
        opportunityId,
      ) ||
      opportunityId <= 0 ||
      (action !== "used" &&
        action !== "skip")
    ) {
      await telegramAnswerCallbackQuery(
        callbackId,
        {
          text:
            "Unknown content action.",
          showAlert: true,
        },
      );
      return;
    }

    await setContentOpportunityStatus(
      opportunityId,
      action === "used"
        ? "used"
        : "skipped",
    );

    await telegramAnswerCallbackQuery(
      callbackId,
      {
        text:
          action === "used"
            ? "Marked as used."
            : "Content skipped.",
      },
    );

    return;
  }


'@
$contentCommandBranch = @'
  try {
    if (
      command ===
      "/bindcontenthq"
    ) {
      const chatType =
        message.chat?.type ??
        "";

      if (
        chatType !== "group" &&
        chatType !==
          "supergroup"
      ) {
        await reply(
          chatId,
          message.message_id,
          [
            "<b>Content HQ binding</b>",
            "",
            "Create a private Telegram group, add this bot, then run <code>/bindcontenthq</code> inside that group.",
          ].join("\n"),
        );
      } else {
        await bindContentHq(
          chatId,
        );

        await reply(
          chatId,
          message.message_id,
          [
            "✅ <b>MEMESCOPE CONTENT HQ CONNECTED</b>",
            "",
            `Group: <b>${escapeTelegramHtml(
              message.chat?.title ??
                "Private group",
            )}</b>`,
            "",
            "High-value call stories, content hooks and share-card links will be delivered here for admin review.",
            "",
            "<i>No X post is sent automatically.</i>",
          ].join("\n"),
        );
      }
    } else if (
      command === "/contenthq"
    ) {
      const hq =
        await getContentHqStatus();

      await reply(
        chatId,
        message.message_id,
        hq.configured
          ? [
              "<b>MemeScope Content HQ</b>",
              "",
              "Status: <b>CONNECTED</b>",
              `Chat ID: <code>${escapeTelegramHtml(
                hq.chatId ??
                  "unknown",
              )}</code>`,
              "",
              "Content opportunities are generated automatically. X publishing remains manual.",
            ].join("\n")
          : [
              "<b>MemeScope Content HQ</b>",
              "",
              "Status: <b>NOT CONNECTED</b>",
              "",
              "Create a private group, add this bot, and run <code>/bindcontenthq</code> there.",
            ].join("\n"),
      );
    } else if (
      command === "/start" ||
      command === "/help"
    ) {
'@

$payloads = @{}
$payloads["src/lib/call-story.ts"] = @"
aW1wb3J0ICJzZXJ2ZXItb25seSI7CgppbXBvcnQgeyBuZW9uIH0gZnJvbSAiQG5lb25kYXRhYmFzZS9zZXJ2ZXJsZXNzIjsKCmltcG9ydCB7CiAgZXNjYXBl
VGVsZWdyYW1IdG1sLAogIHRlbGVncmFtQ29uZmlnLAogIHRlbGVncmFtQ29uZmlndXJlZCwKICB0ZWxlZ3JhbVNlbmRNZXNzYWdlLAogIHRlbGVncmFtU2l0
ZVVybCwKfSBmcm9tICJAL2xpYi90ZWxlZ3JhbSI7CmltcG9ydCB0eXBlIHsgU2lnbmFsQ2FsbCB9IGZyb20gIkAvbGliL3NpZ25hbC10eXBlcyI7CmltcG9y
dCB0eXBlIHsgVGVybWluYWxUb2tlbiB9IGZyb20gIkAvbGliL3Rlcm1pbmFsLXR5cGVzIjsKCnR5cGUgRGJSb3cgPSBSZWNvcmQ8c3RyaW5nLCB1bmtub3du
PjsKCnR5cGUgU2lnbmFsUmVjb3JkUm93ID0gewogIGlkOiBzdHJpbmc7CiAgc2lnbmFsSWQ6IHN0cmluZzsKICB0b2tlbkFkZHJlc3M6IHN0cmluZzsKICBz
eW1ib2w6IHN0cmluZzsKICBuYW1lOiBzdHJpbmc7CiAgb3BlbmVkQXQ6IG51bWJlcjsKICBlbnRyeVByaWNlVXNkOiBudW1iZXIgfCBudWxsOwogIHBlYWtH
YWluUGVyY2VudDogbnVtYmVyIHwgbnVsbDsKICBtYXhEcmF3ZG93blBlcmNlbnQ6IG51bWJlciB8IG51bGw7CiAgc2NvcmVBdEVudHJ5OiBudW1iZXI7Cn07
Cgp0eXBlIE1hcmtldFNuYXBzaG90ID0gewogIHByaWNlVXNkOiBudW1iZXIgfCBudWxsOwogIG1hcmtldENhcFVzZDogbnVtYmVyIHwgbnVsbDsKICBsaXF1
aWRpdHlVc2Q6IG51bWJlciB8IG51bGw7Cn07CgpleHBvcnQgdHlwZSBDYWxsU3RvcnkgPSB7CiAgc2lnbmFsUmVjb3JkSWQ6IHN0cmluZzsKICBjYWxsTm86
IG51bWJlcjsKICBwdWJsaWNJZDogc3RyaW5nOwogIHNpZ25hbElkOiBzdHJpbmc7CiAgdG9rZW5BZGRyZXNzOiBzdHJpbmc7CiAgc3ltYm9sOiBzdHJpbmc7
CiAgbmFtZTogc3RyaW5nOwogIGNhbGxlZEF0OiBudW1iZXI7CiAgZW50cnlQcmljZVVzZDogbnVtYmVyIHwgbnVsbDsKICBjYWxsTWFya2V0Q2FwVXNkOiBu
dW1iZXIgfCBudWxsOwogIGN1cnJlbnRQcmljZVVzZDogbnVtYmVyIHwgbnVsbDsKICBjdXJyZW50TWFya2V0Q2FwVXNkOiBudW1iZXIgfCBudWxsOwogIHBl
YWtQcmljZVVzZDogbnVtYmVyIHwgbnVsbDsKICBwZWFrTWFya2V0Q2FwVXNkOiBudW1iZXIgfCBudWxsOwogIGN1cnJlbnRNdWx0aXBsZTogbnVtYmVyIHwg
bnVsbDsKICBwZWFrTXVsdGlwbGU6IG51bWJlciB8IG51bGw7CiAgbWF4RHJhd2Rvd25QY3Q6IG51bWJlciB8IG51bGw7CiAgc2lnbmFsU2NvcmU6IG51bWJl
cjsKICBidXlQcmVzc3VyZVBjdDogbnVtYmVyIHwgbnVsbDsKICB2b2x1bWVTcGlrZTogbnVtYmVyIHwgbnVsbDsKICBsaXF1aWRpdHlVc2Q6IG51bWJlciB8
IG51bGw7CiAgcHJpY2VDaGFuZ2U1bTogbnVtYmVyIHwgbnVsbDsKICBwYWlyQWdlTWludXRlczogbnVtYmVyIHwgbnVsbDsKICByZWFzb25zOiBzdHJpbmdb
XTsKICBiYXNlbGluZTogYm9vbGVhbjsKICBsYXN0UHVibGljTWlsZXN0b25lOiBudW1iZXI7CiAgbWlsZXN0b25lMnhBdDogbnVtYmVyIHwgbnVsbDsKICBt
aWxlc3RvbmU1eEF0OiBudW1iZXIgfCBudWxsOwogIG1pbGVzdG9uZTEweEF0OiBudW1iZXIgfCBudWxsOwogIG1pbGVzdG9uZTIweEF0OiBudW1iZXIgfCBu
dWxsOwogIG1pbGVzdG9uZTUweEF0OiBudW1iZXIgfCBudWxsOwogIG1pbGVzdG9uZTEwMHhBdDogbnVtYmVyIHwgbnVsbDsKfTsKCmV4cG9ydCB0eXBlIENh
bGxEYXNoYm9hcmQgPSB7CiAgZGF5czogbnVtYmVyOwogIHRvdGFsQ2FsbHM6IG51bWJlcjsKICByZWFjaGVkMng6IG51bWJlcjsKICByZWFjaGVkNXg6IG51
bWJlcjsKICByZWFjaGVkMTB4OiBudW1iZXI7CiAgbWVkaWFuUGVha011bHRpcGxlOiBudW1iZXIgfCBudWxsOwogIG1lZGlhbk1heERyYXdkb3duUGN0OiBu
dW1iZXIgfCBudWxsOwogIHRvcENhbGxzOiBDYWxsU3RvcnlbXTsKICByZWNlbnRDYWxsczogQ2FsbFN0b3J5W107Cn07CgpsZXQgc2NoZW1hUHJvbWlzZTog
UHJvbWlzZTx2b2lkPiB8IG51bGwgPSBudWxsOwoKZnVuY3Rpb24gc3FsQ2xpZW50KCkgewogIGNvbnN0IGRhdGFiYXNlVXJsID0gcHJvY2Vzcy5lbnYuREFU
QUJBU0VfVVJMPy50cmltKCk7CiAgaWYgKCFkYXRhYmFzZVVybCkgewogICAgdGhyb3cgbmV3IEVycm9yKCJEQVRBQkFTRV9VUkwgaXMgbm90IGNvbmZpZ3Vy
ZWQuIik7CiAgfQogIHJldHVybiBuZW9uKGRhdGFiYXNlVXJsKTsKfQoKZnVuY3Rpb24gbnVtT3JOdWxsKHZhbHVlOiB1bmtub3duKTogbnVtYmVyIHwgbnVs
bCB7CiAgaWYgKHZhbHVlID09PSBudWxsIHx8IHZhbHVlID09PSB1bmRlZmluZWQgfHwgdmFsdWUgPT09ICIiKSByZXR1cm4gbnVsbDsKICBjb25zdCBwYXJz
ZWQgPSBOdW1iZXIodmFsdWUpOwogIHJldHVybiBOdW1iZXIuaXNGaW5pdGUocGFyc2VkKSA/IHBhcnNlZCA6IG51bGw7Cn0KCmZ1bmN0aW9uIG51bSh2YWx1
ZTogdW5rbm93biwgZmFsbGJhY2sgPSAwKSB7CiAgcmV0dXJuIG51bU9yTnVsbCh2YWx1ZSkgPz8gZmFsbGJhY2s7Cn0KCmZ1bmN0aW9uIG1pbGxpcyh2YWx1
ZTogdW5rbm93bik6IG51bWJlciB7CiAgaWYgKHZhbHVlIGluc3RhbmNlb2YgRGF0ZSkgcmV0dXJuIHZhbHVlLmdldFRpbWUoKTsKICBjb25zdCBwYXJzZWQg
PSBEYXRlLnBhcnNlKFN0cmluZyh2YWx1ZSkpOwogIHJldHVybiBOdW1iZXIuaXNGaW5pdGUocGFyc2VkKSA/IHBhcnNlZCA6IERhdGUubm93KCk7Cn0KCmZ1
bmN0aW9uIG51bGxhYmxlTWlsbGlzKHZhbHVlOiB1bmtub3duKTogbnVtYmVyIHwgbnVsbCB7CiAgaWYgKHZhbHVlID09PSBudWxsIHx8IHZhbHVlID09PSB1
bmRlZmluZWQpIHJldHVybiBudWxsOwogIHJldHVybiBtaWxsaXModmFsdWUpOwp9CgpmdW5jdGlvbiBzYWZlSnNvbkFycmF5KHZhbHVlOiB1bmtub3duKTog
c3RyaW5nW10gewogIGlmIChBcnJheS5pc0FycmF5KHZhbHVlKSkgewogICAgcmV0dXJuIHZhbHVlLm1hcCgoaXRlbSkgPT4gU3RyaW5nKGl0ZW0pKS5maWx0
ZXIoQm9vbGVhbik7CiAgfQogIGlmICh0eXBlb2YgdmFsdWUgIT09ICJzdHJpbmciIHx8ICF2YWx1ZS50cmltKCkpIHJldHVybiBbXTsKICB0cnkgewogICAg
Y29uc3QgcGFyc2VkID0gSlNPTi5wYXJzZSh2YWx1ZSkgYXMgdW5rbm93bjsKICAgIHJldHVybiBBcnJheS5pc0FycmF5KHBhcnNlZCkKICAgICAgPyBwYXJz
ZWQubWFwKChpdGVtKSA9PiBTdHJpbmcoaXRlbSkpLmZpbHRlcihCb29sZWFuKQogICAgICA6IFtdOwogIH0gY2F0Y2ggewogICAgcmV0dXJuIFtdOwogIH0K
fQoKZnVuY3Rpb24gbm9ybWFsaXplQ2FsbChyb3c6IERiUm93KTogQ2FsbFN0b3J5IHsKICByZXR1cm4gewogICAgc2lnbmFsUmVjb3JkSWQ6IFN0cmluZyhy
b3cuc2lnbmFsX3JlY29yZF9pZCksCiAgICBjYWxsTm86IG51bShyb3cuY2FsbF9ubyksCiAgICBwdWJsaWNJZDogU3RyaW5nKHJvdy5wdWJsaWNfaWQgPz8g
IiIpLAogICAgc2lnbmFsSWQ6IFN0cmluZyhyb3cuc2lnbmFsX2lkKSwKICAgIHRva2VuQWRkcmVzczogU3RyaW5nKHJvdy50b2tlbl9hZGRyZXNzKSwKICAg
IHN5bWJvbDogU3RyaW5nKHJvdy5zeW1ib2wpLAogICAgbmFtZTogU3RyaW5nKHJvdy5uYW1lKSwKICAgIGNhbGxlZEF0OiBtaWxsaXMocm93LmNhbGxlZF9h
dCksCiAgICBlbnRyeVByaWNlVXNkOiBudW1Pck51bGwocm93LmVudHJ5X3ByaWNlX3VzZCksCiAgICBjYWxsTWFya2V0Q2FwVXNkOiBudW1Pck51bGwocm93
LmNhbGxfbWFya2V0X2NhcF91c2QpLAogICAgY3VycmVudFByaWNlVXNkOiBudW1Pck51bGwocm93LmN1cnJlbnRfcHJpY2VfdXNkKSwKICAgIGN1cnJlbnRN
YXJrZXRDYXBVc2Q6IG51bU9yTnVsbChyb3cuY3VycmVudF9tYXJrZXRfY2FwX3VzZCksCiAgICBwZWFrUHJpY2VVc2Q6IG51bU9yTnVsbChyb3cucGVha19w
cmljZV91c2QpLAogICAgcGVha01hcmtldENhcFVzZDogbnVtT3JOdWxsKHJvdy5wZWFrX21hcmtldF9jYXBfdXNkKSwKICAgIGN1cnJlbnRNdWx0aXBsZTog
bnVtT3JOdWxsKHJvdy5jdXJyZW50X211bHRpcGxlKSwKICAgIHBlYWtNdWx0aXBsZTogbnVtT3JOdWxsKHJvdy5wZWFrX211bHRpcGxlKSwKICAgIG1heERy
YXdkb3duUGN0OiBudW1Pck51bGwocm93Lm1heF9kcmF3ZG93bl9wY3QpLAogICAgc2lnbmFsU2NvcmU6IG51bShyb3cuc2lnbmFsX3Njb3JlKSwKICAgIGJ1
eVByZXNzdXJlUGN0OiBudW1Pck51bGwocm93LmJ1eV9wcmVzc3VyZV9wY3QpLAogICAgdm9sdW1lU3Bpa2U6IG51bU9yTnVsbChyb3cudm9sdW1lX3NwaWtl
KSwKICAgIGxpcXVpZGl0eVVzZDogbnVtT3JOdWxsKHJvdy5saXF1aWRpdHlfdXNkKSwKICAgIHByaWNlQ2hhbmdlNW06IG51bU9yTnVsbChyb3cucHJpY2Vf
Y2hhbmdlXzVtKSwKICAgIHBhaXJBZ2VNaW51dGVzOiBudW1Pck51bGwocm93LnBhaXJfYWdlX21pbnV0ZXMpLAogICAgcmVhc29uczogc2FmZUpzb25BcnJh
eShyb3cucmVhc29uc19qc29uKSwKICAgIGJhc2VsaW5lOiByb3cuYmFzZWxpbmUgPT09IHRydWUsCiAgICBsYXN0UHVibGljTWlsZXN0b25lOiBudW0ocm93
Lmxhc3RfcHVibGljX21pbGVzdG9uZSksCiAgICBtaWxlc3RvbmUyeEF0OiBudWxsYWJsZU1pbGxpcyhyb3cubWlsZXN0b25lXzJ4X2F0KSwKICAgIG1pbGVz
dG9uZTV4QXQ6IG51bGxhYmxlTWlsbGlzKHJvdy5taWxlc3RvbmVfNXhfYXQpLAogICAgbWlsZXN0b25lMTB4QXQ6IG51bGxhYmxlTWlsbGlzKHJvdy5taWxl
c3RvbmVfMTB4X2F0KSwKICAgIG1pbGVzdG9uZTIweEF0OiBudWxsYWJsZU1pbGxpcyhyb3cubWlsZXN0b25lXzIweF9hdCksCiAgICBtaWxlc3RvbmU1MHhB
dDogbnVsbGFibGVNaWxsaXMocm93Lm1pbGVzdG9uZV81MHhfYXQpLAogICAgbWlsZXN0b25lMTAweEF0OiBudWxsYWJsZU1pbGxpcyhyb3cubWlsZXN0b25l
XzEwMHhfYXQpLAogIH07Cn0KCmZ1bmN0aW9uIG5vcm1hbGl6ZVNpZ25hbFJlY29yZChyb3c6IERiUm93KTogU2lnbmFsUmVjb3JkUm93IHsKICByZXR1cm4g
ewogICAgaWQ6IFN0cmluZyhyb3cuaWQpLAogICAgc2lnbmFsSWQ6IFN0cmluZyhyb3cuc2lnbmFsX2lkKSwKICAgIHRva2VuQWRkcmVzczogU3RyaW5nKHJv
dy50b2tlbl9hZGRyZXNzKSwKICAgIHN5bWJvbDogU3RyaW5nKHJvdy5zeW1ib2wpLAogICAgbmFtZTogU3RyaW5nKHJvdy5uYW1lKSwKICAgIG9wZW5lZEF0
OiBtaWxsaXMocm93Lm9wZW5lZF9hdCksCiAgICBlbnRyeVByaWNlVXNkOiBudW1Pck51bGwocm93LmVudHJ5X3ByaWNlX3VzZCksCiAgICBwZWFrR2FpblBl
cmNlbnQ6IG51bU9yTnVsbChyb3cucGVha19nYWluX3BjdCksCiAgICBtYXhEcmF3ZG93blBlcmNlbnQ6IG51bU9yTnVsbChyb3cubWF4X2RyYXdkb3duX3Bj
dCksCiAgICBzY29yZUF0RW50cnk6IG51bShyb3cuc2NvcmVfYXRfZW50cnkpLAogIH07Cn0KCmV4cG9ydCBmdW5jdGlvbiBjb21wYWN0VXNkKHZhbHVlOiBu
dW1iZXIgfCBudWxsKSB7CiAgaWYgKHZhbHVlID09PSBudWxsIHx8ICFOdW1iZXIuaXNGaW5pdGUodmFsdWUpKSByZXR1cm4gIk4vQSI7CiAgY29uc3QgYWJz
b2x1dGUgPSBNYXRoLmFicyh2YWx1ZSk7CiAgaWYgKGFic29sdXRlID49IDFfMDAwXzAwMF8wMDApIHJldHVybiBgJCR7KHZhbHVlIC8gMV8wMDBfMDAwXzAw
MCkudG9GaXhlZCgyKX1CYDsKICBpZiAoYWJzb2x1dGUgPj0gMV8wMDBfMDAwKSByZXR1cm4gYCQkeyh2YWx1ZSAvIDFfMDAwXzAwMCkudG9GaXhlZCgyKX1N
YDsKICBpZiAoYWJzb2x1dGUgPj0gMV8wMDApIHJldHVybiBgJCR7KHZhbHVlIC8gMV8wMDApLnRvRml4ZWQoMCl9S2A7CiAgcmV0dXJuIGAkJHt2YWx1ZS50
b0ZpeGVkKDApfWA7Cn0KCmV4cG9ydCBmdW5jdGlvbiBtdWx0aXBsZVRleHQodmFsdWU6IG51bWJlciB8IG51bGwpIHsKICBpZiAodmFsdWUgPT09IG51bGwg
fHwgIU51bWJlci5pc0Zpbml0ZSh2YWx1ZSkpIHJldHVybiAiTi9BIjsKICByZXR1cm4gYCR7dmFsdWUudG9GaXhlZCh2YWx1ZSA+PSAxMCA/IDEgOiAyKX1Y
YDsKfQoKZnVuY3Rpb24gcGN0KHZhbHVlOiBudW1iZXIgfCBudWxsKSB7CiAgaWYgKHZhbHVlID09PSBudWxsIHx8ICFOdW1iZXIuaXNGaW5pdGUodmFsdWUp
KSByZXR1cm4gIk4vQSI7CiAgcmV0dXJuIGAke3ZhbHVlID4gMCA/ICIrIiA6ICIifSR7dmFsdWUudG9GaXhlZCgxKX0lYDsKfQoKZnVuY3Rpb24gcHJpY2VU
ZXh0KHZhbHVlOiBudW1iZXIgfCBudWxsKSB7CiAgaWYgKHZhbHVlID09PSBudWxsIHx8ICFOdW1iZXIuaXNGaW5pdGUodmFsdWUpKSByZXR1cm4gIk4vQSI7
CiAgaWYgKHZhbHVlID49IDEpIHJldHVybiBgJCR7dmFsdWUudG9GaXhlZCg0KX1gOwogIHJldHVybiBgJCR7dmFsdWUudG9QcmVjaXNpb24oNil9YDsKfQoK
ZnVuY3Rpb24gZHVyYXRpb25UZXh0KGZyb206IG51bWJlciwgdG86IG51bWJlciB8IG51bGwpIHsKICBpZiAodG8gPT09IG51bGwpIHJldHVybiAiTi9BIjsK
ICBjb25zdCBtaW51dGVzID0gTWF0aC5tYXgoMCwgKHRvIC0gZnJvbSkgLyA2MF8wMDApOwogIGlmIChtaW51dGVzIDwgNjApIHJldHVybiBgJHtNYXRoLnJv
dW5kKG1pbnV0ZXMpfW1gOwogIGNvbnN0IGhvdXJzID0gbWludXRlcyAvIDYwOwogIGlmIChob3VycyA8IDI0KSByZXR1cm4gYCR7aG91cnMudG9GaXhlZCgx
KX1oYDsKICByZXR1cm4gYCR7KGhvdXJzIC8gMjQpLnRvRml4ZWQoMSl9ZGA7Cn0KCmZ1bmN0aW9uIHB1YmxpY0lkRm9yKGNhbGxObzogbnVtYmVyLCBjYWxs
ZWRBdDogbnVtYmVyKSB7CiAgY29uc3QgZGF0ZSA9IG5ldyBEYXRlKGNhbGxlZEF0KTsKICBjb25zdCBtb250aCA9IFN0cmluZyhkYXRlLmdldFVUQ01vbnRo
KCkgKyAxKS5wYWRTdGFydCgyLCAiMCIpOwogIGNvbnN0IGRheSA9IFN0cmluZyhkYXRlLmdldFVUQ0RhdGUoKSkucGFkU3RhcnQoMiwgIjAiKTsKICByZXR1
cm4gYE1TLSR7bW9udGh9JHtkYXl9LSR7U3RyaW5nKGNhbGxObykucGFkU3RhcnQoMywgIjAiKX1gOwp9CgpmdW5jdGlvbiBoaWdoZXN0UHVibGljTWlsZXN0
b25lKHZhbHVlOiBudW1iZXIgfCBudWxsKSB7CiAgaWYgKHZhbHVlID09PSBudWxsKSByZXR1cm4gMDsKICBpZiAodmFsdWUgPj0gMTApIHJldHVybiAxMDsK
ICBpZiAodmFsdWUgPj0gNSkgcmV0dXJuIDU7CiAgaWYgKHZhbHVlID49IDIpIHJldHVybiAyOwogIHJldHVybiAwOwp9CgpmdW5jdGlvbiBtaWxlc3RvbmVD
b2x1bW4obWlsZXN0b25lOiBudW1iZXIpIHsKICBpZiAobWlsZXN0b25lID09PSAyKSByZXR1cm4gIm1pbGVzdG9uZV8yeF9hdCI7CiAgaWYgKG1pbGVzdG9u
ZSA9PT0gNSkgcmV0dXJuICJtaWxlc3RvbmVfNXhfYXQiOwogIGlmIChtaWxlc3RvbmUgPT09IDEwKSByZXR1cm4gIm1pbGVzdG9uZV8xMHhfYXQiOwogIGlm
IChtaWxlc3RvbmUgPT09IDIwKSByZXR1cm4gIm1pbGVzdG9uZV8yMHhfYXQiOwogIGlmIChtaWxlc3RvbmUgPT09IDUwKSByZXR1cm4gIm1pbGVzdG9uZV81
MHhfYXQiOwogIHJldHVybiAibWlsZXN0b25lXzEwMHhfYXQiOwp9CgpmdW5jdGlvbiBtZWRpYW4odmFsdWVzOiBudW1iZXJbXSkgewogIGNvbnN0IGNsZWFu
ID0gdmFsdWVzLmZpbHRlcihOdW1iZXIuaXNGaW5pdGUpLnNvcnQoKGEsIGIpID0+IGEgLSBiKTsKICBpZiAoY2xlYW4ubGVuZ3RoID09PSAwKSByZXR1cm4g
bnVsbDsKICBjb25zdCBtaWRkbGUgPSBNYXRoLmZsb29yKGNsZWFuLmxlbmd0aCAvIDIpOwogIHJldHVybiBjbGVhbi5sZW5ndGggJSAyID09PSAwCiAgICA/
IChjbGVhblttaWRkbGUgLSAxXSArIGNsZWFuW21pZGRsZV0pIC8gMgogICAgOiBjbGVhblttaWRkbGVdOwp9CgpleHBvcnQgYXN5bmMgZnVuY3Rpb24gZW5z
dXJlQ2FsbFN0b3J5U2NoZW1hKCkgewogIGlmIChzY2hlbWFQcm9taXNlKSByZXR1cm4gc2NoZW1hUHJvbWlzZTsKCiAgc2NoZW1hUHJvbWlzZSA9IChhc3lu
YyAoKSA9PiB7CiAgICBjb25zdCBzcWwgPSBzcWxDbGllbnQoKTsKCiAgICBhd2FpdCBzcWxgCiAgICAgIENSRUFURSBUQUJMRSBJRiBOT1QgRVhJU1RTIG1l
bWVzY29wZV9jYWxsX3N0b3J5X3N0YXRlICgKICAgICAgICBpZCBJTlRFR0VSIFBSSU1BUlkgS0VZLAogICAgICAgIGluaXRpYWxpemVkX2F0IFRJTUVTVEFN
UFRaIE5PVCBOVUxMIERFRkFVTFQgTk9XKCkKICAgICAgKQogICAgYDsKCiAgICBhd2FpdCBzcWxgCiAgICAgIENSRUFURSBUQUJMRSBJRiBOT1QgRVhJU1RT
IG1lbWVzY29wZV9jYWxsX3N0b3J5ICgKICAgICAgICBzaWduYWxfcmVjb3JkX2lkIFRFWFQgUFJJTUFSWSBLRVksCiAgICAgICAgY2FsbF9ubyBCSUdTRVJJ
QUwgVU5JUVVFLAogICAgICAgIHB1YmxpY19pZCBURVhUIFVOSVFVRSwKICAgICAgICBzaWduYWxfaWQgVEVYVCBOT1QgTlVMTCwKICAgICAgICB0b2tlbl9h
ZGRyZXNzIFRFWFQgTk9UIE5VTEwsCiAgICAgICAgc3ltYm9sIFRFWFQgTk9UIE5VTEwsCiAgICAgICAgbmFtZSBURVhUIE5PVCBOVUxMLAogICAgICAgIGNh
bGxlZF9hdCBUSU1FU1RBTVBUWiBOT1QgTlVMTCwKICAgICAgICBlbnRyeV9wcmljZV91c2QgRE9VQkxFIFBSRUNJU0lPTiwKICAgICAgICBjYWxsX21hcmtl
dF9jYXBfdXNkIERPVUJMRSBQUkVDSVNJT04sCiAgICAgICAgY3VycmVudF9wcmljZV91c2QgRE9VQkxFIFBSRUNJU0lPTiwKICAgICAgICBjdXJyZW50X21h
cmtldF9jYXBfdXNkIERPVUJMRSBQUkVDSVNJT04sCiAgICAgICAgcGVha19wcmljZV91c2QgRE9VQkxFIFBSRUNJU0lPTiwKICAgICAgICBwZWFrX21hcmtl
dF9jYXBfdXNkIERPVUJMRSBQUkVDSVNJT04sCiAgICAgICAgY3VycmVudF9tdWx0aXBsZSBET1VCTEUgUFJFQ0lTSU9OLAogICAgICAgIHBlYWtfbXVsdGlw
bGUgRE9VQkxFIFBSRUNJU0lPTiwKICAgICAgICBtYXhfZHJhd2Rvd25fcGN0IERPVUJMRSBQUkVDSVNJT04sCiAgICAgICAgc2lnbmFsX3Njb3JlIElOVEVH
RVIgTk9UIE5VTEwgREVGQVVMVCAwLAogICAgICAgIGJ1eV9wcmVzc3VyZV9wY3QgRE9VQkxFIFBSRUNJU0lPTiwKICAgICAgICB2b2x1bWVfc3Bpa2UgRE9V
QkxFIFBSRUNJU0lPTiwKICAgICAgICBsaXF1aWRpdHlfdXNkIERPVUJMRSBQUkVDSVNJT04sCiAgICAgICAgcHJpY2VfY2hhbmdlXzVtIERPVUJMRSBQUkVD
SVNJT04sCiAgICAgICAgcGFpcl9hZ2VfbWludXRlcyBET1VCTEUgUFJFQ0lTSU9OLAogICAgICAgIHJlYXNvbnNfanNvbiBURVhUIE5PVCBOVUxMIERFRkFV
TFQgJ1tdJywKICAgICAgICBiYXNlbGluZSBCT09MRUFOIE5PVCBOVUxMIERFRkFVTFQgRkFMU0UsCiAgICAgICAgbGFzdF9wdWJsaWNfbWlsZXN0b25lIElO
VEVHRVIgTk9UIE5VTEwgREVGQVVMVCAwLAogICAgICAgIG1pbGVzdG9uZV8yeF9hdCBUSU1FU1RBTVBUWiwKICAgICAgICBtaWxlc3RvbmVfNXhfYXQgVElN
RVNUQU1QVFosCiAgICAgICAgbWlsZXN0b25lXzEweF9hdCBUSU1FU1RBTVBUWiwKICAgICAgICBtaWxlc3RvbmVfMjB4X2F0IFRJTUVTVEFNUFRaLAogICAg
ICAgIG1pbGVzdG9uZV81MHhfYXQgVElNRVNUQU1QVFosCiAgICAgICAgbWlsZXN0b25lXzEwMHhfYXQgVElNRVNUQU1QVFosCiAgICAgICAgdGVsZWdyYW1f
MnhfbWVzc2FnZV9pZCBCSUdJTlQsCiAgICAgICAgdGVsZWdyYW1fNXhfbWVzc2FnZV9pZCBCSUdJTlQsCiAgICAgICAgdGVsZWdyYW1fMTB4X21lc3NhZ2Vf
aWQgQklHSU5ULAogICAgICAgIGNyZWF0ZWRfYXQgVElNRVNUQU1QVFogTk9UIE5VTEwgREVGQVVMVCBOT1coKSwKICAgICAgICB1cGRhdGVkX2F0IFRJTUVT
VEFNUFRaIE5PVCBOVUxMIERFRkFVTFQgTk9XKCkKICAgICAgKQogICAgYDsKCiAgICBhd2FpdCBzcWxgCiAgICAgIENSRUFURSBJTkRFWCBJRiBOT1QgRVhJ
U1RTIG1lbWVzY29wZV9jYWxsX3N0b3J5X2NhbGxlZF9pZHgKICAgICAgT04gbWVtZXNjb3BlX2NhbGxfc3RvcnkgKGNhbGxlZF9hdCBERVNDKQogICAgYDsK
CiAgICBhd2FpdCBzcWxgCiAgICAgIENSRUFURSBJTkRFWCBJRiBOT1QgRVhJU1RTIG1lbWVzY29wZV9jYWxsX3N0b3J5X3BlYWtfaWR4CiAgICAgIE9OIG1l
bWVzY29wZV9jYWxsX3N0b3J5IChwZWFrX211bHRpcGxlIERFU0MgTlVMTFMgTEFTVCkKICAgIGA7CgogICAgYXdhaXQgc3FsYAogICAgICBDUkVBVEUgVEFC
TEUgSUYgTk9UIEVYSVNUUyBtZW1lc2NvcGVfY29udGVudF9zZXR0aW5ncyAoCiAgICAgICAgaWQgSU5URUdFUiBQUklNQVJZIEtFWSwKICAgICAgICBjb250
ZW50X2hxX2NoYXRfaWQgVEVYVCwKICAgICAgICB1cGRhdGVkX2F0IFRJTUVTVEFNUFRaIE5PVCBOVUxMIERFRkFVTFQgTk9XKCkKICAgICAgKQogICAgYDsK
CiAgICBhd2FpdCBzcWxgCiAgICAgIElOU0VSVCBJTlRPIG1lbWVzY29wZV9jb250ZW50X3NldHRpbmdzIChpZCkKICAgICAgVkFMVUVTICgxKQogICAgICBP
TiBDT05GTElDVCAoaWQpIERPIE5PVEhJTkcKICAgIGA7CgogICAgYXdhaXQgc3FsYAogICAgICBDUkVBVEUgVEFCTEUgSUYgTk9UIEVYSVNUUyBtZW1lc2Nv
cGVfY29udGVudF9vcHBvcnR1bml0aWVzICgKICAgICAgICBpZCBCSUdTRVJJQUwgUFJJTUFSWSBLRVksCiAgICAgICAgc2lnbmFsX3JlY29yZF9pZCBURVhU
LAogICAgICAgIHB1YmxpY19pZCBURVhULAogICAgICAgIG9wcG9ydHVuaXR5X3R5cGUgVEVYVCBOT1QgTlVMTCwKICAgICAgICBwcmlvcml0eSBURVhUIE5P
VCBOVUxMLAogICAgICAgIG1pbGVzdG9uZV9tdWx0aXBsZSBET1VCTEUgUFJFQ0lTSU9OLAogICAgICAgIGRyYWZ0X3RleHQgVEVYVCBOT1QgTlVMTCwKICAg
ICAgICBzdGF0dXMgVEVYVCBOT1QgTlVMTCBERUZBVUxUICdwZW5kaW5nJywKICAgICAgICB0ZWxlZ3JhbV9tZXNzYWdlX2lkIEJJR0lOVCwKICAgICAgICBj
cmVhdGVkX2F0IFRJTUVTVEFNUFRaIE5PVCBOVUxMIERFRkFVTFQgTk9XKCksCiAgICAgICAgc2VudF9hdCBUSU1FU1RBTVBUWiwKICAgICAgICB1cGRhdGVk
X2F0IFRJTUVTVEFNUFRaIE5PVCBOVUxMIERFRkFVTFQgTk9XKCksCiAgICAgICAgVU5JUVVFIChzaWduYWxfcmVjb3JkX2lkLCBvcHBvcnR1bml0eV90eXBl
KQogICAgICApCiAgICBgOwoKICAgIGF3YWl0IHNxbGAKICAgICAgQ1JFQVRFIFRBQkxFIElGIE5PVCBFWElTVFMgbWVtZXNjb3BlX3B1YmxpY19yZXBvcnRz
ICgKICAgICAgICByZXBvcnRfa2V5IFRFWFQgUFJJTUFSWSBLRVksCiAgICAgICAgcmVwb3J0X3R5cGUgVEVYVCBOT1QgTlVMTCwKICAgICAgICByZXBvcnRf
ZGF0ZSBURVhUIE5PVCBOVUxMLAogICAgICAgIHB1YmxpY19tZXNzYWdlX2lkIEJJR0lOVCwKICAgICAgICBjb250ZW50X2hxX21lc3NhZ2VfaWQgQklHSU5U
LAogICAgICAgIGNyZWF0ZWRfYXQgVElNRVNUQU1QVFogTk9UIE5VTEwgREVGQVVMVCBOT1coKQogICAgICApCiAgICBgOwogIH0pKCkuY2F0Y2goKGVycm9y
KSA9PiB7CiAgICBzY2hlbWFQcm9taXNlID0gbnVsbDsKICAgIHRocm93IGVycm9yOwogIH0pOwoKICByZXR1cm4gc2NoZW1hUHJvbWlzZTsKfQoKdHlwZSBE
ZXhQYWlyID0gewogIGNoYWluSWQ/OiBzdHJpbmc7CiAgcHJpY2VVc2Q/OiBzdHJpbmc7CiAgbWFya2V0Q2FwPzogbnVtYmVyOwogIGZkdj86IG51bWJlcjsK
ICBiYXNlVG9rZW4/OiB7IGFkZHJlc3M/OiBzdHJpbmcgfTsKICBsaXF1aWRpdHk/OiB7IHVzZD86IG51bWJlciB9Owp9OwoKYXN5bmMgZnVuY3Rpb24gZmV0
Y2hNYXJrZXRTbmFwc2hvdHMoYWRkcmVzc2VzOiBzdHJpbmdbXSkgewogIGNvbnN0IHVuaXF1ZSA9IEFycmF5LmZyb20obmV3IFNldChhZGRyZXNzZXMuZmls
dGVyKEJvb2xlYW4pKSk7CiAgY29uc3QgcmVzdWx0ID0gbmV3IE1hcDxzdHJpbmcsIE1hcmtldFNuYXBzaG90PigpOwoKICBmb3IgKGxldCBpbmRleCA9IDA7
IGluZGV4IDwgdW5pcXVlLmxlbmd0aDsgaW5kZXggKz0gMzApIHsKICAgIGNvbnN0IGJhdGNoID0gdW5pcXVlLnNsaWNlKGluZGV4LCBpbmRleCArIDMwKTsK
ICAgIGlmIChiYXRjaC5sZW5ndGggPT09IDApIGNvbnRpbnVlOwoKICAgIHRyeSB7CiAgICAgIGNvbnN0IHJlc3BvbnNlID0gYXdhaXQgZmV0Y2goCiAgICAg
ICAgYGh0dHBzOi8vYXBpLmRleHNjcmVlbmVyLmNvbS90b2tlbnMvdjEvc29sYW5hLyR7YmF0Y2guam9pbigiLCIpfWAsCiAgICAgICAgeyBjYWNoZTogIm5v
LXN0b3JlIiwgaGVhZGVyczogeyBhY2NlcHQ6ICJhcHBsaWNhdGlvbi9qc29uIiB9IH0sCiAgICAgICk7CiAgICAgIGlmICghcmVzcG9uc2Uub2spIGNvbnRp
bnVlOwoKICAgICAgY29uc3QgcGFpcnMgPSAoYXdhaXQgcmVzcG9uc2UuanNvbigpKSBhcyBEZXhQYWlyW107CiAgICAgIGNvbnN0IGJlc3RMaXF1aWRpdHkg
PSBuZXcgTWFwPHN0cmluZywgbnVtYmVyPigpOwoKICAgICAgZm9yIChjb25zdCBwYWlyIG9mIHBhaXJzKSB7CiAgICAgICAgY29uc3QgYWRkcmVzcyA9IHBh
aXIuYmFzZVRva2VuPy5hZGRyZXNzOwogICAgICAgIGlmICghYWRkcmVzcykgY29udGludWU7CiAgICAgICAgY29uc3QgbGlxdWlkaXR5ID0gTnVtYmVyKHBh
aXIubGlxdWlkaXR5Py51c2QgPz8gMCk7CiAgICAgICAgaWYgKGxpcXVpZGl0eSA8IChiZXN0TGlxdWlkaXR5LmdldChhZGRyZXNzKSA/PyAtMSkpIGNvbnRp
bnVlOwoKICAgICAgICBjb25zdCBwYXJzZWRQcmljZSA9IE51bWJlcihwYWlyLnByaWNlVXNkKTsKICAgICAgICBjb25zdCBtYXJrZXRDYXAgPSBOdW1iZXIo
cGFpci5tYXJrZXRDYXAgPz8gcGFpci5mZHYpOwogICAgICAgIHJlc3VsdC5zZXQoYWRkcmVzcywgewogICAgICAgICAgcHJpY2VVc2Q6IE51bWJlci5pc0Zp
bml0ZShwYXJzZWRQcmljZSkgJiYgcGFyc2VkUHJpY2UgPiAwID8gcGFyc2VkUHJpY2UgOiBudWxsLAogICAgICAgICAgbWFya2V0Q2FwVXNkOiBOdW1iZXIu
aXNGaW5pdGUobWFya2V0Q2FwKSAmJiBtYXJrZXRDYXAgPiAwID8gbWFya2V0Q2FwIDogbnVsbCwKICAgICAgICAgIGxpcXVpZGl0eVVzZDogTnVtYmVyLmlz
RmluaXRlKGxpcXVpZGl0eSkgJiYgbGlxdWlkaXR5ID4gMCA/IGxpcXVpZGl0eSA6IG51bGwsCiAgICAgICAgfSk7CiAgICAgICAgYmVzdExpcXVpZGl0eS5z
ZXQoYWRkcmVzcywgbGlxdWlkaXR5KTsKICAgICAgfQogICAgfSBjYXRjaCB7CiAgICAgIC8vIEtlZXAgdGhlIGxhc3Qgc3RvcmVkIHNuYXBzaG90IHdoZW4g
RGV4U2NyZWVuZXIgaXMgdGVtcG9yYXJpbHkgdW5hdmFpbGFibGUuCiAgICB9CiAgfQoKICByZXR1cm4gcmVzdWx0Owp9Cgphc3luYyBmdW5jdGlvbiBpbml0
aWFsaXplQ2FsbFN0b3J5QmFzZWxpbmUoKSB7CiAgYXdhaXQgZW5zdXJlQ2FsbFN0b3J5U2NoZW1hKCk7CiAgY29uc3Qgc3FsID0gc3FsQ2xpZW50KCk7Cgog
IGNvbnN0IGV4aXN0aW5nID0gYXdhaXQgc3FsYAogICAgU0VMRUNUIGluaXRpYWxpemVkX2F0CiAgICBGUk9NIG1lbWVzY29wZV9jYWxsX3N0b3J5X3N0YXRl
CiAgICBXSEVSRSBpZCA9IDEKICAgIExJTUlUIDEKICBgOwoKICBpZiAoZXhpc3RpbmdbMF0pIHsKICAgIHJldHVybiB7IGluaXRpYWxpemVkOiBmYWxzZSwg
aW5pdGlhbGl6ZWRBdDogbWlsbGlzKChleGlzdGluZ1swXSBhcyBEYlJvdykuaW5pdGlhbGl6ZWRfYXQpIH07CiAgfQoKICBjb25zdCBub3cgPSBuZXcgRGF0
ZSgpOwogIGF3YWl0IHNxbGAKICAgIElOU0VSVCBJTlRPIG1lbWVzY29wZV9jYWxsX3N0b3J5X3N0YXRlIChpZCwgaW5pdGlhbGl6ZWRfYXQpCiAgICBWQUxV
RVMgKDEsICR7bm93LnRvSVNPU3RyaW5nKCl9KQogICAgT04gQ09ORkxJQ1QgKGlkKSBETyBOT1RISU5HCiAgYDsKCiAgcmV0dXJuIHsgaW5pdGlhbGl6ZWQ6
IHRydWUsIGluaXRpYWxpemVkQXQ6IG5vdy5nZXRUaW1lKCkgfTsKfQoKYXN5bmMgZnVuY3Rpb24gZW5zdXJlUHVibGljSWQoc2lnbmFsUmVjb3JkSWQ6IHN0
cmluZykgewogIGNvbnN0IHNxbCA9IHNxbENsaWVudCgpOwogIGNvbnN0IHJvd3MgPSBhd2FpdCBzcWxgCiAgICBTRUxFQ1QgY2FsbF9ubywgcHVibGljX2lk
LCBjYWxsZWRfYXQKICAgIEZST00gbWVtZXNjb3BlX2NhbGxfc3RvcnkKICAgIFdIRVJFIHNpZ25hbF9yZWNvcmRfaWQgPSAke3NpZ25hbFJlY29yZElkfQog
ICAgTElNSVQgMQogIGA7CiAgY29uc3Qgcm93ID0gcm93c1swXSBhcyBEYlJvdyB8IHVuZGVmaW5lZDsKICBpZiAoIXJvdykgcmV0dXJuICIiOwogIGlmIChy
b3cucHVibGljX2lkKSByZXR1cm4gU3RyaW5nKHJvdy5wdWJsaWNfaWQpOwoKICBjb25zdCBwdWJsaWNJZCA9IHB1YmxpY0lkRm9yKG51bShyb3cuY2FsbF9u
byksIG1pbGxpcyhyb3cuY2FsbGVkX2F0KSk7CiAgYXdhaXQgc3FsYAogICAgVVBEQVRFIG1lbWVzY29wZV9jYWxsX3N0b3J5CiAgICBTRVQgcHVibGljX2lk
ID0gJHtwdWJsaWNJZH0sIHVwZGF0ZWRfYXQgPSBOT1coKQogICAgV0hFUkUgc2lnbmFsX3JlY29yZF9pZCA9ICR7c2lnbmFsUmVjb3JkSWR9CiAgYDsKICBy
ZXR1cm4gcHVibGljSWQ7Cn0KCmFzeW5jIGZ1bmN0aW9uIHNldE1pbGVzdG9uZVRpbWVzKAogIHNpZ25hbFJlY29yZElkOiBzdHJpbmcsCiAgcGVha011bHRp
cGxlOiBudW1iZXIgfCBudWxsLAopIHsKICBpZiAocGVha011bHRpcGxlID09PSBudWxsKSByZXR1cm47CiAgY29uc3Qgc3FsID0gc3FsQ2xpZW50KCk7CiAg
Y29uc3QgdGhyZXNob2xkcyA9IFsyLCA1LCAxMCwgMjAsIDUwLCAxMDBdOwogIGZvciAoY29uc3QgdGhyZXNob2xkIG9mIHRocmVzaG9sZHMpIHsKICAgIGlm
IChwZWFrTXVsdGlwbGUgPCB0aHJlc2hvbGQpIGNvbnRpbnVlOwogICAgY29uc3QgY29sdW1uID0gbWlsZXN0b25lQ29sdW1uKHRocmVzaG9sZCk7CiAgICBp
ZiAoY29sdW1uID09PSAibWlsZXN0b25lXzJ4X2F0IikgewogICAgICBhd2FpdCBzcWxgVVBEQVRFIG1lbWVzY29wZV9jYWxsX3N0b3J5IFNFVCBtaWxlc3Rv
bmVfMnhfYXQgPSBDT0FMRVNDRShtaWxlc3RvbmVfMnhfYXQsIE5PVygpKSBXSEVSRSBzaWduYWxfcmVjb3JkX2lkID0gJHtzaWduYWxSZWNvcmRJZH1gOwog
ICAgfSBlbHNlIGlmIChjb2x1bW4gPT09ICJtaWxlc3RvbmVfNXhfYXQiKSB7CiAgICAgIGF3YWl0IHNxbGBVUERBVEUgbWVtZXNjb3BlX2NhbGxfc3Rvcnkg
U0VUIG1pbGVzdG9uZV81eF9hdCA9IENPQUxFU0NFKG1pbGVzdG9uZV81eF9hdCwgTk9XKCkpIFdIRVJFIHNpZ25hbF9yZWNvcmRfaWQgPSAke3NpZ25hbFJl
Y29yZElkfWA7CiAgICB9IGVsc2UgaWYgKGNvbHVtbiA9PT0gIm1pbGVzdG9uZV8xMHhfYXQiKSB7CiAgICAgIGF3YWl0IHNxbGBVUERBVEUgbWVtZXNjb3Bl
X2NhbGxfc3RvcnkgU0VUIG1pbGVzdG9uZV8xMHhfYXQgPSBDT0FMRVNDRShtaWxlc3RvbmVfMTB4X2F0LCBOT1coKSkgV0hFUkUgc2lnbmFsX3JlY29yZF9p
ZCA9ICR7c2lnbmFsUmVjb3JkSWR9YDsKICAgIH0gZWxzZSBpZiAoY29sdW1uID09PSAibWlsZXN0b25lXzIweF9hdCIpIHsKICAgICAgYXdhaXQgc3FsYFVQ
REFURSBtZW1lc2NvcGVfY2FsbF9zdG9yeSBTRVQgbWlsZXN0b25lXzIweF9hdCA9IENPQUxFU0NFKG1pbGVzdG9uZV8yMHhfYXQsIE5PVygpKSBXSEVSRSBz
aWduYWxfcmVjb3JkX2lkID0gJHtzaWduYWxSZWNvcmRJZH1gOwogICAgfSBlbHNlIGlmIChjb2x1bW4gPT09ICJtaWxlc3RvbmVfNTB4X2F0IikgewogICAg
ICBhd2FpdCBzcWxgVVBEQVRFIG1lbWVzY29wZV9jYWxsX3N0b3J5IFNFVCBtaWxlc3RvbmVfNTB4X2F0ID0gQ09BTEVTQ0UobWlsZXN0b25lXzUweF9hdCwg
Tk9XKCkpIFdIRVJFIHNpZ25hbF9yZWNvcmRfaWQgPSAke3NpZ25hbFJlY29yZElkfWA7CiAgICB9IGVsc2UgewogICAgICBhd2FpdCBzcWxgVVBEQVRFIG1l
bWVzY29wZV9jYWxsX3N0b3J5IFNFVCBtaWxlc3RvbmVfMTAweF9hdCA9IENPQUxFU0NFKG1pbGVzdG9uZV8xMDB4X2F0LCBOT1coKSkgV0hFUkUgc2lnbmFs
X3JlY29yZF9pZCA9ICR7c2lnbmFsUmVjb3JkSWR9YDsKICAgIH0KICB9Cn0KCmFzeW5jIGZ1bmN0aW9uIHN5bmNDYWxsUm93cyh0b2tlbnM6IFRlcm1pbmFs
VG9rZW5bXSwgc2lnbmFsczogU2lnbmFsQ2FsbFtdKSB7CiAgY29uc3Qgc3RhdGUgPSBhd2FpdCBpbml0aWFsaXplQ2FsbFN0b3J5QmFzZWxpbmUoKTsKICBj
b25zdCBzcWwgPSBzcWxDbGllbnQoKTsKCiAgY29uc3QgcmVjb3JkUm93cyA9IGF3YWl0IHNxbGAKICAgIFNFTEVDVCAqCiAgICBGUk9NIG1lbWVzY29wZV9z
aWduYWxfcmVjb3JkcwogICAgV0hFUkUgb3BlbmVkX2F0ID49IE5PVygpIC0gSU5URVJWQUwgJzYwIGRheXMnCiAgICBPUkRFUiBCWSBvcGVuZWRfYXQgQVND
CiAgICBMSU1JVCAxMDAwCiAgYDsKCiAgY29uc3QgcmVjb3JkczogU2lnbmFsUmVjb3JkUm93W10gPSByZWNvcmRSb3dzLm1hcCgocm93OiB1bmtub3duKSA9
PiBub3JtYWxpemVTaWduYWxSZWNvcmQocm93IGFzIERiUm93KSk7CiAgY29uc3QgdG9rZW5NYXAgPSBuZXcgTWFwKHRva2Vucy5tYXAoKHRva2VuKSA9PiBb
dG9rZW4uYWRkcmVzcywgdG9rZW5dKSk7CiAgY29uc3Qgc2lnbmFsTWFwID0gbmV3IE1hcChzaWduYWxzLm1hcCgoc2lnbmFsKSA9PiBbc2lnbmFsLmlkLCBz
aWduYWxdKSk7CiAgY29uc3QgbWFya2V0U25hcHNob3RzID0gYXdhaXQgZmV0Y2hNYXJrZXRTbmFwc2hvdHMocmVjb3Jkcy5tYXAoKHJlY29yZDogU2lnbmFs
UmVjb3JkUm93KSA9PiByZWNvcmQudG9rZW5BZGRyZXNzKSk7CgogIGZvciAoY29uc3QgcmVjb3JkIG9mIHJlY29yZHMpIHsKICAgIGNvbnN0IHRva2VuID0g
dG9rZW5NYXAuZ2V0KHJlY29yZC50b2tlbkFkZHJlc3MpOwogICAgY29uc3Qgc2lnbmFsID0gc2lnbmFsTWFwLmdldChyZWNvcmQuc2lnbmFsSWQpOwogICAg
Y29uc3QgbWFya2V0ID0gbWFya2V0U25hcHNob3RzLmdldChyZWNvcmQudG9rZW5BZGRyZXNzKTsKCiAgICBjb25zdCBjdXJyZW50UHJpY2UgPSB0b2tlbj8u
cHJpY2VVc2QgPz8gbWFya2V0Py5wcmljZVVzZCA/PyBudWxsOwogICAgY29uc3QgY3VycmVudE1hcmtldENhcCA9IHRva2VuPy5tYXJrZXRDYXAgPz8gbWFy
a2V0Py5tYXJrZXRDYXBVc2QgPz8gbnVsbDsKICAgIGNvbnN0IGVudHJ5ID0gcmVjb3JkLmVudHJ5UHJpY2VVc2Q7CgogICAgY29uc3QgaW5mZXJyZWRDYWxs
TWFya2V0Q2FwID0KICAgICAgY3VycmVudE1hcmtldENhcCAhPT0gbnVsbCAmJiBjdXJyZW50UHJpY2UgIT09IG51bGwgJiYgY3VycmVudFByaWNlID4gMCAm
JiBlbnRyeSAhPT0gbnVsbCAmJiBlbnRyeSA+IDAKICAgICAgICA/IGN1cnJlbnRNYXJrZXRDYXAgKiAoZW50cnkgLyBjdXJyZW50UHJpY2UpCiAgICAgICAg
OiBzaWduYWw/Lm1hcmtldENhcCA/PyBudWxsOwoKICAgIGNvbnN0IGN1cnJlbnRNdWx0aXBsZSA9CiAgICAgIGVudHJ5ICE9PSBudWxsICYmIGVudHJ5ID4g
MCAmJiBjdXJyZW50UHJpY2UgIT09IG51bGwgJiYgY3VycmVudFByaWNlID4gMAogICAgICAgID8gY3VycmVudFByaWNlIC8gZW50cnkKICAgICAgICA6IG51
bGw7CgogICAgY29uc3QgcmVjb3JkUGVha011bHRpcGxlID0KICAgICAgcmVjb3JkLnBlYWtHYWluUGVyY2VudCAhPT0gbnVsbAogICAgICAgID8gTWF0aC5t
YXgoMCwgMSArIHJlY29yZC5wZWFrR2FpblBlcmNlbnQgLyAxMDApCiAgICAgICAgOiBudWxsOwoKICAgIGNvbnN0IGV4aXN0aW5nUm93cyA9IGF3YWl0IHNx
bGAKICAgICAgU0VMRUNUICoKICAgICAgRlJPTSBtZW1lc2NvcGVfY2FsbF9zdG9yeQogICAgICBXSEVSRSBzaWduYWxfcmVjb3JkX2lkID0gJHtyZWNvcmQu
aWR9CiAgICAgIExJTUlUIDEKICAgIGA7CiAgICBjb25zdCBleGlzdGluZyA9IGV4aXN0aW5nUm93c1swXSA/IG5vcm1hbGl6ZUNhbGwoZXhpc3RpbmdSb3dz
WzBdIGFzIERiUm93KSA6IG51bGw7CgogICAgY29uc3QgY2FsbE1hcmtldENhcCA9IGV4aXN0aW5nPy5jYWxsTWFya2V0Q2FwVXNkID8/IHNpZ25hbD8ubWFy
a2V0Q2FwID8/IGluZmVycmVkQ2FsbE1hcmtldENhcDsKICAgIGNvbnN0IHBlYWtNdWx0aXBsZSA9IE1hdGgubWF4KAogICAgICBleGlzdGluZz8ucGVha011
bHRpcGxlID8/IDAsCiAgICAgIGN1cnJlbnRNdWx0aXBsZSA/PyAwLAogICAgICByZWNvcmRQZWFrTXVsdGlwbGUgPz8gMCwKICAgICAgMSwKICAgICk7CiAg
ICBjb25zdCBwZWFrUHJpY2UgPSBNYXRoLm1heChleGlzdGluZz8ucGVha1ByaWNlVXNkID8/IDAsIGN1cnJlbnRQcmljZSA/PyAwLCBlbnRyeSA/PyAwKSB8
fCBudWxsOwogICAgY29uc3QgZGVyaXZlZFBlYWtNYyA9IGNhbGxNYXJrZXRDYXAgIT09IG51bGwgPyBjYWxsTWFya2V0Q2FwICogcGVha011bHRpcGxlIDog
bnVsbDsKICAgIGNvbnN0IHBlYWtNYXJrZXRDYXAgPSBNYXRoLm1heChleGlzdGluZz8ucGVha01hcmtldENhcFVzZCA/PyAwLCBjdXJyZW50TWFya2V0Q2Fw
ID8/IDAsIGRlcml2ZWRQZWFrTWMgPz8gMCkgfHwgbnVsbDsKICAgIGNvbnN0IG1heERyYXdkb3duID0gTWF0aC5taW4oCiAgICAgIGV4aXN0aW5nPy5tYXhE
cmF3ZG93blBjdCA/PyAwLAogICAgICByZWNvcmQubWF4RHJhd2Rvd25QZXJjZW50ID8/IDAsCiAgICAgIGN1cnJlbnRNdWx0aXBsZSAhPT0gbnVsbCA/IChj
dXJyZW50TXVsdGlwbGUgLSAxKSAqIDEwMCA6IDAsCiAgICApOwoKICAgIGNvbnN0IGJhc2VsaW5lID0gcmVjb3JkLm9wZW5lZEF0IDw9IHN0YXRlLmluaXRp
YWxpemVkQXQ7CiAgICBjb25zdCBpbml0aWFsUHVibGljTWlsZXN0b25lID0gYmFzZWxpbmUgPyBoaWdoZXN0UHVibGljTWlsZXN0b25lKHBlYWtNdWx0aXBs
ZSkgOiAwOwogICAgY29uc3QgcmVhc29ucyA9IHNpZ25hbD8ucmVhc29ucyA/PyBleGlzdGluZz8ucmVhc29ucyA/PyBbXTsKICAgIGNvbnN0IGJ1eVByZXNz
dXJlUGN0ID0gc2lnbmFsPy5idXlTaGFyZTVtICE9PSBudWxsICYmIHNpZ25hbD8uYnV5U2hhcmU1bSAhPT0gdW5kZWZpbmVkCiAgICAgID8gc2lnbmFsLmJ1
eVNoYXJlNW0gKiAxMDAKICAgICAgOiBleGlzdGluZz8uYnV5UHJlc3N1cmVQY3QgPz8gbnVsbDsKCiAgICBpZiAoIWV4aXN0aW5nKSB7CiAgICAgIGF3YWl0
IHNxbGAKICAgICAgICBJTlNFUlQgSU5UTyBtZW1lc2NvcGVfY2FsbF9zdG9yeSAoCiAgICAgICAgICBzaWduYWxfcmVjb3JkX2lkLAogICAgICAgICAgc2ln
bmFsX2lkLAogICAgICAgICAgdG9rZW5fYWRkcmVzcywKICAgICAgICAgIHN5bWJvbCwKICAgICAgICAgIG5hbWUsCiAgICAgICAgICBjYWxsZWRfYXQsCiAg
ICAgICAgICBlbnRyeV9wcmljZV91c2QsCiAgICAgICAgICBjYWxsX21hcmtldF9jYXBfdXNkLAogICAgICAgICAgY3VycmVudF9wcmljZV91c2QsCiAgICAg
ICAgICBjdXJyZW50X21hcmtldF9jYXBfdXNkLAogICAgICAgICAgcGVha19wcmljZV91c2QsCiAgICAgICAgICBwZWFrX21hcmtldF9jYXBfdXNkLAogICAg
ICAgICAgY3VycmVudF9tdWx0aXBsZSwKICAgICAgICAgIHBlYWtfbXVsdGlwbGUsCiAgICAgICAgICBtYXhfZHJhd2Rvd25fcGN0LAogICAgICAgICAgc2ln
bmFsX3Njb3JlLAogICAgICAgICAgYnV5X3ByZXNzdXJlX3BjdCwKICAgICAgICAgIHZvbHVtZV9zcGlrZSwKICAgICAgICAgIGxpcXVpZGl0eV91c2QsCiAg
ICAgICAgICBwcmljZV9jaGFuZ2VfNW0sCiAgICAgICAgICBwYWlyX2FnZV9taW51dGVzLAogICAgICAgICAgcmVhc29uc19qc29uLAogICAgICAgICAgYmFz
ZWxpbmUsCiAgICAgICAgICBsYXN0X3B1YmxpY19taWxlc3RvbmUsCiAgICAgICAgICB1cGRhdGVkX2F0CiAgICAgICAgKSBWQUxVRVMgKAogICAgICAgICAg
JHtyZWNvcmQuaWR9LAogICAgICAgICAgJHtyZWNvcmQuc2lnbmFsSWR9LAogICAgICAgICAgJHtyZWNvcmQudG9rZW5BZGRyZXNzfSwKICAgICAgICAgICR7
cmVjb3JkLnN5bWJvbH0sCiAgICAgICAgICAke3JlY29yZC5uYW1lfSwKICAgICAgICAgICR7bmV3IERhdGUocmVjb3JkLm9wZW5lZEF0KS50b0lTT1N0cmlu
ZygpfSwKICAgICAgICAgICR7ZW50cnl9LAogICAgICAgICAgJHtjYWxsTWFya2V0Q2FwfSwKICAgICAgICAgICR7Y3VycmVudFByaWNlfSwKICAgICAgICAg
ICR7Y3VycmVudE1hcmtldENhcH0sCiAgICAgICAgICAke3BlYWtQcmljZX0sCiAgICAgICAgICAke3BlYWtNYXJrZXRDYXB9LAogICAgICAgICAgJHtjdXJy
ZW50TXVsdGlwbGV9LAogICAgICAgICAgJHtwZWFrTXVsdGlwbGV9LAogICAgICAgICAgJHttYXhEcmF3ZG93bn0sCiAgICAgICAgICAke3NpZ25hbD8uc2ln
bmFsU2NvcmUgPz8gcmVjb3JkLnNjb3JlQXRFbnRyeX0sCiAgICAgICAgICAke2J1eVByZXNzdXJlUGN0fSwKICAgICAgICAgICR7c2lnbmFsPy52b2x1bWVT
cGlrZTVtID8/IG51bGx9LAogICAgICAgICAgJHtzaWduYWw/LmxpcXVpZGl0eVVzZCA/PyB0b2tlbj8ubGlxdWlkaXR5VXNkID8/IG1hcmtldD8ubGlxdWlk
aXR5VXNkID8/IG51bGx9LAogICAgICAgICAgJHtzaWduYWw/LnByaWNlQ2hhbmdlNW0gPz8gdG9rZW4/LnByaWNlQ2hhbmdlLm01ID8/IG51bGx9LAogICAg
ICAgICAgJHtzaWduYWw/LnBhaXJBZ2VNaW51dGVzID8/IHRva2VuPy5wYWlyQWdlTWludXRlcyA/PyBudWxsfSwKICAgICAgICAgICR7SlNPTi5zdHJpbmdp
ZnkocmVhc29ucyl9LAogICAgICAgICAgJHtiYXNlbGluZX0sCiAgICAgICAgICAke2luaXRpYWxQdWJsaWNNaWxlc3RvbmV9LAogICAgICAgICAgTk9XKCkK
ICAgICAgICApCiAgICAgICAgT04gQ09ORkxJQ1QgKHNpZ25hbF9yZWNvcmRfaWQpIERPIE5PVEhJTkcKICAgICAgYDsKICAgIH0gZWxzZSB7CiAgICAgIGF3
YWl0IHNxbGAKICAgICAgICBVUERBVEUgbWVtZXNjb3BlX2NhbGxfc3RvcnkKICAgICAgICBTRVQKICAgICAgICAgIGN1cnJlbnRfcHJpY2VfdXNkID0gQ09B
TEVTQ0UoJHtjdXJyZW50UHJpY2V9LCBjdXJyZW50X3ByaWNlX3VzZCksCiAgICAgICAgICBjdXJyZW50X21hcmtldF9jYXBfdXNkID0gQ09BTEVTQ0UoJHtj
dXJyZW50TWFya2V0Q2FwfSwgY3VycmVudF9tYXJrZXRfY2FwX3VzZCksCiAgICAgICAgICBjYWxsX21hcmtldF9jYXBfdXNkID0gQ09BTEVTQ0UoY2FsbF9t
YXJrZXRfY2FwX3VzZCwgJHtjYWxsTWFya2V0Q2FwfSksCiAgICAgICAgICBwZWFrX3ByaWNlX3VzZCA9IEdSRUFURVNUKENPQUxFU0NFKHBlYWtfcHJpY2Vf
dXNkLCAwKSwgQ09BTEVTQ0UoJHtwZWFrUHJpY2V9LCAwKSksCiAgICAgICAgICBwZWFrX21hcmtldF9jYXBfdXNkID0gR1JFQVRFU1QoQ09BTEVTQ0UocGVh
a19tYXJrZXRfY2FwX3VzZCwgMCksIENPQUxFU0NFKCR7cGVha01hcmtldENhcH0sIDApKSwKICAgICAgICAgIGN1cnJlbnRfbXVsdGlwbGUgPSBDT0FMRVND
RSgke2N1cnJlbnRNdWx0aXBsZX0sIGN1cnJlbnRfbXVsdGlwbGUpLAogICAgICAgICAgcGVha19tdWx0aXBsZSA9IEdSRUFURVNUKENPQUxFU0NFKHBlYWtf
bXVsdGlwbGUsIDEpLCBDT0FMRVNDRSgke3BlYWtNdWx0aXBsZX0sIDEpKSwKICAgICAgICAgIG1heF9kcmF3ZG93bl9wY3QgPSBMRUFTVChDT0FMRVNDRSht
YXhfZHJhd2Rvd25fcGN0LCAwKSwgQ09BTEVTQ0UoJHttYXhEcmF3ZG93bn0sIDApKSwKICAgICAgICAgIHNpZ25hbF9zY29yZSA9IEdSRUFURVNUKHNpZ25h
bF9zY29yZSwgJHtzaWduYWw/LnNpZ25hbFNjb3JlID8/IHJlY29yZC5zY29yZUF0RW50cnl9KSwKICAgICAgICAgIGJ1eV9wcmVzc3VyZV9wY3QgPSBDT0FM
RVNDRShidXlfcHJlc3N1cmVfcGN0LCAke2J1eVByZXNzdXJlUGN0fSksCiAgICAgICAgICB2b2x1bWVfc3Bpa2UgPSBDT0FMRVNDRSh2b2x1bWVfc3Bpa2Us
ICR7c2lnbmFsPy52b2x1bWVTcGlrZTVtID8/IGV4aXN0aW5nLnZvbHVtZVNwaWtlID8/IG51bGx9KSwKICAgICAgICAgIGxpcXVpZGl0eV91c2QgPSBDT0FM
RVNDRSgke3NpZ25hbD8ubGlxdWlkaXR5VXNkID8/IHRva2VuPy5saXF1aWRpdHlVc2QgPz8gbWFya2V0Py5saXF1aWRpdHlVc2QgPz8gbnVsbH0sIGxpcXVp
ZGl0eV91c2QpLAogICAgICAgICAgcHJpY2VfY2hhbmdlXzVtID0gQ09BTEVTQ0UocHJpY2VfY2hhbmdlXzVtLCAke3NpZ25hbD8ucHJpY2VDaGFuZ2U1bSA/
PyB0b2tlbj8ucHJpY2VDaGFuZ2UubTUgPz8gbnVsbH0pLAogICAgICAgICAgcGFpcl9hZ2VfbWludXRlcyA9IENPQUxFU0NFKHBhaXJfYWdlX21pbnV0ZXMs
ICR7c2lnbmFsPy5wYWlyQWdlTWludXRlcyA/PyB0b2tlbj8ucGFpckFnZU1pbnV0ZXMgPz8gbnVsbH0pLAogICAgICAgICAgcmVhc29uc19qc29uID0gQ0FT
RQogICAgICAgICAgICBXSEVOIHJlYXNvbnNfanNvbiA9ICdbXScgVEhFTiAke0pTT04uc3RyaW5naWZ5KHJlYXNvbnMpfQogICAgICAgICAgICBFTFNFIHJl
YXNvbnNfanNvbgogICAgICAgICAgRU5ELAogICAgICAgICAgdXBkYXRlZF9hdCA9IE5PVygpCiAgICAgICAgV0hFUkUgc2lnbmFsX3JlY29yZF9pZCA9ICR7
cmVjb3JkLmlkfQogICAgICBgOwogICAgfQoKICAgIGF3YWl0IGVuc3VyZVB1YmxpY0lkKHJlY29yZC5pZCk7CiAgICBhd2FpdCBzZXRNaWxlc3RvbmVUaW1l
cyhyZWNvcmQuaWQsIHBlYWtNdWx0aXBsZSk7CiAgfQoKICByZXR1cm4geyBiYXNlbGluZUluaXRpYWxpemVkOiBzdGF0ZS5pbml0aWFsaXplZCwgdHJhY2tl
ZDogcmVjb3Jkcy5sZW5ndGggfTsKfQoKZXhwb3J0IGFzeW5jIGZ1bmN0aW9uIGdldENhbGxTdG9yeUZvclNpZ25hbFJlY29yZChzaWduYWxSZWNvcmRJZDog
c3RyaW5nKSB7CiAgYXdhaXQgZW5zdXJlQ2FsbFN0b3J5U2NoZW1hKCk7CiAgY29uc3Qgc3FsID0gc3FsQ2xpZW50KCk7CiAgY29uc3Qgcm93cyA9IGF3YWl0
IHNxbGAKICAgIFNFTEVDVCAqCiAgICBGUk9NIG1lbWVzY29wZV9jYWxsX3N0b3J5CiAgICBXSEVSRSBzaWduYWxfcmVjb3JkX2lkID0gJHtzaWduYWxSZWNv
cmRJZH0KICAgIExJTUlUIDEKICBgOwogIHJldHVybiByb3dzWzBdID8gbm9ybWFsaXplQ2FsbChyb3dzWzBdIGFzIERiUm93KSA6IG51bGw7Cn0KCmV4cG9y
dCBhc3luYyBmdW5jdGlvbiBnZXRDYWxsQnlQdWJsaWNJZChwdWJsaWNJZDogc3RyaW5nKSB7CiAgYXdhaXQgZW5zdXJlQ2FsbFN0b3J5U2NoZW1hKCk7CiAg
Y29uc3Qgc3FsID0gc3FsQ2xpZW50KCk7CiAgY29uc3Qgcm93cyA9IGF3YWl0IHNxbGAKICAgIFNFTEVDVCAqCiAgICBGUk9NIG1lbWVzY29wZV9jYWxsX3N0
b3J5CiAgICBXSEVSRSBVUFBFUihwdWJsaWNfaWQpID0gVVBQRVIoJHtwdWJsaWNJZH0pCiAgICBMSU1JVCAxCiAgYDsKICByZXR1cm4gcm93c1swXSA/IG5v
cm1hbGl6ZUNhbGwocm93c1swXSBhcyBEYlJvdykgOiBudWxsOwp9CgpleHBvcnQgYXN5bmMgZnVuY3Rpb24gZ2V0Q2FsbERhc2hib2FyZChkYXlzID0gMzAp
OiBQcm9taXNlPENhbGxEYXNoYm9hcmQ+IHsKICBhd2FpdCBlbnN1cmVDYWxsU3RvcnlTY2hlbWEoKTsKICBjb25zdCBzcWwgPSBzcWxDbGllbnQoKTsKICBj
b25zdCBzYWZlRGF5cyA9IE1hdGgubWF4KDEsIE1hdGgubWluKDM2NTAsIE1hdGgucm91bmQoZGF5cykpKTsKICBjb25zdCByb3dzID0gYXdhaXQgc3FsYAog
ICAgU0VMRUNUICoKICAgIEZST00gbWVtZXNjb3BlX2NhbGxfc3RvcnkKICAgIFdIRVJFIGNhbGxlZF9hdCA+PSBOT1coKSAtICgke3NhZmVEYXlzfSAqIElO
VEVSVkFMICcxIGRheScpCiAgICBPUkRFUiBCWSBjYWxsZWRfYXQgREVTQwogICAgTElNSVQgMTAwMAogIGA7CiAgY29uc3QgY2FsbHM6IENhbGxTdG9yeVtd
ID0gcm93cy5tYXAoKHJvdzogdW5rbm93bikgPT4gbm9ybWFsaXplQ2FsbChyb3cgYXMgRGJSb3cpKTsKICBjb25zdCB0b3BDYWxscyA9IFsuLi5jYWxsc10K
ICAgIC5zb3J0KChhOiBDYWxsU3RvcnksIGI6IENhbGxTdG9yeSkgPT4gKGIucGVha011bHRpcGxlID8/IDApIC0gKGEucGVha011bHRpcGxlID8/IDApKQog
ICAgLnNsaWNlKDAsIDIwKTsKCiAgcmV0dXJuIHsKICAgIGRheXM6IHNhZmVEYXlzLAogICAgdG90YWxDYWxsczogY2FsbHMubGVuZ3RoLAogICAgcmVhY2hl
ZDJ4OiBjYWxscy5maWx0ZXIoKGNhbGw6IENhbGxTdG9yeSkgPT4gKGNhbGwucGVha011bHRpcGxlID8/IDApID49IDIpLmxlbmd0aCwKICAgIHJlYWNoZWQ1
eDogY2FsbHMuZmlsdGVyKChjYWxsOiBDYWxsU3RvcnkpID0+IChjYWxsLnBlYWtNdWx0aXBsZSA/PyAwKSA+PSA1KS5sZW5ndGgsCiAgICByZWFjaGVkMTB4
OiBjYWxscy5maWx0ZXIoKGNhbGw6IENhbGxTdG9yeSkgPT4gKGNhbGwucGVha011bHRpcGxlID8/IDApID49IDEwKS5sZW5ndGgsCiAgICBtZWRpYW5QZWFr
TXVsdGlwbGU6IG1lZGlhbihjYWxscy5tYXAoKGNhbGw6IENhbGxTdG9yeSkgPT4gY2FsbC5wZWFrTXVsdGlwbGUpLmZpbHRlcigodmFsdWU6IG51bWJlciB8
IG51bGwpOiB2YWx1ZSBpcyBudW1iZXIgPT4gdmFsdWUgIT09IG51bGwpKSwKICAgIG1lZGlhbk1heERyYXdkb3duUGN0OiBtZWRpYW4oY2FsbHMubWFwKChj
YWxsOiBDYWxsU3RvcnkpID0+IGNhbGwubWF4RHJhd2Rvd25QY3QpLmZpbHRlcigodmFsdWU6IG51bWJlciB8IG51bGwpOiB2YWx1ZSBpcyBudW1iZXIgPT4g
dmFsdWUgIT09IG51bGwpKSwKICAgIHRvcENhbGxzLAogICAgcmVjZW50Q2FsbHM6IGNhbGxzLnNsaWNlKDAsIDMwKSwKICB9Owp9CgpleHBvcnQgYXN5bmMg
ZnVuY3Rpb24gYmluZENvbnRlbnRIcShjaGF0SWQ6IHN0cmluZyB8IG51bWJlcikgewogIGF3YWl0IGVuc3VyZUNhbGxTdG9yeVNjaGVtYSgpOwogIGNvbnN0
IHNxbCA9IHNxbENsaWVudCgpOwogIGF3YWl0IHNxbGAKICAgIFVQREFURSBtZW1lc2NvcGVfY29udGVudF9zZXR0aW5ncwogICAgU0VUIGNvbnRlbnRfaHFf
Y2hhdF9pZCA9ICR7U3RyaW5nKGNoYXRJZCl9LCB1cGRhdGVkX2F0ID0gTk9XKCkKICAgIFdIRVJFIGlkID0gMQogIGA7CiAgcmV0dXJuIFN0cmluZyhjaGF0
SWQpOwp9CgpleHBvcnQgYXN5bmMgZnVuY3Rpb24gZ2V0Q29udGVudEhxU3RhdHVzKCkgewogIGF3YWl0IGVuc3VyZUNhbGxTdG9yeVNjaGVtYSgpOwogIGNv
bnN0IHNxbCA9IHNxbENsaWVudCgpOwogIGNvbnN0IHJvd3MgPSBhd2FpdCBzcWxgCiAgICBTRUxFQ1QgY29udGVudF9ocV9jaGF0X2lkLCB1cGRhdGVkX2F0
CiAgICBGUk9NIG1lbWVzY29wZV9jb250ZW50X3NldHRpbmdzCiAgICBXSEVSRSBpZCA9IDEKICAgIExJTUlUIDEKICBgOwogIGNvbnN0IHJvdyA9IHJvd3Nb
MF0gYXMgRGJSb3cgfCB1bmRlZmluZWQ7CiAgcmV0dXJuIHsKICAgIGNvbmZpZ3VyZWQ6IEJvb2xlYW4ocm93Py5jb250ZW50X2hxX2NoYXRfaWQpLAogICAg
Y2hhdElkOiByb3c/LmNvbnRlbnRfaHFfY2hhdF9pZCA/IFN0cmluZyhyb3cuY29udGVudF9ocV9jaGF0X2lkKSA6IG51bGwsCiAgICB1cGRhdGVkQXQ6IHJv
dz8udXBkYXRlZF9hdCA/IG1pbGxpcyhyb3cudXBkYXRlZF9hdCkgOiBudWxsLAogIH07Cn0KCmV4cG9ydCBhc3luYyBmdW5jdGlvbiBzZXRDb250ZW50T3Bw
b3J0dW5pdHlTdGF0dXMoCiAgaWQ6IG51bWJlciwKICBzdGF0dXM6ICJ1c2VkIiB8ICJza2lwcGVkIiB8ICJwZW5kaW5nIiwKKSB7CiAgYXdhaXQgZW5zdXJl
Q2FsbFN0b3J5U2NoZW1hKCk7CiAgY29uc3Qgc3FsID0gc3FsQ2xpZW50KCk7CiAgYXdhaXQgc3FsYAogICAgVVBEQVRFIG1lbWVzY29wZV9jb250ZW50X29w
cG9ydHVuaXRpZXMKICAgIFNFVCBzdGF0dXMgPSAke3N0YXR1c30sIHVwZGF0ZWRfYXQgPSBOT1coKQogICAgV0hFUkUgaWQgPSAke2lkfQogIGA7Cn0KCmFz
eW5jIGZ1bmN0aW9uIG9yaWdpbmFsVGVsZWdyYW1NZXNzYWdlSWQoc2lnbmFsUmVjb3JkSWQ6IHN0cmluZykgewogIGNvbnN0IHNxbCA9IHNxbENsaWVudCgp
OwogIHRyeSB7CiAgICBjb25zdCByb3dzID0gYXdhaXQgc3FsYAogICAgICBTRUxFQ1QgbWVzc2FnZV9pZAogICAgICBGUk9NIG1lbWVzY29wZV90ZWxlZ3Jh
bV9wb3N0cwogICAgICBXSEVSRSBzaWduYWxfcmVjb3JkX2lkID0gJHtzaWduYWxSZWNvcmRJZH0KICAgICAgTElNSVQgMQogICAgYDsKICAgIHJldHVybiBy
b3dzWzBdID8gbnVtT3JOdWxsKChyb3dzWzBdIGFzIERiUm93KS5tZXNzYWdlX2lkKSA6IG51bGw7CiAgfSBjYXRjaCB7CiAgICByZXR1cm4gbnVsbDsKICB9
Cn0KCmZ1bmN0aW9uIGNoYW5uZWxNZXNzYWdlVXJsKG1lc3NhZ2VJZDogbnVtYmVyIHwgbnVsbCkgewogIGNvbnN0IHsgY2hhbm5lbFVybCB9ID0gdGVsZWdy
YW1Db25maWcoKTsKICBpZiAoIW1lc3NhZ2VJZCB8fCAhY2hhbm5lbFVybCkgcmV0dXJuIG51bGw7CiAgcmV0dXJuIGAke2NoYW5uZWxVcmwucmVwbGFjZSgv
XC8rJC8sICIiKX0vJHttZXNzYWdlSWR9YDsKfQoKZnVuY3Rpb24gbWlsZXN0b25lVGl0bGUobWlsZXN0b25lOiBudW1iZXIpIHsKICBpZiAobWlsZXN0b25l
ID09PSAyKSByZXR1cm4gIvCfmoAgTUVNRVNDT1BFIFJVTk5FUiI7CiAgaWYgKG1pbGVzdG9uZSA9PT0gNSkgcmV0dXJuICLwn5KOIE1FTUVTQ09QRSBNQUpP
UiBDQUxMIjsKICByZXR1cm4gIvCfkZEgTUVNRVNDT1BFIEVYQ0VQVElPTkFMIENBTEwiOwp9CgpmdW5jdGlvbiBtaWxlc3RvbmVBdChjYWxsOiBDYWxsU3Rv
cnksIG1pbGVzdG9uZTogbnVtYmVyKSB7CiAgaWYgKG1pbGVzdG9uZSA9PT0gMikgcmV0dXJuIGNhbGwubWlsZXN0b25lMnhBdDsKICBpZiAobWlsZXN0b25l
ID09PSA1KSByZXR1cm4gY2FsbC5taWxlc3RvbmU1eEF0OwogIHJldHVybiBjYWxsLm1pbGVzdG9uZTEweEF0Owp9CgpmdW5jdGlvbiBtaWxlc3RvbmVUZWxl
Z3JhbVRleHQoY2FsbDogQ2FsbFN0b3J5LCBtaWxlc3RvbmU6IG51bWJlcikgewogIGNvbnN0IHBlYWtNYyA9IGNhbGwucGVha01hcmtldENhcFVzZCA/PyBj
YWxsLmN1cnJlbnRNYXJrZXRDYXBVc2Q7CiAgY29uc3QgbGluZXMgPSBbCiAgICBgPGI+JHttaWxlc3RvbmVUaXRsZShtaWxlc3RvbmUpfTwvYj5gLAogICAg
IiIsCiAgICBgPGI+JCR7ZXNjYXBlVGVsZWdyYW1IdG1sKGNhbGwuc3ltYm9sKX08L2I+YCwKICAgIGA8Y29kZT4ke2VzY2FwZVRlbGVncmFtSHRtbChjYWxs
LnB1YmxpY0lkKX08L2NvZGU+YCwKICAgICIiLAogICAgYEZyb20gQ2FsbDogPGI+JHttdWx0aXBsZVRleHQoY2FsbC5wZWFrTXVsdGlwbGUpfTwvYj5gLAog
ICAgYENhbGwgTUM6IDxiPiR7Y29tcGFjdFVzZChjYWxsLmNhbGxNYXJrZXRDYXBVc2QpfTwvYj5gLAogICAgYCR7bWlsZXN0b25lID09PSAyID8gIkN1cnJl
bnQiIDogIlBlYWsifSBNQzogPGI+JHtjb21wYWN0VXNkKHBlYWtNYyl9PC9iPmAsCiAgICBgVGltZSB0byAke21pbGVzdG9uZX1YOiA8Yj4ke2R1cmF0aW9u
VGV4dChjYWxsLmNhbGxlZEF0LCBtaWxlc3RvbmVBdChjYWxsLCBtaWxlc3RvbmUpKX08L2I+YCwKICAgIGBNYXggRHJhd2Rvd246IDxiPiR7cGN0KGNhbGwu
bWF4RHJhd2Rvd25QY3QpfTwvYj5gLAogIF07CgogIGlmIChtaWxlc3RvbmUgPj0gMTApIHsKICAgIGxpbmVzLnB1c2goCiAgICAgICIiLAogICAgICBgMlg6
IDxiPiR7ZHVyYXRpb25UZXh0KGNhbGwuY2FsbGVkQXQsIGNhbGwubWlsZXN0b25lMnhBdCl9PC9iPmAsCiAgICAgIGA1WDogPGI+JHtkdXJhdGlvblRleHQo
Y2FsbC5jYWxsZWRBdCwgY2FsbC5taWxlc3RvbmU1eEF0KX08L2I+YCwKICAgICAgYDEwWDogPGI+JHtkdXJhdGlvblRleHQoY2FsbC5jYWxsZWRBdCwgY2Fs
bC5taWxlc3RvbmUxMHhBdCl9PC9iPmAsCiAgICApOwogIH0KCiAgbGluZXMucHVzaCgiIiwgIjxpPk9yaWdpbmFsIGNhbGwgcmVtYWlucyB1bmNoYW5nZWQu
PC9pPiIpOwogIHJldHVybiBsaW5lcy5qb2luKCJcbiIpOwp9CgpmdW5jdGlvbiBtaWxlc3RvbmVCdXR0b25zKGNhbGw6IENhbGxTdG9yeSwgb3JpZ2luYWxN
ZXNzYWdlSWRWYWx1ZTogbnVtYmVyIHwgbnVsbCkgewogIGNvbnN0IHNpdGUgPSB0ZWxlZ3JhbVNpdGVVcmwoKTsKICBjb25zdCBvcmlnaW5hbFVybCA9IGNo
YW5uZWxNZXNzYWdlVXJsKG9yaWdpbmFsTWVzc2FnZUlkVmFsdWUpOwogIGNvbnN0IGZpcnN0Um93OiBBcnJheTx7IHRleHQ6IHN0cmluZzsgdXJsOiBzdHJp
bmcgfT4gPSBbXTsKICBpZiAob3JpZ2luYWxVcmwpIGZpcnN0Um93LnB1c2goeyB0ZXh0OiAi8J+TjCBPcmlnaW5hbCBDYWxsIiwgdXJsOiBvcmlnaW5hbFVy
bCB9KTsKICBmaXJzdFJvdy5wdXNoKHsgdGV4dDogIvCfp60gQ2FsbCBKb3VybmV5IiwgdXJsOiBgJHtzaXRlfS9jYWxscy8ke2VuY29kZVVSSUNvbXBvbmVu
dChjYWxsLnB1YmxpY0lkKX1gIH0pOwoKICByZXR1cm4gewogICAgaW5saW5lX2tleWJvYXJkOiBbCiAgICAgIGZpcnN0Um93LAogICAgICBbCiAgICAgICAg
eyB0ZXh0OiAi8J+TiiBMaXZlIENoYXJ0IiwgdXJsOiBgaHR0cHM6Ly9kZXhzY3JlZW5lci5jb20vc29sYW5hLyR7ZW5jb2RlVVJJQ29tcG9uZW50KGNhbGwu
dG9rZW5BZGRyZXNzKX1gIH0sCiAgICAgICAgeyB0ZXh0OiAi8J+MkCBNZW1lU2NvcGUiLCB1cmw6IHNpdGUgfSwKICAgICAgXSwKICAgIF0sCiAgfTsKfQoK
YXN5bmMgZnVuY3Rpb24gcHVibGlzaFBlbmRpbmdQdWJsaWNNaWxlc3RvbmVzKCkgewogIGlmICghdGVsZWdyYW1Db25maWd1cmVkKCkpIHJldHVybiB7IHNl
bnQ6IDAgfTsKICBjb25zdCBzcWwgPSBzcWxDbGllbnQoKTsKICBjb25zdCB7IGNoYW5uZWxJZCB9ID0gdGVsZWdyYW1Db25maWcoKTsKICBjb25zdCByb3dz
ID0gYXdhaXQgc3FsYAogICAgU0VMRUNUICoKICAgIEZST00gbWVtZXNjb3BlX2NhbGxfc3RvcnkKICAgIFdIRVJFIGJhc2VsaW5lID0gRkFMU0UKICAgICAg
QU5EIHBlYWtfbXVsdGlwbGUgPj0gMgogICAgICBBTkQgKAogICAgICAgIChwZWFrX211bHRpcGxlID49IDEwIEFORCBsYXN0X3B1YmxpY19taWxlc3RvbmUg
PCAxMCkgT1IKICAgICAgICAocGVha19tdWx0aXBsZSA+PSA1IEFORCBsYXN0X3B1YmxpY19taWxlc3RvbmUgPCA1KSBPUgogICAgICAgIChwZWFrX211bHRp
cGxlID49IDIgQU5EIGxhc3RfcHVibGljX21pbGVzdG9uZSA8IDIpCiAgICAgICkKICAgIE9SREVSIEJZIGNhbGxlZF9hdCBBU0MKICAgIExJTUlUIDMwCiAg
YDsKCiAgbGV0IHNlbnQgPSAwOwogIGZvciAoY29uc3QgcmF3IG9mIHJvd3MpIHsKICAgIGNvbnN0IGNhbGwgPSBub3JtYWxpemVDYWxsKHJhdyBhcyBEYlJv
dyk7CiAgICBjb25zdCBtaWxlc3RvbmUgPSBoaWdoZXN0UHVibGljTWlsZXN0b25lKGNhbGwucGVha011bHRpcGxlKTsKICAgIGlmIChtaWxlc3RvbmUgPD0g
Y2FsbC5sYXN0UHVibGljTWlsZXN0b25lIHx8IG1pbGVzdG9uZSA9PT0gMCkgY29udGludWU7CgogICAgY29uc3Qgb3JpZ2luYWxNZXNzYWdlSWRWYWx1ZSA9
IGF3YWl0IG9yaWdpbmFsVGVsZWdyYW1NZXNzYWdlSWQoY2FsbC5zaWduYWxSZWNvcmRJZCk7CiAgICBpZiAob3JpZ2luYWxNZXNzYWdlSWRWYWx1ZSA9PT0g
bnVsbCkgewogICAgICAvLyBLZWVwIGNocm9ub2xvZ2ljYWwgb3JkZXI6IE5FVyBDQUxMIG11c3QgZXhpc3QgYmVmb3JlIGFueSBtaWxlc3RvbmUgcG9zdC4K
ICAgICAgY29udGludWU7CiAgICB9CgogICAgY29uc3QgbWVzc2FnZSA9IGF3YWl0IHRlbGVncmFtU2VuZE1lc3NhZ2UoCiAgICAgIGNoYW5uZWxJZCwKICAg
ICAgbWlsZXN0b25lVGVsZWdyYW1UZXh0KGNhbGwsIG1pbGVzdG9uZSksCiAgICAgIHsgcmVwbHlNYXJrdXA6IG1pbGVzdG9uZUJ1dHRvbnMoY2FsbCwgb3Jp
Z2luYWxNZXNzYWdlSWRWYWx1ZSkgfSwKICAgICk7CgogICAgaWYgKG1pbGVzdG9uZSA9PT0gMikgewogICAgICBhd2FpdCBzcWxgVVBEQVRFIG1lbWVzY29w
ZV9jYWxsX3N0b3J5IFNFVCBsYXN0X3B1YmxpY19taWxlc3RvbmUgPSAyLCB0ZWxlZ3JhbV8yeF9tZXNzYWdlX2lkID0gJHttZXNzYWdlLm1lc3NhZ2VfaWR9
LCB1cGRhdGVkX2F0ID0gTk9XKCkgV0hFUkUgc2lnbmFsX3JlY29yZF9pZCA9ICR7Y2FsbC5zaWduYWxSZWNvcmRJZH1gOwogICAgfSBlbHNlIGlmIChtaWxl
c3RvbmUgPT09IDUpIHsKICAgICAgYXdhaXQgc3FsYFVQREFURSBtZW1lc2NvcGVfY2FsbF9zdG9yeSBTRVQgbGFzdF9wdWJsaWNfbWlsZXN0b25lID0gNSwg
dGVsZWdyYW1fNXhfbWVzc2FnZV9pZCA9ICR7bWVzc2FnZS5tZXNzYWdlX2lkfSwgdXBkYXRlZF9hdCA9IE5PVygpIFdIRVJFIHNpZ25hbF9yZWNvcmRfaWQg
PSAke2NhbGwuc2lnbmFsUmVjb3JkSWR9YDsKICAgIH0gZWxzZSB7CiAgICAgIGF3YWl0IHNxbGBVUERBVEUgbWVtZXNjb3BlX2NhbGxfc3RvcnkgU0VUIGxh
c3RfcHVibGljX21pbGVzdG9uZSA9IDEwLCB0ZWxlZ3JhbV8xMHhfbWVzc2FnZV9pZCA9ICR7bWVzc2FnZS5tZXNzYWdlX2lkfSwgdXBkYXRlZF9hdCA9IE5P
VygpIFdIRVJFIHNpZ25hbF9yZWNvcmRfaWQgPSAke2NhbGwuc2lnbmFsUmVjb3JkSWR9YDsKICAgIH0KICAgIHNlbnQgKz0gMTsKICB9CiAgcmV0dXJuIHsg
c2VudCB9Owp9CgpmdW5jdGlvbiByZXN1bHREcmFmdChjYWxsOiBDYWxsU3RvcnkpIHsKICByZXR1cm4gWwogICAgYE1lbWVTY29wZSBmbGFnZ2VkICQke2Nh
bGwuc3ltYm9sfSBhdCAke2NvbXBhY3RVc2QoY2FsbC5jYWxsTWFya2V0Q2FwVXNkKX0gTUMuIEl0IGxhdGVyIHJlYWNoZWQgJHtjb21wYWN0VXNkKGNhbGwu
cGVha01hcmtldENhcFVzZCl9LmAsCiAgICAiIiwKICAgIGAke211bHRpcGxlVGV4dChjYWxsLnBlYWtNdWx0aXBsZSl9IGZyb20gdGhlIG9yaWdpbmFsIGNh
bGwuYCwKICAgIGBPcmlnaW5hbCBjYWxsOiAke2NhbGwucHVibGljSWR9LmAsCiAgXS5qb2luKCJcbiIpOwp9CgpmdW5jdGlvbiBiZWZvcmVNb3ZlRHJhZnQo
Y2FsbDogQ2FsbFN0b3J5KSB7CiAgcmV0dXJuIFsKICAgIGBXaGF0IE1lbWVTY29wZSBzYXcgYmVmb3JlICQke2NhbGwuc3ltYm9sfSBtb3ZlZCBmcm9tICR7
Y29tcGFjdFVzZChjYWxsLmNhbGxNYXJrZXRDYXBVc2QpfSB0byAke2NvbXBhY3RVc2QoY2FsbC5wZWFrTWFya2V0Q2FwVXNkKX06YCwKICAgICIiLAogICAg
YEJ1eSBwcmVzc3VyZTogJHtjYWxsLmJ1eVByZXNzdXJlUGN0ID09PSBudWxsID8gIk4vQSIgOiBgJHtjYWxsLmJ1eVByZXNzdXJlUGN0LnRvRml4ZWQoMCl9
JWB9YCwKICAgIGBWb2x1bWUgZXhwYW5zaW9uOiAke2NhbGwudm9sdW1lU3Bpa2UgPT09IG51bGwgPyAiTi9BIiA6IGAke2NhbGwudm9sdW1lU3Bpa2UudG9G
aXhlZCgxKX1YYH1gLAogICAgYExpcXVpZGl0eTogJHtjb21wYWN0VXNkKGNhbGwubGlxdWlkaXR5VXNkKX1gLAogICAgYFNpZ25hbCBzY29yZTogJHtNYXRo
LnJvdW5kKGNhbGwuc2lnbmFsU2NvcmUpfS8xMDBgLAogICAgIiIsCiAgICBgUGVhayBzaW5jZSBjYWxsOiAke211bHRpcGxlVGV4dChjYWxsLnBlYWtNdWx0
aXBsZSl9LmAsCiAgXS5qb2luKCJcbiIpOwp9Cgphc3luYyBmdW5jdGlvbiBjcmVhdGVPcHBvcnR1bml0eSgKICBjYWxsOiBDYWxsU3RvcnksCiAgdHlwZTog
c3RyaW5nLAogIHByaW9yaXR5OiBzdHJpbmcsCiAgbWlsZXN0b25lOiBudW1iZXIsCiAgZHJhZnQ6IHN0cmluZywKKSB7CiAgY29uc3Qgc3FsID0gc3FsQ2xp
ZW50KCk7CiAgYXdhaXQgc3FsYAogICAgSU5TRVJUIElOVE8gbWVtZXNjb3BlX2NvbnRlbnRfb3Bwb3J0dW5pdGllcyAoCiAgICAgIHNpZ25hbF9yZWNvcmRf
aWQsCiAgICAgIHB1YmxpY19pZCwKICAgICAgb3Bwb3J0dW5pdHlfdHlwZSwKICAgICAgcHJpb3JpdHksCiAgICAgIG1pbGVzdG9uZV9tdWx0aXBsZSwKICAg
ICAgZHJhZnRfdGV4dAogICAgKSBWQUxVRVMgKAogICAgICAke2NhbGwuc2lnbmFsUmVjb3JkSWR9LAogICAgICAke2NhbGwucHVibGljSWR9LAogICAgICAk
e3R5cGV9LAogICAgICAke3ByaW9yaXR5fSwKICAgICAgJHttaWxlc3RvbmV9LAogICAgICAke2RyYWZ0fQogICAgKQogICAgT04gQ09ORkxJQ1QgKHNpZ25h
bF9yZWNvcmRfaWQsIG9wcG9ydHVuaXR5X3R5cGUpCiAgICBETyBVUERBVEUgU0VUCiAgICAgIHByaW9yaXR5ID0gRVhDTFVERUQucHJpb3JpdHksCiAgICAg
IG1pbGVzdG9uZV9tdWx0aXBsZSA9IEdSRUFURVNUKENPQUxFU0NFKG1lbWVzY29wZV9jb250ZW50X29wcG9ydHVuaXRpZXMubWlsZXN0b25lX211bHRpcGxl
LCAwKSwgRVhDTFVERUQubWlsZXN0b25lX211bHRpcGxlKSwKICAgICAgZHJhZnRfdGV4dCA9IEVYQ0xVREVELmRyYWZ0X3RleHQsCiAgICAgIHVwZGF0ZWRf
YXQgPSBOT1coKQogIGA7Cn0KCmFzeW5jIGZ1bmN0aW9uIGRpc2NvdmVyQ29udGVudE9wcG9ydHVuaXRpZXMoKSB7CiAgY29uc3Qgc3FsID0gc3FsQ2xpZW50
KCk7CiAgY29uc3Qgcm93cyA9IGF3YWl0IHNxbGAKICAgIFNFTEVDVCAqCiAgICBGUk9NIG1lbWVzY29wZV9jYWxsX3N0b3J5CiAgICBXSEVSRSBiYXNlbGlu
ZSA9IEZBTFNFCiAgICAgIEFORCBwZWFrX211bHRpcGxlID49IDIKICAgIE9SREVSIEJZIGNhbGxlZF9hdCBERVNDCiAgICBMSU1JVCAzMDAKICBgOwoKICBm
b3IgKGNvbnN0IHJhdyBvZiByb3dzKSB7CiAgICBjb25zdCBjYWxsID0gbm9ybWFsaXplQ2FsbChyYXcgYXMgRGJSb3cpOwogICAgY29uc3QgdGltZTJ4TWlu
dXRlcyA9IGNhbGwubWlsZXN0b25lMnhBdCA9PT0gbnVsbCA/IG51bGwgOiAoY2FsbC5taWxlc3RvbmUyeEF0IC0gY2FsbC5jYWxsZWRBdCkgLyA2MF8wMDA7
CgogICAgY29uc3QgcGVhayA9IGNhbGwucGVha011bHRpcGxlID8/IDA7CgogICAgaWYgKHBlYWsgPj0gMTApIHsKICAgICAgYXdhaXQgY3JlYXRlT3Bwb3J0
dW5pdHkoY2FsbCwgImV4Y2VwdGlvbmFsXzEweCIsICJGRUFUVVJFRCIsIDEwLCByZXN1bHREcmFmdChjYWxsKSk7CiAgICB9IGVsc2UgaWYgKHBlYWsgPj0g
NSkgewogICAgICBhd2FpdCBjcmVhdGVPcHBvcnR1bml0eShjYWxsLCAibWFqb3JfNXgiLCAiSElHSCIsIDUsIHJlc3VsdERyYWZ0KGNhbGwpKTsKICAgIH0g
ZWxzZSBpZiAocGVhayA+PSAyICYmIHRpbWUyeE1pbnV0ZXMgIT09IG51bGwgJiYgdGltZTJ4TWludXRlcyA8PSA2MCkgewogICAgICBhd2FpdCBjcmVhdGVP
cHBvcnR1bml0eShjYWxsLCAiZmFzdF8yeCIsICJNRURJVU0iLCAyLCByZXN1bHREcmFmdChjYWxsKSk7CiAgICB9CgogICAgaWYgKHBlYWsgPj0gMTAwKSB7
CiAgICAgIGF3YWl0IGNyZWF0ZU9wcG9ydHVuaXR5KGNhbGwsICJzcGVjaWFsXzEwMHgiLCAiU1BFQ0lBTCIsIDEwMCwgcmVzdWx0RHJhZnQoY2FsbCkpOwog
ICAgfSBlbHNlIGlmIChwZWFrID49IDUwKSB7CiAgICAgIGF3YWl0IGNyZWF0ZU9wcG9ydHVuaXR5KGNhbGwsICJzcGVjaWFsXzUweCIsICJTUEVDSUFMIiwg
NTAsIHJlc3VsdERyYWZ0KGNhbGwpKTsKICAgIH0gZWxzZSBpZiAocGVhayA+PSAyMCkgewogICAgICBhd2FpdCBjcmVhdGVPcHBvcnR1bml0eShjYWxsLCAi
c3BlY2lhbF8yMHgiLCAiU1BFQ0lBTCIsIDIwLCByZXN1bHREcmFmdChjYWxsKSk7CiAgICB9CiAgfQp9Cgphc3luYyBmdW5jdGlvbiBwdWJsaXNoUGVuZGlu
Z0NvbnRlbnRPcHBvcnR1bml0aWVzKCkgewogIGNvbnN0IHN0YXR1cyA9IGF3YWl0IGdldENvbnRlbnRIcVN0YXR1cygpOwogIGlmICghc3RhdHVzLmNvbmZp
Z3VyZWQgfHwgIXN0YXR1cy5jaGF0SWQpIHJldHVybiB7IHNlbnQ6IDAgfTsKICBjb25zdCBzcWwgPSBzcWxDbGllbnQoKTsKICBjb25zdCBzaXRlID0gdGVs
ZWdyYW1TaXRlVXJsKCk7CiAgY29uc3Qgcm93cyA9IGF3YWl0IHNxbGAKICAgIFNFTEVDVCAqCiAgICBGUk9NIG1lbWVzY29wZV9jb250ZW50X29wcG9ydHVu
aXRpZXMKICAgIFdIRVJFIHN0YXR1cyA9ICdwZW5kaW5nJwogICAgICBBTkQgc2VudF9hdCBJUyBOVUxMCiAgICBPUkRFUiBCWQogICAgICBDQVNFIHByaW9y
aXR5CiAgICAgICAgV0hFTiAnU1BFQ0lBTCcgVEhFTiAxCiAgICAgICAgV0hFTiAnRkVBVFVSRUQnIFRIRU4gMgogICAgICAgIFdIRU4gJ0hJR0gnIFRIRU4g
MwogICAgICAgIEVMU0UgNAogICAgICBFTkQsCiAgICAgIGNyZWF0ZWRfYXQgQVNDCiAgICBMSU1JVCAxMgogIGA7CgogIGxldCBzZW50ID0gMDsKICBmb3Ig
KGNvbnN0IHJhdyBvZiByb3dzKSB7CiAgICBjb25zdCByb3cgPSByYXcgYXMgRGJSb3c7CiAgICBjb25zdCBpZCA9IG51bShyb3cuaWQpOwogICAgY29uc3Qg
cHVibGljSWQgPSBTdHJpbmcocm93LnB1YmxpY19pZCA/PyAiIik7CiAgICBjb25zdCBjYWxsID0gcHVibGljSWQgPyBhd2FpdCBnZXRDYWxsQnlQdWJsaWNJ
ZChwdWJsaWNJZCkgOiBudWxsOwogICAgaWYgKCFjYWxsKSBjb250aW51ZTsKCiAgICBjb25zdCBkcmFmdCA9IFN0cmluZyhyb3cuZHJhZnRfdGV4dCA/PyAi
Iik7CiAgICBjb25zdCB0ZXh0ID0gWwogICAgICAi8J+OrCA8Yj5NRU1FU0NPUEUgQ09OVEVOVCBPUFBPUlRVTklUWTwvYj4iLAogICAgICAiIiwKICAgICAg
YDxiPiQke2VzY2FwZVRlbGVncmFtSHRtbChjYWxsLnN5bWJvbCl9PC9iPiDigJQgJHtlc2NhcGVUZWxlZ3JhbUh0bWwoU3RyaW5nKHJvdy5wcmlvcml0eSA/
PyAiTUVESVVNIikpfSBQUklPUklUWWAsCiAgICAgIGA8Y29kZT4ke2VzY2FwZVRlbGVncmFtSHRtbChjYWxsLnB1YmxpY0lkKX08L2NvZGU+YCwKICAgICAg
IiIsCiAgICAgIGBDYWxsIE1DOiA8Yj4ke2NvbXBhY3RVc2QoY2FsbC5jYWxsTWFya2V0Q2FwVXNkKX08L2I+YCwKICAgICAgYFBlYWsgTUM6IDxiPiR7Y29t
cGFjdFVzZChjYWxsLnBlYWtNYXJrZXRDYXBVc2QpfTwvYj5gLAogICAgICBgUGVhazogPGI+JHttdWx0aXBsZVRleHQoY2FsbC5wZWFrTXVsdGlwbGUpfTwv
Yj5gLAogICAgICBgU2lnbmFsIFNjb3JlOiA8Yj4ke01hdGgucm91bmQoY2FsbC5zaWduYWxTY29yZSl9LzEwMDwvYj5gLAogICAgICAiIiwKICAgICAgIjxi
PlN1Z2dlc3RlZCBYIGhvb2s8L2I+IiwKICAgICAgZXNjYXBlVGVsZWdyYW1IdG1sKGRyYWZ0KSwKICAgICAgIiIsCiAgICAgICI8Yj5CZWZvcmUgVGhlIE1v
dmUgYW5nbGU8L2I+IiwKICAgICAgZXNjYXBlVGVsZWdyYW1IdG1sKGJlZm9yZU1vdmVEcmFmdChjYWxsKSksCiAgICAgICIiLAogICAgICAiPGk+Tm8gWCBw
b3N0IGlzIHNlbnQgYXV0b21hdGljYWxseS4gVGhpcyBpcyBhbiBhZG1pbiBjb250ZW50IGluYm94LjwvaT4iLAogICAgXS5qb2luKCJcbiIpOwoKICAgIGNv
bnN0IG1lc3NhZ2UgPSBhd2FpdCB0ZWxlZ3JhbVNlbmRNZXNzYWdlKHN0YXR1cy5jaGF0SWQsIHRleHQsIHsKICAgICAgcmVwbHlNYXJrdXA6IHsKICAgICAg
ICBpbmxpbmVfa2V5Ym9hcmQ6IFsKICAgICAgICAgIFsKICAgICAgICAgICAgeyB0ZXh0OiAi8J+nrSBPcGVuIENhbGwiLCB1cmw6IGAke3NpdGV9L2NhbGxz
LyR7ZW5jb2RlVVJJQ29tcG9uZW50KGNhbGwucHVibGljSWQpfWAgfSwKICAgICAgICAgICAgeyB0ZXh0OiAi8J+WvCBKb3VybmV5IENhcmQiLCB1cmw6IGAk
e3NpdGV9L2FwaS9jYWxscy8ke2VuY29kZVVSSUNvbXBvbmVudChjYWxsLnB1YmxpY0lkKX0vY2FyZD9tb2RlPWpvdXJuZXlgIH0sCiAgICAgICAgICBdLAog
ICAgICAgICAgWwogICAgICAgICAgICB7IHRleHQ6ICLwn5SOIEJlZm9yZSBUaGUgTW92ZSIsIHVybDogYCR7c2l0ZX0vYXBpL2NhbGxzLyR7ZW5jb2RlVVJJ
Q29tcG9uZW50KGNhbGwucHVibGljSWQpfS9jYXJkP21vZGU9YmVmb3JlYCB9LAogICAgICAgICAgXSwKICAgICAgICAgIFsKICAgICAgICAgICAgeyB0ZXh0
OiAi4pyFIE1hcmsgVXNlZCIsIGNhbGxiYWNrX2RhdGE6IGBjb250ZW50OnVzZWQ6JHtpZH1gIH0sCiAgICAgICAgICAgIHsgdGV4dDogIvCfl5EgU2tpcCIs
IGNhbGxiYWNrX2RhdGE6IGBjb250ZW50OnNraXA6JHtpZH1gIH0sCiAgICAgICAgICBdLAogICAgICAgIF0sCiAgICAgIH0sCiAgICB9KTsKCiAgICBhd2Fp
dCBzcWxgCiAgICAgIFVQREFURSBtZW1lc2NvcGVfY29udGVudF9vcHBvcnR1bml0aWVzCiAgICAgIFNFVCB0ZWxlZ3JhbV9tZXNzYWdlX2lkID0gJHttZXNz
YWdlLm1lc3NhZ2VfaWR9LCBzZW50X2F0ID0gTk9XKCksIHVwZGF0ZWRfYXQgPSBOT1coKQogICAgICBXSEVSRSBpZCA9ICR7aWR9CiAgICBgOwogICAgc2Vu
dCArPSAxOwogIH0KCiAgcmV0dXJuIHsgc2VudCB9Owp9CgpmdW5jdGlvbiBsb2NhbENsb2NrKCkgewogIGNvbnN0IHRpbWVab25lID0gcHJvY2Vzcy5lbnYu
TUVNRVNDT1BFX1JFUE9SVF9USU1FWk9ORT8udHJpbSgpIHx8ICJBc2lhL0pha2FydGEiOwogIGNvbnN0IHBhcnRzID0gbmV3IEludGwuRGF0ZVRpbWVGb3Jt
YXQoImVuLUNBIiwgewogICAgdGltZVpvbmUsCiAgICB5ZWFyOiAibnVtZXJpYyIsCiAgICBtb250aDogIjItZGlnaXQiLAogICAgZGF5OiAiMi1kaWdpdCIs
CiAgICB3ZWVrZGF5OiAic2hvcnQiLAogICAgaG91cjogIjItZGlnaXQiLAogICAgaG91ckN5Y2xlOiAiaDIzIiwKICB9KS5mb3JtYXRUb1BhcnRzKG5ldyBE
YXRlKCkpOwogIGNvbnN0IHZhbHVlcyA9IG5ldyBNYXAocGFydHMubWFwKChwYXJ0KSA9PiBbcGFydC50eXBlLCBwYXJ0LnZhbHVlXSkpOwogIHJldHVybiB7
CiAgICB0aW1lWm9uZSwKICAgIGRhdGU6IGAke3ZhbHVlcy5nZXQoInllYXIiKX0tJHt2YWx1ZXMuZ2V0KCJtb250aCIpfS0ke3ZhbHVlcy5nZXQoImRheSIp
fWAsCiAgICB3ZWVrZGF5OiB2YWx1ZXMuZ2V0KCJ3ZWVrZGF5IikgPz8gIiIsCiAgICBob3VyOiBOdW1iZXIodmFsdWVzLmdldCgiaG91ciIpID8/ICIwIiks
CiAgfTsKfQoKYXN5bmMgZnVuY3Rpb24gcmVwb3J0U3RhdHMoZGF5czogbnVtYmVyKSB7CiAgY29uc3QgZGFzaGJvYXJkID0gYXdhaXQgZ2V0Q2FsbERhc2hi
b2FyZChkYXlzKTsKICBjb25zdCB0b3AgPSBkYXNoYm9hcmQudG9wQ2FsbHNbMF0gPz8gbnVsbDsKICBjb25zdCBmYXN0ZXN0MnggPSBkYXNoYm9hcmQucmVj
ZW50Q2FsbHMKICAgIC5maWx0ZXIoKGNhbGwpID0+IGNhbGwubWlsZXN0b25lMnhBdCAhPT0gbnVsbCkKICAgIC5zb3J0KChhLCBiKSA9PgogICAgICAoKGEu
bWlsZXN0b25lMnhBdCA/PyBOdW1iZXIuTUFYX1NBRkVfSU5URUdFUikgLSBhLmNhbGxlZEF0KSAtCiAgICAgICgoYi5taWxlc3RvbmUyeEF0ID8/IE51bWJl
ci5NQVhfU0FGRV9JTlRFR0VSKSAtIGIuY2FsbGVkQXQpLAogICAgKVswXSA/PyBudWxsOwoKICByZXR1cm4geyBkYXNoYm9hcmQsIHRvcCwgZmFzdGVzdDJ4
IH07Cn0KCmFzeW5jIGZ1bmN0aW9uIHNlbmRSZXBvcnQodHlwZTogImRhaWx5IiB8ICJ3ZWVrbHkiLCByZXBvcnREYXRlOiBzdHJpbmcpIHsKICBpZiAoIXRl
bGVncmFtQ29uZmlndXJlZCgpKSByZXR1cm4gZmFsc2U7CiAgY29uc3Qgc3FsID0gc3FsQ2xpZW50KCk7CiAgY29uc3Qga2V5ID0gYCR7dHlwZX06JHtyZXBv
cnREYXRlfWA7CiAgY29uc3QgZXhpc3RpbmcgPSBhd2FpdCBzcWxgU0VMRUNUIHJlcG9ydF9rZXkgRlJPTSBtZW1lc2NvcGVfcHVibGljX3JlcG9ydHMgV0hF
UkUgcmVwb3J0X2tleSA9ICR7a2V5fSBMSU1JVCAxYDsKICBpZiAoZXhpc3RpbmdbMF0pIHJldHVybiBmYWxzZTsKCiAgY29uc3QgeyBkYXNoYm9hcmQsIHRv
cCwgZmFzdGVzdDJ4IH0gPSBhd2FpdCByZXBvcnRTdGF0cyh0eXBlID09PSAiZGFpbHkiID8gMSA6IDcpOwogIGlmIChkYXNoYm9hcmQudG90YWxDYWxscyA9
PT0gMCkgcmV0dXJuIGZhbHNlOwoKICBjb25zdCB0aXRsZSA9IHR5cGUgPT09ICJkYWlseSIgPyAi8J+TiiBNRU1FU0NPUEUgREFJTFkgVEFQRSIgOiAi8J+T
iCBNRU1FU0NPUEUgV0VFS0xZIElOVEVMTElHRU5DRSI7CiAgY29uc3QgbGluZXMgPSBbCiAgICBgPGI+JHt0aXRsZX08L2I+YCwKICAgIHJlcG9ydERhdGUs
CiAgICAiIiwKICAgIGBDYWxsczogPGI+JHtkYXNoYm9hcmQudG90YWxDYWxsc308L2I+YCwKICAgIGBSZWFjaGVkIDJYOiA8Yj4ke2Rhc2hib2FyZC5yZWFj
aGVkMnh9PC9iPmAsCiAgICBgUmVhY2hlZCA1WDogPGI+JHtkYXNoYm9hcmQucmVhY2hlZDV4fTwvYj5gLAogICAgYFJlYWNoZWQgMTBYOiA8Yj4ke2Rhc2hi
b2FyZC5yZWFjaGVkMTB4fTwvYj5gLAogICAgIiIsCiAgICB0b3AgPyBgVG9wIFJlY29yZGVkIENhbGw6IDxiPiQke2VzY2FwZVRlbGVncmFtSHRtbCh0b3Au
c3ltYm9sKX0g4oCUICR7bXVsdGlwbGVUZXh0KHRvcC5wZWFrTXVsdGlwbGUpfTwvYj5gIDogbnVsbCwKICAgIGZhc3Rlc3QyeCA/IGBGYXN0ZXN0IDJYOiA8
Yj4kJHtlc2NhcGVUZWxlZ3JhbUh0bWwoZmFzdGVzdDJ4LnN5bWJvbCl9IOKAlCAke2R1cmF0aW9uVGV4dChmYXN0ZXN0MnguY2FsbGVkQXQsIGZhc3Rlc3Qy
eC5taWxlc3RvbmUyeEF0KX08L2I+YCA6IG51bGwsCiAgICBkYXNoYm9hcmQubWVkaWFuUGVha011bHRpcGxlICE9PSBudWxsID8gYE1lZGlhbiBQZWFrOiA8
Yj4ke211bHRpcGxlVGV4dChkYXNoYm9hcmQubWVkaWFuUGVha011bHRpcGxlKX08L2I+YCA6IG51bGwsCiAgICBkYXNoYm9hcmQubWVkaWFuTWF4RHJhd2Rv
d25QY3QgIT09IG51bGwgPyBgTWVkaWFuIE1heCBEcmF3ZG93bjogPGI+JHtwY3QoZGFzaGJvYXJkLm1lZGlhbk1heERyYXdkb3duUGN0KX08L2I+YCA6IG51
bGwsCiAgICAiIiwKICAgICI8aT5IaXN0b3JpY2FsIG9ic2VydmF0aW9ucyBvbmx5OyBub3QgZnV0dXJlIHByb2JhYmlsaXRpZXMuPC9pPiIsCiAgXS5maWx0
ZXIoKHZhbHVlKTogdmFsdWUgaXMgc3RyaW5nID0+IHZhbHVlICE9PSBudWxsKTsKCiAgY29uc3QgeyBjaGFubmVsSWQgfSA9IHRlbGVncmFtQ29uZmlnKCk7
CiAgY29uc3QgcHVibGljTWVzc2FnZSA9IGF3YWl0IHRlbGVncmFtU2VuZE1lc3NhZ2UoY2hhbm5lbElkLCBsaW5lcy5qb2luKCJcbiIpLCB7CiAgICByZXBs
eU1hcmt1cDogewogICAgICBpbmxpbmVfa2V5Ym9hcmQ6IFtbeyB0ZXh0OiAi8J+PhiBIYWxsIG9mIENhbGxzIiwgdXJsOiBgJHt0ZWxlZ3JhbVNpdGVVcmwo
KX0vY2FsbHNgIH1dXSwKICAgIH0sCiAgfSk7CgogIGNvbnN0IGhxID0gYXdhaXQgZ2V0Q29udGVudEhxU3RhdHVzKCk7CiAgbGV0IGhxTWVzc2FnZUlkOiBu
dW1iZXIgfCBudWxsID0gbnVsbDsKICBpZiAoaHEuY29uZmlndXJlZCAmJiBocS5jaGF0SWQpIHsKICAgIGNvbnN0IGhxVGV4dCA9IFsKICAgICAgYPCfk50g
PGI+JHt0eXBlID09PSAiZGFpbHkiID8gIkRBSUxZIFRBUEUiIDogIldFRUtMWSBJTlRFTExJR0VOQ0UifSBDT05URU5UIFJFQURZPC9iPmAsCiAgICAgICIi
LAogICAgICAuLi5saW5lcy5zbGljZSgxLCAtMiksCiAgICAgICIiLAogICAgICB0b3AKICAgICAgICA/IGA8Yj5TdWdnZXN0ZWQgaG9vazwvYj5cbk1lbWVT
Y29wZSBmbGFnZ2VkICQke2VzY2FwZVRlbGVncmFtSHRtbCh0b3Auc3ltYm9sKX0gYXQgJHtjb21wYWN0VXNkKHRvcC5jYWxsTWFya2V0Q2FwVXNkKX0gTUMu
IEl0IGxhdGVyIHJlYWNoZWQgJHtjb21wYWN0VXNkKHRvcC5wZWFrTWFya2V0Q2FwVXNkKX0uYAogICAgICAgIDogIiIsCiAgICAgICIiLAogICAgICAiPGk+
UmV2aWV3IGJlZm9yZSBwdWJsaXNoaW5nIG91dHNpZGUgVGVsZWdyYW0uPC9pPiIsCiAgICBdLmZpbHRlcihCb29sZWFuKS5qb2luKCJcbiIpOwogICAgY29u
c3QgaHFNZXNzYWdlID0gYXdhaXQgdGVsZWdyYW1TZW5kTWVzc2FnZShocS5jaGF0SWQsIGhxVGV4dCwgewogICAgICByZXBseU1hcmt1cDogeyBpbmxpbmVf
a2V5Ym9hcmQ6IFtbeyB0ZXh0OiAi8J+PhiBPcGVuIEhhbGwgb2YgQ2FsbHMiLCB1cmw6IGAke3RlbGVncmFtU2l0ZVVybCgpfS9jYWxsc2AgfV1dIH0sCiAg
ICB9KTsKICAgIGhxTWVzc2FnZUlkID0gaHFNZXNzYWdlLm1lc3NhZ2VfaWQ7CiAgfQoKICBhd2FpdCBzcWxgCiAgICBJTlNFUlQgSU5UTyBtZW1lc2NvcGVf
cHVibGljX3JlcG9ydHMgKAogICAgICByZXBvcnRfa2V5LCByZXBvcnRfdHlwZSwgcmVwb3J0X2RhdGUsIHB1YmxpY19tZXNzYWdlX2lkLCBjb250ZW50X2hx
X21lc3NhZ2VfaWQKICAgICkgVkFMVUVTICgKICAgICAgJHtrZXl9LCAke3R5cGV9LCAke3JlcG9ydERhdGV9LCAke3B1YmxpY01lc3NhZ2UubWVzc2FnZV9p
ZH0sICR7aHFNZXNzYWdlSWR9CiAgICApCiAgICBPTiBDT05GTElDVCAocmVwb3J0X2tleSkgRE8gTk9USElORwogIGA7CiAgcmV0dXJuIHRydWU7Cn0KCmFz
eW5jIGZ1bmN0aW9uIHB1Ymxpc2hTY2hlZHVsZWRSZXBvcnRzKCkgewogIGNvbnN0IGNsb2NrID0gbG9jYWxDbG9jaygpOwogIGlmIChjbG9jay5ob3VyIDwg
MjMpIHJldHVybiB7IGRhaWx5OiBmYWxzZSwgd2Vla2x5OiBmYWxzZSB9OwogIGNvbnN0IGRhaWx5ID0gYXdhaXQgc2VuZFJlcG9ydCgiZGFpbHkiLCBjbG9j
ay5kYXRlKTsKICBjb25zdCB3ZWVrbHkgPSBjbG9jay53ZWVrZGF5ID09PSAiU3VuIiA/IGF3YWl0IHNlbmRSZXBvcnQoIndlZWtseSIsIGNsb2NrLmRhdGUp
IDogZmFsc2U7CiAgcmV0dXJuIHsgZGFpbHksIHdlZWtseSB9Owp9CgpleHBvcnQgYXN5bmMgZnVuY3Rpb24gcnVuQ2FsbFN0b3J5Q3ljbGUodG9rZW5zOiBU
ZXJtaW5hbFRva2VuW10sIHNpZ25hbHM6IFNpZ25hbENhbGxbXSkgewogIGF3YWl0IGVuc3VyZUNhbGxTdG9yeVNjaGVtYSgpOwogIGNvbnN0IHN5bmMgPSBh
d2FpdCBzeW5jQ2FsbFJvd3ModG9rZW5zLCBzaWduYWxzKTsKICBjb25zdCBtaWxlc3RvbmVzID0gYXdhaXQgcHVibGlzaFBlbmRpbmdQdWJsaWNNaWxlc3Rv
bmVzKCk7CiAgYXdhaXQgZGlzY292ZXJDb250ZW50T3Bwb3J0dW5pdGllcygpOwogIGNvbnN0IGNvbnRlbnQgPSBhd2FpdCBwdWJsaXNoUGVuZGluZ0NvbnRl
bnRPcHBvcnR1bml0aWVzKCk7CiAgY29uc3QgcmVwb3J0cyA9IGF3YWl0IHB1Ymxpc2hTY2hlZHVsZWRSZXBvcnRzKCk7CiAgcmV0dXJuIHsgc3luYywgbWls
ZXN0b25lcywgY29udGVudCwgcmVwb3J0cyB9Owp9Cg==
"@

$payloads["src/app/calls/page.tsx"] = @"
aW1wb3J0IExpbmsgZnJvbSAibmV4dC9saW5rIjsKCmltcG9ydCB7CiAgY29tcGFjdFVzZCwKICBnZXRDYWxsRGFzaGJvYXJkLAogIG11bHRpcGxlVGV4dCwK
fSBmcm9tICJAL2xpYi9jYWxsLXN0b3J5IjsKCmZ1bmN0aW9uIHBjdCh2YWx1ZTogbnVtYmVyIHwgbnVsbCkgewogIGlmICh2YWx1ZSA9PT0gbnVsbCB8fCAh
TnVtYmVyLmlzRmluaXRlKHZhbHVlKSkgcmV0dXJuICJOL0EiOwogIHJldHVybiBgJHt2YWx1ZSA+IDAgPyAiKyIgOiAiIn0ke3ZhbHVlLnRvRml4ZWQoMSl9
JWA7Cn0KCmV4cG9ydCBjb25zdCBkeW5hbWljID0gImZvcmNlLWR5bmFtaWMiOwoKZXhwb3J0IGRlZmF1bHQgYXN5bmMgZnVuY3Rpb24gQ2FsbHNQYWdlKCkg
ewogIGNvbnN0IGRhc2hib2FyZCA9IGF3YWl0IGdldENhbGxEYXNoYm9hcmQoMzApOwoKICByZXR1cm4gKAogICAgPG1haW4gY2xhc3NOYW1lPSJteC1hdXRv
IHctZnVsbCBtYXgtdy03eGwgcHgtNCBweS02IGxnOnB4LTggbGc6cHktOCI+CiAgICAgIDxkaXYgY2xhc3NOYW1lPSJtYi04Ij4KICAgICAgICA8ZGl2IGNs
YXNzTmFtZT0idGV4dC14cyB1cHBlcmNhc2UgdHJhY2tpbmctWzAuMjJlbV0gdGV4dC1lbWVyYWxkLTMwMC83MCI+CiAgICAgICAgICBNZW1lU2NvcGUgTGl2
ZSBDYWxsIEludGVsbGlnZW5jZQogICAgICAgIDwvZGl2PgogICAgICAgIDxoMSBjbGFzc05hbWU9Im10LTIgdGV4dC0zeGwgZm9udC1zZW1pYm9sZCB0cmFj
a2luZy10aWdodCB0ZXh0LXdoaXRlIj4KICAgICAgICAgIENhbGxzICYgUHVibGljIFBlcmZvcm1hbmNlCiAgICAgICAgPC9oMT4KICAgICAgICA8cCBjbGFz
c05hbWU9Im10LTIgbWF4LXctM3hsIHRleHQtc20gbGVhZGluZy02IHRleHQtemluYy01MDAiPgogICAgICAgICAgQ2FsbHMgYXJlIHRyYWNrZWQgZnJvbSB0
aGVpciBvcmlnaW5hbCBlbnRyeS4gUHVibGljIHNpZ25hbCBwb3N0cyByZW1haW4gdW5jaGFuZ2VkIHdoaWxlIE1lbWVTY29wZSByZWNvcmRzIHRoZSBqb3Vy
bmV5LCBwZWFrIHBlcmZvcm1hbmNlIGFuZCBkcmF3ZG93bi4KICAgICAgICA8L3A+CiAgICAgIDwvZGl2PgoKICAgICAgPHNlY3Rpb24gY2xhc3NOYW1lPSJn
cmlkIGdhcC0zIHNtOmdyaWQtY29scy0yIHhsOmdyaWQtY29scy02Ij4KICAgICAgICB7WwogICAgICAgICAgWyIzMEQgQ2FsbHMiLCBkYXNoYm9hcmQudG90
YWxDYWxsc10sCiAgICAgICAgICBbIlJlYWNoZWQgMlgiLCBkYXNoYm9hcmQucmVhY2hlZDJ4XSwKICAgICAgICAgIFsiUmVhY2hlZCA1WCIsIGRhc2hib2Fy
ZC5yZWFjaGVkNXhdLAogICAgICAgICAgWyJSZWFjaGVkIDEwWCIsIGRhc2hib2FyZC5yZWFjaGVkMTB4XSwKICAgICAgICAgIFsiTWVkaWFuIFBlYWsiLCBt
dWx0aXBsZVRleHQoZGFzaGJvYXJkLm1lZGlhblBlYWtNdWx0aXBsZSldLAogICAgICAgICAgWyJNZWRpYW4gRHJhd2Rvd24iLCBwY3QoZGFzaGJvYXJkLm1l
ZGlhbk1heERyYXdkb3duUGN0KV0sCiAgICAgICAgXS5tYXAoKFtsYWJlbCwgdmFsdWVdKSA9PiAoCiAgICAgICAgICA8ZGl2IGtleT17U3RyaW5nKGxhYmVs
KX0gY2xhc3NOYW1lPSJyb3VuZGVkLTJ4bCBib3JkZXIgYm9yZGVyLXdoaXRlLzggYmctd2hpdGUvWzAuMDI1XSBwLTQiPgogICAgICAgICAgICA8ZGl2IGNs
YXNzTmFtZT0idGV4dC1bMTBweF0gdXBwZXJjYXNlIHRyYWNraW5nLVswLjE2ZW1dIHRleHQtemluYy02MDAiPntsYWJlbH08L2Rpdj4KICAgICAgICAgICAg
PGRpdiBjbGFzc05hbWU9Im10LTIgdGV4dC14bCBmb250LXNlbWlib2xkIHRleHQtd2hpdGUiPnt2YWx1ZX08L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAg
ICAgICkpfQogICAgICA8L3NlY3Rpb24+CgogICAgICA8c2VjdGlvbiBjbGFzc05hbWU9Im10LTgiPgogICAgICAgIDxkaXYgY2xhc3NOYW1lPSJtYi0zIGZs
ZXggaXRlbXMtZW5kIGp1c3RpZnktYmV0d2VlbiBnYXAtNCI+CiAgICAgICAgICA8ZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzTmFtZT0idGV4dC14cyB1
cHBlcmNhc2UgdHJhY2tpbmctWzAuMTZlbV0gdGV4dC16aW5jLTYwMCI+SGFsbCBvZiBDYWxsczwvZGl2PgogICAgICAgICAgICA8aDIgY2xhc3NOYW1lPSJt
dC0xIHRleHQteGwgZm9udC1zZW1pYm9sZCB0ZXh0LXdoaXRlIj5Ub3AgcmVjb3JkZWQgY2FsbHM8L2gyPgogICAgICAgICAgPC9kaXY+CiAgICAgICAgICA8
ZGl2IGNsYXNzTmFtZT0idGV4dC14cyB0ZXh0LXppbmMtNjAwIj5SYW5rZWQgYnkgb2JzZXJ2ZWQgcGVhayBzaW5jZSBjYWxsPC9kaXY+CiAgICAgICAgPC9k
aXY+CgogICAgICAgIDxkaXYgY2xhc3NOYW1lPSJncmlkIGdhcC0zIGxnOmdyaWQtY29scy0yIj4KICAgICAgICAgIHtkYXNoYm9hcmQudG9wQ2FsbHMuc2xp
Y2UoMCwgMTApLm1hcCgoY2FsbCwgaW5kZXgpID0+ICgKICAgICAgICAgICAgPExpbmsKICAgICAgICAgICAgICBrZXk9e2NhbGwuc2lnbmFsUmVjb3JkSWR9
CiAgICAgICAgICAgICAgaHJlZj17YC9jYWxscy8ke2VuY29kZVVSSUNvbXBvbmVudChjYWxsLnB1YmxpY0lkKX1gfQogICAgICAgICAgICAgIGNsYXNzTmFt
ZT0iZ3JvdXAgcm91bmRlZC0yeGwgYm9yZGVyIGJvcmRlci13aGl0ZS84IGJnLXdoaXRlL1swLjAyNV0gcC01IHRyYW5zaXRpb24gaG92ZXI6Ym9yZGVyLWVt
ZXJhbGQtNDAwLzIwIGhvdmVyOmJnLXdoaXRlL1swLjA0XSIKICAgICAgICAgICAgPgogICAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJmbGV4IGl0ZW1z
LXN0YXJ0IGp1c3RpZnktYmV0d2VlbiBnYXAtNCI+CiAgICAgICAgICAgICAgICA8ZGl2PgogICAgICAgICAgICAgICAgICA8ZGl2IGNsYXNzTmFtZT0idGV4
dC1bMTBweF0gdGV4dC16aW5jLTYwMCI+I3tpbmRleCArIDF9IMK3IHtjYWxsLnB1YmxpY0lkfTwvZGl2PgogICAgICAgICAgICAgICAgICA8ZGl2IGNsYXNz
TmFtZT0ibXQtMSB0ZXh0LWxnIGZvbnQtc2VtaWJvbGQgdGV4dC13aGl0ZSI+JHtjYWxsLnN5bWJvbH08L2Rpdj4KICAgICAgICAgICAgICAgICAgPGRpdiBj
bGFzc05hbWU9Im10LTEgdGV4dC14cyB0ZXh0LXppbmMtNjAwIj57Y29tcGFjdFVzZChjYWxsLmNhbGxNYXJrZXRDYXBVc2QpfSDihpIge2NvbXBhY3RVc2Qo
Y2FsbC5wZWFrTWFya2V0Q2FwVXNkKX08L2Rpdj4KICAgICAgICAgICAgICAgIDwvZGl2PgogICAgICAgICAgICAgICAgPGRpdiBjbGFzc05hbWU9InRleHQt
cmlnaHQiPgogICAgICAgICAgICAgICAgICA8ZGl2IGNsYXNzTmFtZT0idGV4dC0yeGwgZm9udC1zZW1pYm9sZCB0ZXh0LWVtZXJhbGQtMzAwIj57bXVsdGlw
bGVUZXh0KGNhbGwucGVha011bHRpcGxlKX08L2Rpdj4KICAgICAgICAgICAgICAgICAgPGRpdiBjbGFzc05hbWU9InRleHQtWzEwcHhdIHVwcGVyY2FzZSB0
cmFja2luZy1bMC4xMmVtXSB0ZXh0LXppbmMtNjAwIj5wZWFrPC9kaXY+CiAgICAgICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgICA8L2Rpdj4KICAg
ICAgICAgICAgICA8ZGl2IGNsYXNzTmFtZT0ibXQtNCBncmlkIGdyaWQtY29scy0zIGdhcC0yIHRleHQteHMiPgogICAgICAgICAgICAgICAgPGRpdiBjbGFz
c05hbWU9InJvdW5kZWQteGwgYmctYmxhY2svMjAgcC0yLjUiPjxkaXYgY2xhc3NOYW1lPSJ0ZXh0LXppbmMtNjAwIj5TY29yZTwvZGl2PjxkaXYgY2xhc3NO
YW1lPSJtdC0xIHRleHQtemluYy0zMDAiPntNYXRoLnJvdW5kKGNhbGwuc2lnbmFsU2NvcmUpfS8xMDA8L2Rpdj48L2Rpdj4KICAgICAgICAgICAgICAgIDxk
aXYgY2xhc3NOYW1lPSJyb3VuZGVkLXhsIGJnLWJsYWNrLzIwIHAtMi41Ij48ZGl2IGNsYXNzTmFtZT0idGV4dC16aW5jLTYwMCI+Q3VycmVudDwvZGl2Pjxk
aXYgY2xhc3NOYW1lPSJtdC0xIHRleHQtemluYy0zMDAiPnttdWx0aXBsZVRleHQoY2FsbC5jdXJyZW50TXVsdGlwbGUpfTwvZGl2PjwvZGl2PgogICAgICAg
ICAgICAgICAgPGRpdiBjbGFzc05hbWU9InJvdW5kZWQteGwgYmctYmxhY2svMjAgcC0yLjUiPjxkaXYgY2xhc3NOYW1lPSJ0ZXh0LXppbmMtNjAwIj5EcmF3
ZG93bjwvZGl2PjxkaXYgY2xhc3NOYW1lPSJtdC0xIHRleHQtemluYy0zMDAiPntwY3QoY2FsbC5tYXhEcmF3ZG93blBjdCl9PC9kaXY+PC9kaXY+CiAgICAg
ICAgICAgICAgPC9kaXY+CiAgICAgICAgICAgIDwvTGluaz4KICAgICAgICAgICkpfQogICAgICAgIDwvZGl2PgogICAgICA8L3NlY3Rpb24+CgogICAgICA8
c2VjdGlvbiBjbGFzc05hbWU9Im10LTgiPgogICAgICAgIDxkaXYgY2xhc3NOYW1lPSJtYi0zIj4KICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJ0ZXh0LXhz
IHVwcGVyY2FzZSB0cmFja2luZy1bMC4xNmVtXSB0ZXh0LXppbmMtNjAwIj5SZWNlbnQgQ2FsbHM8L2Rpdj4KICAgICAgICAgIDxoMiBjbGFzc05hbWU9Im10
LTEgdGV4dC14bCBmb250LXNlbWlib2xkIHRleHQtd2hpdGUiPlB1YmxpYyBjYWxsIGhpc3Rvcnk8L2gyPgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYg
Y2xhc3NOYW1lPSJvdmVyZmxvdy1oaWRkZW4gcm91bmRlZC0yeGwgYm9yZGVyIGJvcmRlci13aGl0ZS84IGJnLXdoaXRlL1swLjAyXSI+CiAgICAgICAgICA8
ZGl2IGNsYXNzTmFtZT0iZGl2aWRlLXkgZGl2aWRlLXdoaXRlLzUiPgogICAgICAgICAgICB7ZGFzaGJvYXJkLnJlY2VudENhbGxzLm1hcCgoY2FsbCkgPT4g
KAogICAgICAgICAgICAgIDxMaW5rIGtleT17Y2FsbC5zaWduYWxSZWNvcmRJZH0gaHJlZj17YC9jYWxscy8ke2VuY29kZVVSSUNvbXBvbmVudChjYWxsLnB1
YmxpY0lkKX1gfSBjbGFzc05hbWU9ImdyaWQgZ3JpZC1jb2xzLVsxZnJfYXV0b10gZ2FwLTQgcC00IHRyYW5zaXRpb24gaG92ZXI6Ymctd2hpdGUvWzAuMDNd
IHNtOmdyaWQtY29scy1bMS4yZnJfMWZyXzFmcl9hdXRvXSI+CiAgICAgICAgICAgICAgICA8ZGl2PjxkaXYgY2xhc3NOYW1lPSJmb250LW1lZGl1bSB0ZXh0
LXdoaXRlIj4ke2NhbGwuc3ltYm9sfTwvZGl2PjxkaXYgY2xhc3NOYW1lPSJ0ZXh0LVsxMHB4XSB0ZXh0LXppbmMtNjAwIj57Y2FsbC5wdWJsaWNJZH08L2Rp
dj48L2Rpdj4KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJoaWRkZW4gc206YmxvY2siPjxkaXYgY2xhc3NOYW1lPSJ0ZXh0LVsxMHB4XSB0ZXh0
LXppbmMtNjAwIj5DYWxsIE1DPC9kaXY+PGRpdiBjbGFzc05hbWU9Im10LTEgdGV4dC14cyB0ZXh0LXppbmMtMzAwIj57Y29tcGFjdFVzZChjYWxsLmNhbGxN
YXJrZXRDYXBVc2QpfTwvZGl2PjwvZGl2PgogICAgICAgICAgICAgICAgPGRpdiBjbGFzc05hbWU9ImhpZGRlbiBzbTpibG9jayI+PGRpdiBjbGFzc05hbWU9
InRleHQtWzEwcHhdIHRleHQtemluYy02MDAiPlBlYWsgTUM8L2Rpdj48ZGl2IGNsYXNzTmFtZT0ibXQtMSB0ZXh0LXhzIHRleHQtemluYy0zMDAiPntjb21w
YWN0VXNkKGNhbGwucGVha01hcmtldENhcFVzZCl9PC9kaXY+PC9kaXY+CiAgICAgICAgICAgICAgICA8ZGl2IGNsYXNzTmFtZT0idGV4dC1yaWdodCI+PGRp
diBjbGFzc05hbWU9ImZvbnQtc2VtaWJvbGQgdGV4dC1lbWVyYWxkLTMwMCI+e211bHRpcGxlVGV4dChjYWxsLnBlYWtNdWx0aXBsZSl9PC9kaXY+PGRpdiBj
bGFzc05hbWU9InRleHQtWzEwcHhdIHRleHQtemluYy02MDAiPnBlYWs8L2Rpdj48L2Rpdj4KICAgICAgICAgICAgICA8L0xpbms+CiAgICAgICAgICAgICkp
fQogICAgICAgICAgPC9kaXY+CiAgICAgICAgPC9kaXY+CiAgICAgIDwvc2VjdGlvbj4KCiAgICAgIDxkaXYgY2xhc3NOYW1lPSJtdC02IHRleHQtWzEwcHhd
IGxlYWRpbmctNSB0ZXh0LXppbmMtNzAwIj4KICAgICAgICBQZXJmb3JtYW5jZSBzaG93biBoZXJlIGlzIGhpc3RvcmljYWwgYW5kIGRlc2NyaXB0aXZlLiBQ
ZWFrIHZhbHVlcyBhcmUgb2JzZXJ2ZWQgYWZ0ZXIgdGhlIG9yaWdpbmFsIGNhbGwgYW5kIGFyZSBub3QgZ3VhcmFudGVlcyBvZiBmdXR1cmUgcmVzdWx0cy4K
ICAgICAgPC9kaXY+CiAgICA8L21haW4+CiAgKTsKfQo=
"@

$payloads["src/app/calls/[id]/page.tsx"] = @"
aW1wb3J0IExpbmsgZnJvbSAibmV4dC9saW5rIjsKaW1wb3J0IHsgbm90Rm91bmQgfSBmcm9tICJuZXh0L25hdmlnYXRpb24iOwoKaW1wb3J0IHsKICBjb21w
YWN0VXNkLAogIGdldENhbGxCeVB1YmxpY0lkLAogIG11bHRpcGxlVGV4dCwKfSBmcm9tICJAL2xpYi9jYWxsLXN0b3J5IjsKCmV4cG9ydCBjb25zdCBkeW5h
bWljID0gImZvcmNlLWR5bmFtaWMiOwoKZnVuY3Rpb24gcGN0KHZhbHVlOiBudW1iZXIgfCBudWxsKSB7CiAgaWYgKHZhbHVlID09PSBudWxsIHx8ICFOdW1i
ZXIuaXNGaW5pdGUodmFsdWUpKSByZXR1cm4gIk4vQSI7CiAgcmV0dXJuIGAke3ZhbHVlID4gMCA/ICIrIiA6ICIifSR7dmFsdWUudG9GaXhlZCgxKX0lYDsK
fQoKZnVuY3Rpb24gZHVyYXRpb24oZnJvbTogbnVtYmVyLCB0bzogbnVtYmVyIHwgbnVsbCkgewogIGlmICh0byA9PT0gbnVsbCkgcmV0dXJuICLigJQiOwog
IGNvbnN0IG1pbnV0ZXMgPSBNYXRoLm1heCgwLCAodG8gLSBmcm9tKSAvIDYwXzAwMCk7CiAgaWYgKG1pbnV0ZXMgPCA2MCkgcmV0dXJuIGAke01hdGgucm91
bmQobWludXRlcyl9bWA7CiAgY29uc3QgaG91cnMgPSBtaW51dGVzIC8gNjA7CiAgaWYgKGhvdXJzIDwgMjQpIHJldHVybiBgJHtob3Vycy50b0ZpeGVkKDEp
fWhgOwogIHJldHVybiBgJHsoaG91cnMgLyAyNCkudG9GaXhlZCgxKX1kYDsKfQoKZXhwb3J0IGRlZmF1bHQgYXN5bmMgZnVuY3Rpb24gQ2FsbERldGFpbFBh
Z2UoewogIHBhcmFtcywKfTogewogIHBhcmFtczogUHJvbWlzZTx7IGlkOiBzdHJpbmcgfT47Cn0pIHsKICBjb25zdCB7IGlkIH0gPSBhd2FpdCBwYXJhbXM7
CiAgY29uc3QgY2FsbCA9IGF3YWl0IGdldENhbGxCeVB1YmxpY0lkKGRlY29kZVVSSUNvbXBvbmVudChpZCkpOwogIGlmICghY2FsbCkgbm90Rm91bmQoKTsK
CiAgY29uc3Qgam91cm5leSA9IFsKICAgIHsgbGFiZWw6ICJDQUxMIiwgYXQ6IGNhbGwuY2FsbGVkQXQsIHZhbHVlOiBjb21wYWN0VXNkKGNhbGwuY2FsbE1h
cmtldENhcFVzZCkgfSwKICAgIHsgbGFiZWw6ICIyWCBSVU5ORVIiLCBhdDogY2FsbC5taWxlc3RvbmUyeEF0LCB2YWx1ZTogY2FsbC5taWxlc3RvbmUyeEF0
ID8gIjJYIiA6IG51bGwgfSwKICAgIHsgbGFiZWw6ICI1WCBNQUpPUiBDQUxMIiwgYXQ6IGNhbGwubWlsZXN0b25lNXhBdCwgdmFsdWU6IGNhbGwubWlsZXN0
b25lNXhBdCA/ICI1WCIgOiBudWxsIH0sCiAgICB7IGxhYmVsOiAiMTBYIEVYQ0VQVElPTkFMIiwgYXQ6IGNhbGwubWlsZXN0b25lMTB4QXQsIHZhbHVlOiBj
YWxsLm1pbGVzdG9uZTEweEF0ID8gIjEwWCIgOiBudWxsIH0sCiAgXS5maWx0ZXIoKGl0ZW0pID0+IGl0ZW0uYXQgIT09IG51bGwpOwoKICByZXR1cm4gKAog
ICAgPG1haW4gY2xhc3NOYW1lPSJteC1hdXRvIHctZnVsbCBtYXgtdy02eGwgcHgtNCBweS02IGxnOnB4LTggbGc6cHktOCI+CiAgICAgIDxMaW5rIGhyZWY9
Ii9jYWxscyIgY2xhc3NOYW1lPSJ0ZXh0LXhzIHRleHQtemluYy01MDAgaG92ZXI6dGV4dC13aGl0ZSI+4oaQIEhhbGwgb2YgQ2FsbHM8L0xpbms+CgogICAg
ICA8ZGl2IGNsYXNzTmFtZT0ibXQtNSBmbGV4IGZsZXgtY29sIGp1c3RpZnktYmV0d2VlbiBnYXAtNiBsZzpmbGV4LXJvdyBsZzppdGVtcy1lbmQiPgogICAg
ICAgIDxkaXY+CiAgICAgICAgICA8ZGl2IGNsYXNzTmFtZT0idGV4dC14cyB1cHBlcmNhc2UgdHJhY2tpbmctWzAuMjJlbV0gdGV4dC1lbWVyYWxkLTMwMC83
MCI+TWVtZVNjb3BlIENhbGwgSm91cm5leTwvZGl2PgogICAgICAgICAgPGgxIGNsYXNzTmFtZT0ibXQtMiB0ZXh0LTR4bCBmb250LXNlbWlib2xkIHRyYWNr
aW5nLXRpZ2h0IHRleHQtd2hpdGUiPiR7Y2FsbC5zeW1ib2x9PC9oMT4KICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJtdC0yIGZvbnQtbW9ubyB0ZXh0LXhz
IHRleHQtemluYy02MDAiPntjYWxsLnB1YmxpY0lkfTwvZGl2PgogICAgICAgIDwvZGl2PgogICAgICAgIDxkaXYgY2xhc3NOYW1lPSJ0ZXh0LWxlZnQgbGc6
dGV4dC1yaWdodCI+CiAgICAgICAgICA8ZGl2IGNsYXNzTmFtZT0idGV4dC1bMTBweF0gdXBwZXJjYXNlIHRyYWNraW5nLVswLjE2ZW1dIHRleHQtemluYy02
MDAiPlBlYWsgU2luY2UgQ2FsbDwvZGl2PgogICAgICAgICAgPGRpdiBjbGFzc05hbWU9Im10LTEgdGV4dC00eGwgZm9udC1zZW1pYm9sZCB0ZXh0LWVtZXJh
bGQtMzAwIj57bXVsdGlwbGVUZXh0KGNhbGwucGVha011bHRpcGxlKX08L2Rpdj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9kaXY+CgogICAgICA8c2VjdGlv
biBjbGFzc05hbWU9Im10LTcgZ3JpZCBnYXAtMyBzbTpncmlkLWNvbHMtMiBsZzpncmlkLWNvbHMtNCI+CiAgICAgICAge1sKICAgICAgICAgIFsiQ2FsbCBN
QyIsIGNvbXBhY3RVc2QoY2FsbC5jYWxsTWFya2V0Q2FwVXNkKV0sCiAgICAgICAgICBbIlBlYWsgTUMiLCBjb21wYWN0VXNkKGNhbGwucGVha01hcmtldENh
cFVzZCldLAogICAgICAgICAgWyJDdXJyZW50IiwgbXVsdGlwbGVUZXh0KGNhbGwuY3VycmVudE11bHRpcGxlKV0sCiAgICAgICAgICBbIk1heCBEcmF3ZG93
biIsIHBjdChjYWxsLm1heERyYXdkb3duUGN0KV0sCiAgICAgICAgICBbIlNpZ25hbCBTY29yZSIsIGAke01hdGgucm91bmQoY2FsbC5zaWduYWxTY29yZSl9
LzEwMGBdLAogICAgICAgICAgWyJCdXkgUHJlc3N1cmUiLCBjYWxsLmJ1eVByZXNzdXJlUGN0ID09PSBudWxsID8gIk4vQSIgOiBgJHtjYWxsLmJ1eVByZXNz
dXJlUGN0LnRvRml4ZWQoMCl9JWBdLAogICAgICAgICAgWyJWb2x1bWUgRXhwYW5zaW9uIiwgY2FsbC52b2x1bWVTcGlrZSA9PT0gbnVsbCA/ICJOL0EiIDog
YCR7Y2FsbC52b2x1bWVTcGlrZS50b0ZpeGVkKDEpfVhgXSwKICAgICAgICAgIFsiTGlxdWlkaXR5IiwgY29tcGFjdFVzZChjYWxsLmxpcXVpZGl0eVVzZCld
LAogICAgICAgIF0ubWFwKChbbGFiZWwsIHZhbHVlXSkgPT4gKAogICAgICAgICAgPGRpdiBrZXk9e1N0cmluZyhsYWJlbCl9IGNsYXNzTmFtZT0icm91bmRl
ZC0yeGwgYm9yZGVyIGJvcmRlci13aGl0ZS84IGJnLXdoaXRlL1swLjAyNV0gcC00Ij4KICAgICAgICAgICAgPGRpdiBjbGFzc05hbWU9InRleHQtWzEwcHhd
IHVwcGVyY2FzZSB0cmFja2luZy1bMC4xNGVtXSB0ZXh0LXppbmMtNjAwIj57bGFiZWx9PC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJtdC0y
IHRleHQtbGcgZm9udC1zZW1pYm9sZCB0ZXh0LXdoaXRlIj57dmFsdWV9PC9kaXY+CiAgICAgICAgICA8L2Rpdj4KICAgICAgICApKX0KICAgICAgPC9zZWN0
aW9uPgoKICAgICAgPHNlY3Rpb24gY2xhc3NOYW1lPSJtdC04IGdyaWQgZ2FwLTUgbGc6Z3JpZC1jb2xzLVsxLjFmcl8wLjlmcl0iPgogICAgICAgIDxkaXYg
Y2xhc3NOYW1lPSJyb3VuZGVkLTJ4bCBib3JkZXIgYm9yZGVyLXdoaXRlLzggYmctd2hpdGUvWzAuMDI1XSBwLTUiPgogICAgICAgICAgPGRpdiBjbGFzc05h
bWU9InRleHQteHMgdXBwZXJjYXNlIHRyYWNraW5nLVswLjE2ZW1dIHRleHQtemluYy02MDAiPkNhbGwgSm91cm5leTwvZGl2PgogICAgICAgICAgPGRpdiBj
bGFzc05hbWU9Im10LTUgc3BhY2UteS0xIj4KICAgICAgICAgICAge2pvdXJuZXkubWFwKChpdGVtLCBpbmRleCkgPT4gKAogICAgICAgICAgICAgIDxkaXYg
a2V5PXtpdGVtLmxhYmVsfSBjbGFzc05hbWU9ImdyaWQgZ3JpZC1jb2xzLVsyMHB4XzFmcl9hdXRvXSBnYXAtMyI+CiAgICAgICAgICAgICAgICA8ZGl2IGNs
YXNzTmFtZT0iZmxleCBmbGV4LWNvbCBpdGVtcy1jZW50ZXIiPgogICAgICAgICAgICAgICAgICA8c3BhbiBjbGFzc05hbWU9Im10LTEgaC0yLjUgdy0yLjUg
cm91bmRlZC1mdWxsIGJnLWVtZXJhbGQtMzAwIiAvPgogICAgICAgICAgICAgICAgICB7aW5kZXggPCBqb3VybmV5Lmxlbmd0aCAtIDEgJiYgPHNwYW4gY2xh
c3NOYW1lPSJtaW4taC0xMiB3LXB4IGZsZXgtMSBiZy13aGl0ZS8xMCIgLz59CiAgICAgICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgICAgIDxkaXYg
Y2xhc3NOYW1lPSJwYi01Ij4KICAgICAgICAgICAgICAgICAgPGRpdiBjbGFzc05hbWU9InRleHQtc20gZm9udC1tZWRpdW0gdGV4dC13aGl0ZSI+e2l0ZW0u
bGFiZWx9PC9kaXY+CiAgICAgICAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJtdC0xIHRleHQteHMgdGV4dC16aW5jLTYwMCI+CiAgICAgICAgICAgICAg
ICAgICAge25ldyBEYXRlKGl0ZW0uYXQgYXMgbnVtYmVyKS50b0xvY2FsZVN0cmluZygiZW4tVVMiLCB7IHRpbWVab25lOiAiVVRDIiwgbW9udGg6ICJzaG9y
dCIsIGRheTogIjItZGlnaXQiLCBob3VyOiAiMi1kaWdpdCIsIG1pbnV0ZTogIjItZGlnaXQiLCBob3VyMTI6IGZhbHNlIH0pfSBVVEMKICAgICAgICAgICAg
ICAgICAgPC9kaXY+CiAgICAgICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJ0ZXh0LXJpZ2h0IHRleHQtc20gZm9u
dC1zZW1pYm9sZCB0ZXh0LXppbmMtMzAwIj57aXRlbS52YWx1ZX08L2Rpdj4KICAgICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgICAgKSl9CiAgICAgICAg
ICA8L2Rpdj4KICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJtdC0yIGdyaWQgZ3JpZC1jb2xzLTMgZ2FwLTIgdGV4dC14cyI+CiAgICAgICAgICAgIDxkaXYg
Y2xhc3NOYW1lPSJyb3VuZGVkLXhsIGJnLWJsYWNrLzIwIHAtMyI+PGRpdiBjbGFzc05hbWU9InRleHQtemluYy02MDAiPlRpbWUgdG8gMlg8L2Rpdj48ZGl2
IGNsYXNzTmFtZT0ibXQtMSB0ZXh0LXppbmMtMzAwIj57ZHVyYXRpb24oY2FsbC5jYWxsZWRBdCwgY2FsbC5taWxlc3RvbmUyeEF0KX08L2Rpdj48L2Rpdj4K
ICAgICAgICAgICAgPGRpdiBjbGFzc05hbWU9InJvdW5kZWQteGwgYmctYmxhY2svMjAgcC0zIj48ZGl2IGNsYXNzTmFtZT0idGV4dC16aW5jLTYwMCI+VGlt
ZSB0byA1WDwvZGl2PjxkaXYgY2xhc3NOYW1lPSJtdC0xIHRleHQtemluYy0zMDAiPntkdXJhdGlvbihjYWxsLmNhbGxlZEF0LCBjYWxsLm1pbGVzdG9uZTV4
QXQpfTwvZGl2PjwvZGl2PgogICAgICAgICAgICA8ZGl2IGNsYXNzTmFtZT0icm91bmRlZC14bCBiZy1ibGFjay8yMCBwLTMiPjxkaXYgY2xhc3NOYW1lPSJ0
ZXh0LXppbmMtNjAwIj5UaW1lIHRvIDEwWDwvZGl2PjxkaXYgY2xhc3NOYW1lPSJtdC0xIHRleHQtemluYy0zMDAiPntkdXJhdGlvbihjYWxsLmNhbGxlZEF0
LCBjYWxsLm1pbGVzdG9uZTEweEF0KX08L2Rpdj48L2Rpdj4KICAgICAgICAgIDwvZGl2PgogICAgICAgIDwvZGl2PgoKICAgICAgICA8ZGl2IGNsYXNzTmFt
ZT0ic3BhY2UteS01Ij4KICAgICAgICAgIDxzZWN0aW9uIGNsYXNzTmFtZT0icm91bmRlZC0yeGwgYm9yZGVyIGJvcmRlci13aGl0ZS84IGJnLXdoaXRlL1sw
LjAyNV0gcC01Ij4KICAgICAgICAgICAgPGRpdiBjbGFzc05hbWU9InRleHQteHMgdXBwZXJjYXNlIHRyYWNraW5nLVswLjE2ZW1dIHRleHQtemluYy02MDAi
PldoeSBpdCB0cmlnZ2VyZWQ8L2Rpdj4KICAgICAgICAgICAgPGRpdiBjbGFzc05hbWU9Im10LTQgc3BhY2UteS0yIHRleHQtc20gbGVhZGluZy02IHRleHQt
emluYy00MDAiPgogICAgICAgICAgICAgIHtjYWxsLnJlYXNvbnMubGVuZ3RoID4gMCA/IGNhbGwucmVhc29ucy5tYXAoKHJlYXNvbikgPT4gPGRpdiBrZXk9
e3JlYXNvbn0+4oCiIHtyZWFzb259PC9kaXY+KSA6IDxkaXY+Tm8gc3RvcmVkIHJhdGlvbmFsZSBmb3IgdGhpcyBoaXN0b3JpY2FsIGNhbGwuPC9kaXY+fQog
ICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDwvc2VjdGlvbj4KCiAgICAgICAgICA8c2VjdGlvbiBjbGFzc05hbWU9InJvdW5kZWQtMnhsIGJvcmRlciBi
b3JkZXItd2hpdGUvOCBiZy13aGl0ZS9bMC4wMjVdIHAtNSI+CiAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJ0ZXh0LXhzIHVwcGVyY2FzZSB0cmFja2lu
Zy1bMC4xNmVtXSB0ZXh0LXppbmMtNjAwIj5Db250ZW50IENhcmRzPC9kaXY+CiAgICAgICAgICAgIDxkaXYgY2xhc3NOYW1lPSJtdC00IGdyaWQgZ2FwLTIi
PgogICAgICAgICAgICAgIDxhIGhyZWY9e2AvYXBpL2NhbGxzLyR7ZW5jb2RlVVJJQ29tcG9uZW50KGNhbGwucHVibGljSWQpfS9jYXJkP21vZGU9am91cm5l
eWB9IHRhcmdldD0iX2JsYW5rIiByZWw9Im5vcmVmZXJyZXIiIGNsYXNzTmFtZT0icm91bmRlZC14bCBib3JkZXIgYm9yZGVyLXdoaXRlLzggcHgtMyBweS0y
LjUgdGV4dC1zbSB0ZXh0LXppbmMtMzAwIGhvdmVyOmJvcmRlci1lbWVyYWxkLTQwMC8yMCBob3Zlcjp0ZXh0LXdoaXRlIj5PcGVuIEpvdXJuZXkgQ2FyZDwv
YT4KICAgICAgICAgICAgICA8YSBocmVmPXtgL2FwaS9jYWxscy8ke2VuY29kZVVSSUNvbXBvbmVudChjYWxsLnB1YmxpY0lkKX0vY2FyZD9tb2RlPWJlZm9y
ZWB9IHRhcmdldD0iX2JsYW5rIiByZWw9Im5vcmVmZXJyZXIiIGNsYXNzTmFtZT0icm91bmRlZC14bCBib3JkZXIgYm9yZGVyLXdoaXRlLzggcHgtMyBweS0y
LjUgdGV4dC1zbSB0ZXh0LXppbmMtMzAwIGhvdmVyOmJvcmRlci1lbWVyYWxkLTQwMC8yMCBob3Zlcjp0ZXh0LXdoaXRlIj5PcGVuIEJlZm9yZSBUaGUgTW92
ZSBDYXJkPC9hPgogICAgICAgICAgICAgIDxhIGhyZWY9e2BodHRwczovL2RleHNjcmVlbmVyLmNvbS9zb2xhbmEvJHtlbmNvZGVVUklDb21wb25lbnQoY2Fs
bC50b2tlbkFkZHJlc3MpfWB9IHRhcmdldD0iX2JsYW5rIiByZWw9Im5vcmVmZXJyZXIiIGNsYXNzTmFtZT0icm91bmRlZC14bCBib3JkZXIgYm9yZGVyLXdo
aXRlLzggcHgtMyBweS0yLjUgdGV4dC1zbSB0ZXh0LXppbmMtMzAwIGhvdmVyOmJvcmRlci1lbWVyYWxkLTQwMC8yMCBob3Zlcjp0ZXh0LXdoaXRlIj5MaXZl
IENoYXJ0PC9hPgogICAgICAgICAgICA8L2Rpdj4KICAgICAgICAgIDwvc2VjdGlvbj4KICAgICAgICA8L2Rpdj4KICAgICAgPC9zZWN0aW9uPgoKICAgICAg
PGRpdiBjbGFzc05hbWU9Im10LTYgdGV4dC1bMTBweF0gbGVhZGluZy01IHRleHQtemluYy03MDAiPgogICAgICAgIE9yaWdpbmFsIGNhbGwgZGF0YSBpcyBy
ZXRhaW5lZCBmb3IgcHVibGljIGhpc3RvcnkuIFBlYWsgYW5kIGRyYXdkb3duIHZhbHVlcyBhcmUgaGlzdG9yaWNhbCBvYnNlcnZhdGlvbnMsIG5vdCBmb3Jl
Y2FzdHMgb3IgZ3VhcmFudGVlZCByZXR1cm5zLgogICAgICA8L2Rpdj4KICAgIDwvbWFpbj4KICApOwp9Cg==
"@

$payloads["src/app/api/calls/[id]/card/route.ts"] = @"
aW1wb3J0IHsKICBjb21wYWN0VXNkLAogIGdldENhbGxCeVB1YmxpY0lkLAogIG11bHRpcGxlVGV4dCwKfSBmcm9tICJAL2xpYi9jYWxsLXN0b3J5IjsKCmV4
cG9ydCBjb25zdCBkeW5hbWljID0gImZvcmNlLWR5bmFtaWMiOwoKZnVuY3Rpb24geG1sKHZhbHVlOiB1bmtub3duKSB7CiAgcmV0dXJuIFN0cmluZyh2YWx1
ZSA/PyAiIikKICAgIC5yZXBsYWNlQWxsKCImIiwgIiZhbXA7IikKICAgIC5yZXBsYWNlQWxsKCI8IiwgIiZsdDsiKQogICAgLnJlcGxhY2VBbGwoIj4iLCAi
Jmd0OyIpCiAgICAucmVwbGFjZUFsbCgnIicsICImcXVvdDsiKTsKfQoKZnVuY3Rpb24gcGN0KHZhbHVlOiBudW1iZXIgfCBudWxsKSB7CiAgaWYgKHZhbHVl
ID09PSBudWxsIHx8ICFOdW1iZXIuaXNGaW5pdGUodmFsdWUpKSByZXR1cm4gIk4vQSI7CiAgcmV0dXJuIGAke3ZhbHVlID4gMCA/ICIrIiA6ICIifSR7dmFs
dWUudG9GaXhlZCgxKX0lYDsKfQoKZnVuY3Rpb24gZHVyYXRpb24oZnJvbTogbnVtYmVyLCB0bzogbnVtYmVyIHwgbnVsbCkgewogIGlmICh0byA9PT0gbnVs
bCkgcmV0dXJuICLigJQiOwogIGNvbnN0IG1pbnV0ZXMgPSBNYXRoLm1heCgwLCAodG8gLSBmcm9tKSAvIDYwXzAwMCk7CiAgaWYgKG1pbnV0ZXMgPCA2MCkg
cmV0dXJuIGAke01hdGgucm91bmQobWludXRlcyl9bWA7CiAgY29uc3QgaG91cnMgPSBtaW51dGVzIC8gNjA7CiAgaWYgKGhvdXJzIDwgMjQpIHJldHVybiBg
JHtob3Vycy50b0ZpeGVkKDEpfWhgOwogIHJldHVybiBgJHsoaG91cnMgLyAyNCkudG9GaXhlZCgxKX1kYDsKfQoKZXhwb3J0IGFzeW5jIGZ1bmN0aW9uIEdF
VCgKICByZXF1ZXN0OiBSZXF1ZXN0LAogIGNvbnRleHQ6IHsgcGFyYW1zOiBQcm9taXNlPHsgaWQ6IHN0cmluZyB9PiB9LAopIHsKICBjb25zdCB7IGlkIH0g
PSBhd2FpdCBjb250ZXh0LnBhcmFtczsKICBjb25zdCBjYWxsID0gYXdhaXQgZ2V0Q2FsbEJ5UHVibGljSWQoZGVjb2RlVVJJQ29tcG9uZW50KGlkKSk7CiAg
aWYgKCFjYWxsKSByZXR1cm4gbmV3IFJlc3BvbnNlKCJDYWxsIG5vdCBmb3VuZCIsIHsgc3RhdHVzOiA0MDQgfSk7CgogIGNvbnN0IG1vZGUgPSBuZXcgVVJM
KHJlcXVlc3QudXJsKS5zZWFyY2hQYXJhbXMuZ2V0KCJtb2RlIikgPT09ICJiZWZvcmUiID8gImJlZm9yZSIgOiAiam91cm5leSI7CiAgY29uc3QgYWNjZW50
ID0gbW9kZSA9PT0gImJlZm9yZSIgPyAiIzYwYTVmYSIgOiAiIzZlZTdiNyI7CiAgY29uc3QgdGl0bGUgPSBtb2RlID09PSAiYmVmb3JlIiA/ICJCRUZPUkUg
VEhFIE1PVkUiIDogIkNBTEwgSk9VUk5FWSI7CgogIGNvbnN0IGJvZHkgPSBtb2RlID09PSAiYmVmb3JlIgogICAgPyBgCiAgICAgIDx0ZXh0IHg9IjcyIiB5
PSIyNzAiIGZpbGw9IiM3MTcxN2EiIGZvbnQtc2l6ZT0iMjAiPkNBTExFRCBBVDwvdGV4dD4KICAgICAgPHRleHQgeD0iNzIiIHk9IjMxNSIgZmlsbD0iI2Zm
ZmZmZiIgZm9udC1zaXplPSI0NiIgZm9udC13ZWlnaHQ9IjcwMCI+JHt4bWwoY29tcGFjdFVzZChjYWxsLmNhbGxNYXJrZXRDYXBVc2QpKX0gTUM8L3RleHQ+
CiAgICAgIDx0ZXh0IHg9IjcyIiB5PSIzOTAiIGZpbGw9IiM3MTcxN2EiIGZvbnQtc2l6ZT0iMTgiPkJVWSBQUkVTU1VSRTwvdGV4dD4KICAgICAgPHRleHQg
eD0iNzIiIHk9IjQyNSIgZmlsbD0iI2ZmZmZmZiIgZm9udC1zaXplPSIzMCIgZm9udC13ZWlnaHQ9IjYwMCI+JHt4bWwoY2FsbC5idXlQcmVzc3VyZVBjdCA9
PT0gbnVsbCA/ICJOL0EiIDogYCR7Y2FsbC5idXlQcmVzc3VyZVBjdC50b0ZpeGVkKDApfSVgKX08L3RleHQ+CiAgICAgIDx0ZXh0IHg9IjM2MCIgeT0iMzkw
IiBmaWxsPSIjNzE3MTdhIiBmb250LXNpemU9IjE4Ij5WT0xVTUUgRVhQQU5TSU9OPC90ZXh0PgogICAgICA8dGV4dCB4PSIzNjAiIHk9IjQyNSIgZmlsbD0i
I2ZmZmZmZiIgZm9udC1zaXplPSIzMCIgZm9udC13ZWlnaHQ9IjYwMCI+JHt4bWwoY2FsbC52b2x1bWVTcGlrZSA9PT0gbnVsbCA/ICJOL0EiIDogYCR7Y2Fs
bC52b2x1bWVTcGlrZS50b0ZpeGVkKDEpfVhgKX08L3RleHQ+CiAgICAgIDx0ZXh0IHg9IjcyMCIgeT0iMzkwIiBmaWxsPSIjNzE3MTdhIiBmb250LXNpemU9
IjE4Ij5TSUdOQUwgU0NPUkU8L3RleHQ+CiAgICAgIDx0ZXh0IHg9IjcyMCIgeT0iNDI1IiBmaWxsPSIjZmZmZmZmIiBmb250LXNpemU9IjMwIiBmb250LXdl
aWdodD0iNjAwIj4ke01hdGgucm91bmQoY2FsbC5zaWduYWxTY29yZSl9LzEwMDwvdGV4dD4KICAgICAgPHRleHQgeD0iNzIiIHk9IjUyMCIgZmlsbD0iIzcx
NzE3YSIgZm9udC1zaXplPSIyMCI+SVQgTEFURVIgUkVBQ0hFRDwvdGV4dD4KICAgICAgPHRleHQgeD0iNzIiIHk9IjU3MCIgZmlsbD0iJHthY2NlbnR9IiBm
b250LXNpemU9IjQ4IiBmb250LXdlaWdodD0iNzAwIj4ke3htbChjb21wYWN0VXNkKGNhbGwucGVha01hcmtldENhcFVzZCkpfSBNQyDCtyAke3htbChtdWx0
aXBsZVRleHQoY2FsbC5wZWFrTXVsdGlwbGUpKX08L3RleHQ+CiAgICBgCiAgICA6IGAKICAgICAgPHRleHQgeD0iNzIiIHk9IjI4MCIgZmlsbD0iIzcxNzE3
YSIgZm9udC1zaXplPSIyMCI+Q0FMTCBNQzwvdGV4dD4KICAgICAgPHRleHQgeD0iNzIiIHk9IjMyNSIgZmlsbD0iI2ZmZmZmZiIgZm9udC1zaXplPSI0MiIg
Zm9udC13ZWlnaHQ9IjcwMCI+JHt4bWwoY29tcGFjdFVzZChjYWxsLmNhbGxNYXJrZXRDYXBVc2QpKX08L3RleHQ+CiAgICAgIDx0ZXh0IHg9IjQyMCIgeT0i
MjgwIiBmaWxsPSIjNzE3MTdhIiBmb250LXNpemU9IjIwIj5QRUFLIE1DPC90ZXh0PgogICAgICA8dGV4dCB4PSI0MjAiIHk9IjMyNSIgZmlsbD0iI2ZmZmZm
ZiIgZm9udC1zaXplPSI0MiIgZm9udC13ZWlnaHQ9IjcwMCI+JHt4bWwoY29tcGFjdFVzZChjYWxsLnBlYWtNYXJrZXRDYXBVc2QpKX08L3RleHQ+CiAgICAg
IDx0ZXh0IHg9IjgzMCIgeT0iMjgwIiBmaWxsPSIjNzE3MTdhIiBmb250LXNpemU9IjIwIj5QRUFLPC90ZXh0PgogICAgICA8dGV4dCB4PSI4MzAiIHk9IjMy
NSIgZmlsbD0iJHthY2NlbnR9IiBmb250LXNpemU9IjQ4IiBmb250LXdlaWdodD0iNzAwIj4ke3htbChtdWx0aXBsZVRleHQoY2FsbC5wZWFrTXVsdGlwbGUp
KX08L3RleHQ+CiAgICAgIDx0ZXh0IHg9IjcyIiB5PSI0MjUiIGZpbGw9IiM3MTcxN2EiIGZvbnQtc2l6ZT0iMTgiPkNBTEw8L3RleHQ+CiAgICAgIDx0ZXh0
IHg9IjcyIiB5PSI0NTgiIGZpbGw9IiNmZmZmZmYiIGZvbnQtc2l6ZT0iMjYiPiR7bmV3IERhdGUoY2FsbC5jYWxsZWRBdCkudG9JU09TdHJpbmcoKS5zbGlj
ZSgxMSwgMTYpfSBVVEM8L3RleHQ+CiAgICAgIDx0ZXh0IHg9IjMzMCIgeT0iNDI1IiBmaWxsPSIjNzE3MTdhIiBmb250LXNpemU9IjE4Ij4yWDwvdGV4dD4K
ICAgICAgPHRleHQgeD0iMzMwIiB5PSI0NTgiIGZpbGw9IiNmZmZmZmYiIGZvbnQtc2l6ZT0iMjYiPiR7eG1sKGR1cmF0aW9uKGNhbGwuY2FsbGVkQXQsIGNh
bGwubWlsZXN0b25lMnhBdCkpfTwvdGV4dD4KICAgICAgPHRleHQgeD0iNTYwIiB5PSI0MjUiIGZpbGw9IiM3MTcxN2EiIGZvbnQtc2l6ZT0iMTgiPjVYPC90
ZXh0PgogICAgICA8dGV4dCB4PSI1NjAiIHk9IjQ1OCIgZmlsbD0iI2ZmZmZmZiIgZm9udC1zaXplPSIyNiI+JHt4bWwoZHVyYXRpb24oY2FsbC5jYWxsZWRB
dCwgY2FsbC5taWxlc3RvbmU1eEF0KSl9PC90ZXh0PgogICAgICA8dGV4dCB4PSI3OTAiIHk9IjQyNSIgZmlsbD0iIzcxNzE3YSIgZm9udC1zaXplPSIxOCI+
MTBYPC90ZXh0PgogICAgICA8dGV4dCB4PSI3OTAiIHk9IjQ1OCIgZmlsbD0iI2ZmZmZmZiIgZm9udC1zaXplPSIyNiI+JHt4bWwoZHVyYXRpb24oY2FsbC5j
YWxsZWRBdCwgY2FsbC5taWxlc3RvbmUxMHhBdCkpfTwvdGV4dD4KICAgICAgPHRleHQgeD0iNzIiIHk9IjU2MCIgZmlsbD0iIzcxNzE3YSIgZm9udC1zaXpl
PSIxOCI+TUFYIERSQVdET1dOPC90ZXh0PgogICAgICA8dGV4dCB4PSI3MiIgeT0iNTk1IiBmaWxsPSIjZmZmZmZmIiBmb250LXNpemU9IjI4Ij4ke3htbChw
Y3QoY2FsbC5tYXhEcmF3ZG93blBjdCkpfTwvdGV4dD4KICAgICAgPHRleHQgeD0iMzYwIiB5PSI1NjAiIGZpbGw9IiM3MTcxN2EiIGZvbnQtc2l6ZT0iMTgi
PlNJR05BTCBTQ09SRTwvdGV4dD4KICAgICAgPHRleHQgeD0iMzYwIiB5PSI1OTUiIGZpbGw9IiNmZmZmZmYiIGZvbnQtc2l6ZT0iMjgiPiR7TWF0aC5yb3Vu
ZChjYWxsLnNpZ25hbFNjb3JlKX0vMTAwPC90ZXh0PgogICAgYDsKCiAgY29uc3Qgc3ZnID0gYDw/eG1sIHZlcnNpb249IjEuMCIgZW5jb2Rpbmc9IlVURi04
Ij8+CiAgPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxMjAwIiBoZWlnaHQ9IjY3NSIgdmlld0JveD0iMCAwIDEyMDAg
Njc1Ij4KICAgIDxyZWN0IHdpZHRoPSIxMjAwIiBoZWlnaHQ9IjY3NSIgZmlsbD0iIzA4MGEwZiIvPgogICAgPGNpcmNsZSBjeD0iMTA4MCIgY3k9IjgwIiBy
PSIyNjAiIGZpbGw9IiR7YWNjZW50fSIgb3BhY2l0eT0iMC4wNyIvPgogICAgPHJlY3QgeD0iNDIiIHk9IjQyIiB3aWR0aD0iMTExNiIgaGVpZ2h0PSI1OTEi
IHJ4PSIzMCIgZmlsbD0iIzBkMTAxNiIgc3Ryb2tlPSIjMjcyNzJhIi8+CiAgICA8dGV4dCB4PSI3MiIgeT0iMTAwIiBmaWxsPSIke2FjY2VudH0iIGZvbnQt
ZmFtaWx5PSJBcmlhbCwgc2Fucy1zZXJpZiIgZm9udC1zaXplPSIxOCIgbGV0dGVyLXNwYWNpbmc9IjQiPk1FTUVTQ09QRTwvdGV4dD4KICAgIDx0ZXh0IHg9
IjcyIiB5PSIxNDUiIGZpbGw9IiNmZmZmZmYiIGZvbnQtZmFtaWx5PSJBcmlhbCwgc2Fucy1zZXJpZiIgZm9udC1zaXplPSIyOCIgZm9udC13ZWlnaHQ9Ijcw
MCI+JHt0aXRsZX08L3RleHQ+CiAgICA8dGV4dCB4PSI3MiIgeT0iMjE1IiBmaWxsPSIjZmZmZmZmIiBmb250LWZhbWlseT0iQXJpYWwsIHNhbnMtc2VyaWYi
IGZvbnQtc2l6ZT0iNTYiIGZvbnQtd2VpZ2h0PSI3MDAiPiQke3htbChjYWxsLnN5bWJvbCl9PC90ZXh0PgogICAgPHRleHQgeD0iMTA4MCIgeT0iMjEyIiB0
ZXh0LWFuY2hvcj0iZW5kIiBmaWxsPSIjNzE3MTdhIiBmb250LWZhbWlseT0iQXJpYWwsIHNhbnMtc2VyaWYiIGZvbnQtc2l6ZT0iMjAiPiR7eG1sKGNhbGwu
cHVibGljSWQpfTwvdGV4dD4KICAgIDxnIGZvbnQtZmFtaWx5PSJBcmlhbCwgc2Fucy1zZXJpZiI+JHtib2R5fTwvZz4KICAgIDx0ZXh0IHg9IjEwODAiIHk9
IjYwNSIgdGV4dC1hbmNob3I9ImVuZCIgZmlsbD0iIzUyNTI1YiIgZm9udC1mYW1pbHk9IkFyaWFsLCBzYW5zLXNlcmlmIiBmb250LXNpemU9IjE2Ij5Pcmln
aW5hbCBjYWxsIHJlbWFpbnMgaW4gcHVibGljIGhpc3Rvcnk8L3RleHQ+CiAgPC9zdmc+YDsKCiAgcmV0dXJuIG5ldyBSZXNwb25zZShzdmcsIHsKICAgIGhl
YWRlcnM6IHsKICAgICAgImNvbnRlbnQtdHlwZSI6ICJpbWFnZS9zdmcreG1sOyBjaGFyc2V0PXV0Zi04IiwKICAgICAgImNhY2hlLWNvbnRyb2wiOiAicHVi
bGljLCBtYXgtYWdlPTYwLCBzdGFsZS13aGlsZS1yZXZhbGlkYXRlPTMwMCIsCiAgICB9LAogIH0pOwp9Cg==
"@

$payloads["README-MEMESCOPE-LIVE-CALL-INTELLIGENCE.md"] = @"
IyBNZW1lU2NvcGUgTGl2ZSBDYWxsIEludGVsbGlnZW5jZQoKVGhpcyB1cGRhdGUgdHVybnMgTWVtZVNjb3BlIGNhbGxzIGludG8gYSB0cmFja2VkIHB1Ymxp
YyBoaXN0b3J5IGFuZCBjb250ZW50IHdvcmtmbG93LgoKIyMgUHVibGljIFRlbGVncmFtIGJlaGF2aW9yCgotIE5FVyBDQUxMIGlzIHBvc3RlZCBvbmNlIGFu
ZCBpcyBuZXZlciBlZGl0ZWQuCi0gU2lsZW50IHRyYWNraW5nIGNvbnRpbnVlcyBpbiB0aGUgYmFja2dyb3VuZC4KLSBQdWJsaWMgbWlsZXN0b25lIHBvc3Rz
IGFyZSBsaW1pdGVkIHRvIDJYLCA1WCBhbmQgMTBYKy4KLSBJZiBhIGNhbGwganVtcHMgYWNyb3NzIHNldmVyYWwgbWlsZXN0b25lcyBiZXR3ZWVuIGNoZWNr
cywgb25seSB0aGUgaGlnaGVzdCBuZXdseSByZWFjaGVkIG1pbGVzdG9uZSBpcyBwb3N0ZWQuCi0gMjBYLCA1MFggYW5kIDEwMFggYXJlIG5vdCBhZGRlZCB0
byB0aGUgcHVibGljIG1pbGVzdG9uZSBsYWRkZXI7IHRoZXkgYmVjb21lIHByaXZhdGUgQ29udGVudCBIUSBvcHBvcnR1bml0aWVzLgotIERhaWx5IFRhcGUg
aXMgcG9zdGVkIG9uY2UgcGVyIGRheSBhZnRlciAyMzowMCBpbiB0aGUgcmVwb3J0IHRpbWV6b25lLgotIFdlZWtseSBJbnRlbGxpZ2VuY2UgaXMgcG9zdGVk
IG9uIFN1bmRheSBhZnRlciAyMzowMC4KLSBEZWZhdWx0IHJlcG9ydCB0aW1lem9uZSBpcyBgQXNpYS9KYWthcnRhYDsgb3B0aW9uYWwgb3ZlcnJpZGU6IGBN
RU1FU0NPUEVfUkVQT1JUX1RJTUVaT05FYC4KCiMjIFdlYnNpdGUKCi0gYC9jYWxsc2Ag4oCUIEhhbGwgb2YgQ2FsbHMgKyAzMC1kYXkgcHVibGljIHN0YXRp
c3RpY3MgKyByZWNlbnQgY2FsbCBoaXN0b3J5LgotIGAvY2FsbHMvW3B1YmxpY0lkXWAg4oCUIGNvbXBsZXRlIENhbGwgSm91cm5leS4KLSBgL2FwaS9jYWxs
cy9bcHVibGljSWRdL2NhcmQ/bW9kZT1qb3VybmV5YCDigJQgc2hhcmVhYmxlIEpvdXJuZXkgQ2FyZCAoU1ZHKS4KLSBgL2FwaS9jYWxscy9bcHVibGljSWRd
L2NhcmQ/bW9kZT1iZWZvcmVgIOKAlCBzaGFyZWFibGUgQmVmb3JlIFRoZSBNb3ZlIGNhcmQgKFNWRykuCgojIyBQcml2YXRlIENvbnRlbnQgSFEKCjEuIENy
ZWF0ZSBhIHByaXZhdGUgVGVsZWdyYW0gZ3JvdXAgbmFtZWQgZS5nLiBgTWVtZVNjb3BlIOKAlCBDb250ZW50IEhRYC4KMi4gQWRkIHRoZSBleGlzdGluZyBN
ZW1lU2NvcGUgYm90IHRvIHRoZSBncm91cC4KMy4gRnJvbSB0aGUgb3duZXIgVGVsZWdyYW0gYWNjb3VudCwgc2VuZCBgL2JpbmRjb250ZW50aHFgIGluc2lk
ZSB0aGF0IGdyb3VwLgo0LiBDaGVjayB3aXRoIGAvY29udGVudGhxYC4KClRoZSBncm91cCByZWNlaXZlcyBoaWdoLXZhbHVlIGNvbnRlbnQgb3Bwb3J0dW5p
dGllcywgc3VnZ2VzdGVkIFggaG9va3MgYW5kIGxpbmtzIHRvIGdlbmVyYXRlZCBjYXJkcy4gSXQgZG9lcyAqKm5vdCoqIGF1dG9tYXRpY2FsbHkgcG9zdCB0
byBYLgoKIyMgQ29udGVudCBvcHBvcnR1bml0aWVzCgotIEZhc3QgMlggKHdpdGhpbiA2MCBtaW51dGVzKTogbWVkaXVtIHByaW9yaXR5LgotIDVYOiBoaWdo
IHByaW9yaXR5LgotIDEwWDogZmVhdHVyZWQuCi0gMjBYIC8gNTBYIC8gMTAwWDogc3BlY2lhbC1zdG9yeSBjYW5kaWRhdGVzLCBwcml2YXRlIHRvIENvbnRl
bnQgSFEuCgojIyBOb3QgaW5jbHVkZWQgYnkgcmVxdWVzdAoKLSBObyBYIGF1dG8tcHVibGlzaGluZy4KLSBObyB0cmFkZSBwYWdlIC8gdHJhZGluZy1ib3Qg
ZXhlY3V0aW9uIGludGVncmF0aW9uLgoKIyMgQWZ0ZXIgaW5zdGFsbAoKYGBgcG93ZXJzaGVsbApucG0gcnVuIHR5cGVjaGVjawpucG0gcnVuIGJ1aWxkCmdp
dCBhZGQgc3JjCmdpdCBjb21taXQgLW0gIkFkZCBNZW1lU2NvcGUgTGl2ZSBDYWxsIEludGVsbGlnZW5jZSIKZ2l0IHB1c2gKbnB4IHZlcmNlbEBsYXRlc3Qg
ZGVwbG95IC0tcHJvZCAtLWZvcmNlCnBvd2Vyc2hlbGwgLUV4ZWN1dGlvblBvbGljeSBCeXBhc3MgLUZpbGUgIi5cYm9vdHN0cmFwLXRlbGVncmFtLnBzMSIK
YGBgCgpUaGVuIGNyZWF0ZS9iaW5kIENvbnRlbnQgSFEgYW5kIG9wZW4gYC9jYWxsc2Agb24gcHJvZHVjdGlvbi4K
"@


Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " MemeScope Live Call Intelligence - Full Upgrade" -ForegroundColor Cyan
Write-Host " Stages 19.4 - 20.1 (No X Auto-Post / No Trade Page)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$root = (Get-Location).Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

if (!(Test-Path -LiteralPath (Join-Path $root "package.json"))) {
    throw "package.json tidak ditemukan. Jalankan dari root memecoin-analyst."
}

$recorderPath = Join-Path $root "src/lib/signal-recorder-db.ts"
$publisherPath = Join-Path $root "src/lib/telegram-publisher.ts"
$telegramPath = Join-Path $root "src/lib/telegram.ts"
$webhookPath = Join-Path $root "src/app/api/telegram/webhook/route.ts"
$sidebarPath = Join-Path $root "src/components/sidebar.tsx"

foreach ($path in @($recorderPath, $publisherPath, $telegramPath, $webhookPath)) {
    if (!(Test-Path -LiteralPath $path)) {
        throw "Required source missing: $path"
    }
}

$recorder = [System.IO.File]::ReadAllText($recorderPath)
$publisher = [System.IO.File]::ReadAllText($publisherPath)
$telegram = [System.IO.File]::ReadAllText($telegramPath)
$webhook = [System.IO.File]::ReadAllText($webhookPath)
$sidebar = if (Test-Path -LiteralPath $sidebarPath) { [System.IO.File]::ReadAllText($sidebarPath) } else { $null }

# ------------------------------------------------------------
# Prevalidate before writing anything.
# ------------------------------------------------------------
if (!$recorder.Contains("Stage 17 Telegram publisher") -and !$recorder.Contains("Stage 20 Call Story cycle")) {
    throw "Recorder Stage 17 marker tidak ditemukan. Tidak ada file yang diubah."
}

if (!$publisher.Contains("export async function publishPendingTelegramSignals()")) {
    throw "Telegram publisher function tidak ditemukan. Tidak ada file yang diubah."
}

if (!$publisher.Contains("ensureTelegramPublisherSchema")) {
    throw "Telegram publisher schema marker tidak ditemukan. Tidak ada file yang diubah."
}

if (!$telegram.Contains("export async function telegramSetCommands()")) {
    throw "telegramSetCommands tidak ditemukan. Tidak ada file yang diubah."
}

if (!$webhook.Contains("async function handleCallback(")) {
    throw "Telegram webhook callback handler tidak ditemukan. Tidak ada file yang diubah."
}

# ------------------------------------------------------------
# Recorder: run Call Story cycle before the immutable publisher.
# ------------------------------------------------------------
$patchedRecorder = $recorder
if (!$patchedRecorder.Contains("Stage 20 Call Story cycle")) {
    $marker = "  // Stage 17 Telegram publisher."
    if (!$patchedRecorder.Contains($marker)) {
        throw "Recorder publisher marker tidak ditemukan. Tidak ada file yang diubah."
    }
    $patchedRecorder = $patchedRecorder.Replace($marker, $recorderBlock + $marker)
}

# ------------------------------------------------------------
# Telegram publisher: NEW CALL only, immutable, no Potential TP.
# ------------------------------------------------------------
$patchedPublisher = $publisher

if (!$patchedPublisher.Contains('from "@/lib/call-story"')) {
    $importMarker = '} from "@/lib/telegram";'
    $idx = $patchedPublisher.IndexOf($importMarker)
    if ($idx -lt 0) {
        throw "Publisher Telegram import marker tidak ditemukan. Tidak ada file yang diubah."
    }
    $idx += $importMarker.Length
    $patchedPublisher = $patchedPublisher.Substring(0, $idx) + "`r`n" + $callStoryImport + $patchedPublisher.Substring($idx)
}

if (!$patchedPublisher.Contains("Original call will remain unchanged")) {
    $channelStart = $patchedPublisher.IndexOf("async function channelText(")
    if ($channelStart -lt 0) {
        $channelStart = $patchedPublisher.IndexOf("function channelText(")
    }
    $targetStart = $patchedPublisher.IndexOf("function targetReply(", $channelStart)
    if ($channelStart -lt 0 -or $targetStart -le $channelStart) {
        throw "Publisher channelText/targetReply markers tidak ditemukan. Tidak ada file yang diubah."
    }
    $patchedPublisher = $patchedPublisher.Substring(0, $channelStart) + $newChannelText + "`r`n" + $patchedPublisher.Substring($targetStart)
}

# Remove the legacy target-reply formatter; public TP updates are no longer used.
$targetReplyStart = $patchedPublisher.IndexOf("function targetReply(")
if ($targetReplyStart -ge 0) {
    $schemaStart = $patchedPublisher.IndexOf("export async function ensureTelegramPublisherSchema()", $targetReplyStart)
    if ($schemaStart -le $targetReplyStart) {
        throw "Publisher targetReply boundary tidak ditemukan. Tidak ada file yang diubah."
    }
    $patchedPublisher = $patchedPublisher.Substring(0, $targetReplyStart) + $patchedPublisher.Substring($schemaStart)
}

$publisherStart = $patchedPublisher.IndexOf("export async function publishPendingTelegramSignals()")
if ($publisherStart -lt 0) {
    throw "Publisher function start tidak ditemukan. Tidak ada file yang diubah."
}
$patchedPublisher = $patchedPublisher.Substring(0, $publisherStart) + $newPublisherFunction + "`r`n"

if (!$patchedPublisher.Contains("telegramEditMessage(")) {
    $patchedPublisher = [regex]::Replace(
        $patchedPublisher,
        '(?m)^[ \t]*telegramEditMessage,\r?\n',
        '',
        1
    )
}

if ($patchedPublisher.Contains("Potential TP:")) {
    throw "Publisher validation failed: Potential TP text masih aktif. Tidak ada file yang diubah."
}
if (!$patchedPublisher.Contains("await channelText(record)")) {
    throw "Publisher validation failed: async channelText belum benar. Tidak ada file yang diubah."
}

# ------------------------------------------------------------
# Telegram command menu: Content HQ commands.
# ------------------------------------------------------------
$patchedTelegram = $telegram
if (!$patchedTelegram.Contains('command: "contenthq"')) {
    $commandsMarker = "      commands: ["
    $idx = $patchedTelegram.IndexOf($commandsMarker)
    if ($idx -lt 0) {
        throw "Telegram commands array tidak ditemukan. Tidak ada file yang diubah."
    }
    $idx += $commandsMarker.Length
    $commands = @'

        {
          command: "contenthq",
          description:
            "Content HQ status",
        },
        {
          command: "bindcontenthq",
          description:
            "Bind private Content HQ group",
        },
'@
    $patchedTelegram = $patchedTelegram.Substring(0, $idx) + $commands + $patchedTelegram.Substring($idx)
}

# ------------------------------------------------------------
# Owner webhook: bind Content HQ + content review callbacks.
# ------------------------------------------------------------
$patchedWebhook = $webhook

if (!$patchedWebhook.Contains('from "@/lib/call-story"')) {
    $anchor = "import {`r`n  applySignalPreset,"
    if (!$patchedWebhook.Contains($anchor)) {
        $anchor = "import {`n  applySignalPreset,"
    }
    $idx = $patchedWebhook.IndexOf($anchor)
    if ($idx -lt 0) {
        throw "Webhook import anchor tidak ditemukan. Tidak ada file yang diubah."
    }
    $patchedWebhook = $patchedWebhook.Substring(0, $idx) + $webhookCallStoryImport + $patchedWebhook.Substring($idx)
}

if (!$patchedWebhook.Contains("type?: string;")) {
    $chatPattern = '(?s)chat\?:\s*\{\s*id\?: number;\s*\};'
    if (![regex]::IsMatch($patchedWebhook, $chatPattern)) {
        throw "Webhook Telegram chat type block tidak ditemukan. Tidak ada file yang diubah."
    }
    $chatReplacement = @'
chat?: {
    id?: number;
    type?: string;
    title?: string;
  };
'@
    $patchedWebhook = [regex]::Replace($patchedWebhook, $chatPattern, $chatReplacement, 1)
}

if (!$patchedWebhook.Contains("Unknown content action.")) {
    $callbackMarker = @'
  if (
    data ===
    "preset:refresh"
  ) {
'@
    if (!$patchedWebhook.Contains($callbackMarker)) {
        $callbackMarker = $callbackMarker -replace "`r`n", "`n"
    }
    $idx = $patchedWebhook.IndexOf($callbackMarker)
    if ($idx -lt 0) {
        throw "Webhook preset callback marker tidak ditemukan. Tidak ada file yang diubah."
    }
    $patchedWebhook = $patchedWebhook.Substring(0, $idx) + $contentCallbackBlock + $patchedWebhook.Substring($idx)
}

if (!$patchedWebhook.Contains("/bindcontenthq - bind this private group as Content HQ")) {
    $helpMarker = '    "/settings - preset control panel",'
    if (!$patchedWebhook.Contains($helpMarker)) {
        throw "Webhook help marker tidak ditemukan. Tidak ada file yang diubah."
    }
    $helpReplacement = @'
    "/settings - preset control panel",
    "/contenthq - Content HQ status",
    "/bindcontenthq - bind this private group as Content HQ",
'@
    $patchedWebhook = $patchedWebhook.Replace($helpMarker, $helpReplacement)
}

if (!$patchedWebhook.Contains("MEMESCOPE CONTENT HQ CONNECTED")) {
    $branchMarker = @'
  try {
    if (
      command === "/start" ||
      command === "/help"
    ) {
'@
    if (!$patchedWebhook.Contains($branchMarker)) {
        $branchMarker = $branchMarker -replace "`r`n", "`n"
    }
    $idx = $patchedWebhook.IndexOf($branchMarker)
    if ($idx -lt 0) {
        throw "Webhook command branch marker tidak ditemukan. Tidak ada file yang diubah."
    }
    $patchedWebhook = $patchedWebhook.Substring(0, $idx) + $contentCommandBranch + $patchedWebhook.Substring($idx + $branchMarker.Length)
}

if (!$patchedWebhook.Contains("setContentOpportunityStatus")) {
    throw "Webhook Content HQ validation failed. Tidak ada file yang diubah."
}

# ------------------------------------------------------------
# Sidebar: add Calls using the same icon already used by Signals.
# Optional if custom sidebar structure differs.
# ------------------------------------------------------------
$patchedSidebar = $sidebar
if ($null -ne $patchedSidebar -and !$patchedSidebar.Contains('href: "/calls"')) {
    $match = [regex]::Match(
        $patchedSidebar,
        '(?m)^(\s*)\{\s*href:\s*"/signals",\s*label:\s*"[^"]+",\s*icon:\s*([A-Za-z0-9_]+)\s*\},\s*$'
    )
    if ($match.Success) {
        $indent = $match.Groups[1].Value
        $icon = $match.Groups[2].Value
        $line = $match.Value
        $callsLine = $indent + '{ href: "/calls", label: "Calls", icon: ' + $icon + ' },'
        $patchedSidebar = $patchedSidebar.Replace($line, $line + [Environment]::NewLine + $callsLine)
    } else {
        Write-Host "Sidebar custom structure detected; /calls route will work but nav item was not auto-added." -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------
# Back up only after every patch has validated in memory.
# ------------------------------------------------------------
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $env:TEMP "MemeScope-LiveCall-$stamp"
New-Item -ItemType Directory -Force -Path $backup | Out-Null

foreach ($path in @($recorderPath, $publisherPath, $telegramPath, $webhookPath, $sidebarPath)) {
    if (Test-Path -LiteralPath $path) {
        $safe = ((Resolve-Path -LiteralPath $path).Path -replace '[^A-Za-z0-9._-]', '_')
        Copy-Item -LiteralPath $path -Destination (Join-Path $backup $safe) -Force
    }
}

# ------------------------------------------------------------
# Write patched existing files.
# ------------------------------------------------------------
[System.IO.File]::WriteAllText($recorderPath, $patchedRecorder, $utf8)
[System.IO.File]::WriteAllText($publisherPath, $patchedPublisher, $utf8)
[System.IO.File]::WriteAllText($telegramPath, $patchedTelegram, $utf8)
[System.IO.File]::WriteAllText($webhookPath, $patchedWebhook, $utf8)
if ($null -ne $patchedSidebar -and $patchedSidebar -ne $sidebar) {
    [System.IO.File]::WriteAllText($sidebarPath, $patchedSidebar, $utf8)
}

# ------------------------------------------------------------
# Write new source files from base64 payloads (UTF-8, no BOM).
# ------------------------------------------------------------
foreach ($relative in $payloads.Keys) {
    $target = Join-Path $root $relative
    $dir = Split-Path -Parent $target
    if ($dir -and !(Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $bytes = [Convert]::FromBase64String(($payloads[$relative] -replace '\s', ''))
    [System.IO.File]::WriteAllBytes($target, $bytes)
    Write-Host "Created/Updated: $relative" -ForegroundColor Green
}

Remove-Item (Join-Path $root ".next") -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " MemeScope Live Call Intelligence installed" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Installed:" -ForegroundColor Cyan
Write-Host " - Immutable NEW CALL posts; no public Potential TP / target-hit spam"
Write-Host " - Silent live tracking after the legacy signal lifecycle closes"
Write-Host " - Highest-new-milestone-only public events: 2X / 5X / 10X+"
Write-Host " - 20X / 50X / 100X private special-story candidates"
Write-Host " - Permanent MemeScope public call IDs"
Write-Host " - /calls Hall of Calls + 30D transparent stats"
Write-Host " - /calls/[id] public Call Journey"
Write-Host " - Journey Card + Before The Move SVG cards"
Write-Host " - Private Telegram Content HQ binding + review inbox"
Write-Host " - Daily Tape + Weekly Intelligence"
Write-Host " - NO X auto-publishing"
Write-Host " - NO trade page"
Write-Host ""
Write-Host "Backup: $backup" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Next:" -ForegroundColor Cyan
Write-Host " npm run typecheck"
Write-Host " npm run build"
Write-Host ""
