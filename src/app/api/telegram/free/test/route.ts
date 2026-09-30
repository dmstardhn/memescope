import { NextResponse } from "next/server";

import { sendFreeChannelTest } from "@/lib/free-channel";

function authorized(request: Request) {
  const secret = process.env.CRON_SECRET?.trim();

  return Boolean(
    secret &&
      request.headers.get("authorization") === `Bearer ${secret}`,
  );
}

export async function POST(request: Request) {
  if (!authorized(request)) {
    return NextResponse.json(
      {
        ok: false,
        error: "Unauthorized.",
      },
      {
        status: 401,
      },
    );
  }

  try {
    const url = new URL(request.url);
    const kind = url.searchParams.get("kind") === "vip" ? "vip" : "dex";
    const result = await sendFreeChannelTest(kind);

    return NextResponse.json({
      ok: true,
      kind,
      delivered: true,
      messageId: result.message_id,
    });
  } catch (error) {
    return NextResponse.json(
      {
        ok: false,
        error:
          error instanceof Error
            ? error.message
            : "FREE channel test failed.",
      },
      {
        status: 500,
      },
    );
  }
}
