import { NextResponse } from "next/server";
import { approve, nextCaption, nextVisual, reject } from "@/lib/content-hq-v4/queue-control";
import { publishNow, scheduleIn } from "@/lib/content-hq-v4/publisher";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function authorized(request: Request) {
  const expected = process.env.CONTENT_HQ_ADMIN_KEY?.trim() || process.env.CRON_SECRET?.trim();
  if (!expected) return process.env.NODE_ENV !== "production";
  return request.headers.get("authorization") === `Bearer ${expected}`;
}

export async function POST(request: Request) {
  if (!authorized(request)) return NextResponse.json({error:"Unauthorized"},{status:401});

  try {
    const body = await request.json() as {id?:number;action?:string;minutes?:number};
    const id = Number(body.id);
    if (!Number.isFinite(id)) return NextResponse.json({error:"Invalid id"},{status:400});

    if (body.action === "approve") await approve(id);
    else if (body.action === "reject") await reject(id);
    else if (body.action === "next_caption") await nextCaption(id);
    else if (body.action === "next_visual") await nextVisual(id);
    else if (body.action === "publish_now") return NextResponse.json({ok:true,result:await publishNow(id,true)});
    else if (body.action === "schedule") return NextResponse.json({ok:true,scheduledAt:await scheduleIn(id,Number(body.minutes ?? 60))});
    else return NextResponse.json({error:"Unknown action"},{status:400});

    return NextResponse.json({ok:true});
  } catch (error) {
    return NextResponse.json({ok:false,error:error instanceof Error ? error.message : String(error)},{status:500});
  }
}