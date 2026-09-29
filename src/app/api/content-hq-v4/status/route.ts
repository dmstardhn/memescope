import { NextResponse } from "next/server";
import { v4Status } from "@/lib/content-hq-v4/db";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  try {
    return NextResponse.json({ok:true, ...(await v4Status())});
  } catch (error) {
    return NextResponse.json({ok:false,error:error instanceof Error ? error.message : String(error)},{status:500});
  }
}