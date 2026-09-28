import {
  pumpConfigured,
  subscribePump,
} from "@/lib/pumpportal-hub";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  const encoder = new TextEncoder();

  if (!pumpConfigured()) {
    return new Response(
      encoder.encode(
        `event: status\ndata: ${JSON.stringify({
          configured: false,
          message:
            "PUMPPORTAL_API_KEY is not configured.",
        })}\n\n`,
      ),
      {
        status: 200,
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache, no-transform",
          Connection: "keep-alive",
        },
      },
    );
  }

  let unsubscribe: (() => void) | null = null;
  let heartbeat: ReturnType<
    typeof setInterval
  > | null = null;

  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(
        encoder.encode(
          `event: status\ndata: ${JSON.stringify({
            configured: true,
            message: "PumpPortal stream connecting.",
          })}\n\n`,
        ),
      );

      unsubscribe = subscribePump((event) => {
        controller.enqueue(
          encoder.encode(
            `event: pump\ndata: ${JSON.stringify(
              event,
            )}\n\n`,
          ),
        );
      });

      heartbeat = setInterval(() => {
        try {
          controller.enqueue(
            encoder.encode(
              `event: heartbeat\ndata: ${Date.now()}\n\n`,
            ),
          );
        } catch {
          // Client disconnected.
        }
      }, 15_000);
    },
    cancel() {
      unsubscribe?.();

      if (heartbeat) {
        clearInterval(heartbeat);
      }
    },
  });

  return new Response(stream, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache, no-transform",
      Connection: "keep-alive",
    },
  });
}
