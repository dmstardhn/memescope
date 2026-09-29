import { NextResponse } from "next/server";
import { VISUAL_TEMPLATES } from "@/lib/content-hq-blueprint-v3";

export async function GET() {
  return NextResponse.json({
    ok: true,
    count: VISUAL_TEMPLATES.length,
    templates: VISUAL_TEMPLATES,
  });
}