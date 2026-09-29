export type ContentType =
  | "new_discovery"
  | "runner"
  | "big_runner"
  | "moonshot"
  | "before_move"
  | "wallet_activity"
  | "smart_money"
  | "holder_growth"
  | "memescope_detection"
  | "call_journey"
  | "weekly_recap"
  | "hall_of_calls"
  | "text_only";

export type VisualSource =
  | "dex_screener"
  | "gmgn"
  | "memescope"
  | "text_only";

export type QueueStatus =
  | "draft"
  | "queued"
  | "approved"
  | "scheduled"
  | "published"
  | "failed"
  | "rejected";

export type ScreenshotPreset = string;

export type ContentConfig = {
  runnerGainPct: number;
  bigRunnerGainPct: number;
  moonshotGainPct: number;
  beforeMoveGainPct: number;
  minLiquidityUsd: number;
  minVolumeUsd: number;
  maxTokenAgeHours: number;
  tokenPostCooldownMinutes: number;
  maxPostsPerDay: number;
  minimumGapMinutes: number;
  maxSameContentTypeConsecutive: number;
  maxSameSourceConsecutive: number;
  manualApproval: boolean;
  dexTargetPct: number;
  gmgnTargetPct: number;
  memescopeTargetPct: number;
  textTargetPct: number;
};

export type ContentCandidate = {
  eventKey: string;
  tokenAddress: string;
  pairAddress: string | null;
  symbol: string;
  name: string;
  contentType: ContentType;
  priority: number;
  firstMarketCap: number | null;
  currentMarketCap: number | null;
  gainPct: number;
  multiple: number;
  liquidityUsd: number | null;
  volumeUsd: number | null;
  ageHours: number | null;
  callPublicId: string | null;
  milestone: string | null;
  detectedAt: string;
};

export type CaptionTemplate = {
  id: number;
  templateKey: string;
  contentType: ContentType;
  body: string;
  isActive: boolean;
  useCount: number;
};

export type QueueItem = {
  id: number;
  eventKey: string;
  tokenAddress: string;
  pairAddress: string | null;
  symbol: string;
  contentType: ContentType;
  priority: number;
  captionTemplate: string;
  caption: string;
  visualSource: VisualSource;
  screenshotPreset: ScreenshotPreset;
  imageMime: string | null;
  status: QueueStatus;
  firstMarketCap: number | null;
  currentMarketCap: number | null;
  gainPct: number;
  multiple: number;
  createdAt: string;
  scheduledAt: string | null;
  publishedAt: string | null;
  xPostId: string | null;
  telegramMessageId: number | null;
};