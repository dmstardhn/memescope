import { NextResponse } from "next/server";
import { processContentHqV4 } from "@/lib/content-hq-v4/engine";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorized(request: Request) {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret) return process.env.NODE_ENV !== "production";
  return request.headers.get("authorization") === `Bearer ${secret}`;
}

export async function GET(request: Request) {
  if (!authorized(request)) return NextResponse.json({error:"Unauthorized"},{status:401});
  try {
    return NextResponse.json(await processContentHqV4());
  } catch (error) {
    console.error("Content HQ V4 process failed", error);
    return NextResponse.json({ok:false,error:error instanceof Error ? error.message : String(error)},{status:500});
  }
}

export async function POST(request: Request) {
  return GET(request);
}