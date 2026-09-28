import { NextResponse } from "next/server";

export function GET() {
  return NextResponse.json({
    ok: true,
    service: "memecoin-analyst",
    version: "0.1.0",
  });
}