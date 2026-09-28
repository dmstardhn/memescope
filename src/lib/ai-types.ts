export type AIAnalysisResponse = {
  ok: boolean;
  mode: "local" | "openai";
  model: string | null;
  tokenAddress: string;
  symbol: string | null;
  name: string | null;
  headline: string;
  summary: string;
  strengths: string[];
  risks: string[];
  watch: string[];
  verdict: string;
  generatedAt: number;
  disclaimer: string;
  error?: string;
};
