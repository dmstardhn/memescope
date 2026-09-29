import { NextResponse } from "next/server";
import { contentHqV4TestBatch } from "@/lib/content-hq-v4/engine";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorized(request: Request) {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret) return process.env.NODE_ENV !== "production";
  return request.headers.get("authorization") === `Bearer ${secret}`;
}

export async function POST(request: Request) {
  if (!authorized(request)) {
    return NextResponse.json({error:"Unauthorized"},{status:401});
  }

  try {
    const body = await request.json().catch(()=>({})) as {limit?:number};
    const limit = Math.max(1,Math.min(Number(body.limit ?? 6),8));
    return NextResponse.json(await contentHqV4TestBatch(limit));
  } catch (error) {
    return NextResponse.json(
      {ok:false,error:error instanceof Error ? error.message : String(error)},
      {status:500},
    );
  }
}