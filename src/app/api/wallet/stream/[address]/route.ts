import WebSocket from "ws";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function validAddress(address: string) {
  return /^[1-9A-HJ-NP-Za-km-z]{32,44}$/.test(address);
}

function websocketUrl() {
  const configured = process.env.SOLANA_WSS_URL?.trim();

  if (configured) return configured;

  const http = process.env.SOLANA_RPC_URL?.trim();

  if (http) {
    if (http.startsWith("https://")) {
      return http.replace(/^https:/, "wss:");
    }

    if (http.startsWith("http://")) {
      return http.replace(/^http:/, "ws:");
    }
  }

  return "wss://api.mainnet.solana.com/";
}

export async function GET(
  _request: Request,
  context: { params: Promise<{ address: string }> },
) {
  const { address } = await context.params;
  const encoder = new TextEncoder();

  if (!validAddress(address)) {
    return new Response(
      encoder.encode(
        `event: error\ndata: ${JSON.stringify({
          error: "Invalid Solana wallet address.",
        })}\n\n`,
      ),
      {
        status: 400,
        headers: {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache, no-transform",
        },
      },
    );
  }

  let socket: WebSocket | null = null;
  let heartbeat: ReturnType<typeof setInterval> | null = null;
  let closed = false;

  const stream = new ReadableStream({
    start(controller) {
      function push(
        event: string,
        payload: unknown,
      ) {
        if (closed) return;

        try {
          controller.enqueue(
            encoder.encode(
              `event: ${event}\ndata: ${JSON.stringify(
                payload,
              )}\n\n`,
            ),
          );
        } catch {
          closed = true;
        }
      }

      push("status", {
        state: "connecting",
        source: "Solana WebSocket",
      });

      socket = new WebSocket(websocketUrl());

      socket.on("open", () => {
        push("status", {
          state: "live",
          source: "Solana WebSocket",
        });

        socket?.send(
          JSON.stringify({
            jsonrpc: "2.0",
            id: 1,
            method: "logsSubscribe",
            params: [
              {
                mentions: [address],
              },
              {
                commitment: "processed",
              },
            ],
          }),
        );
      });

      socket.on("message", (buffer) => {
        try {
          const message = JSON.parse(
            buffer.toString(),
          ) as {
            method?: string;
            params?: {
              result?: {
                context?: {
                  slot?: number;
                };
                value?: {
                  signature?: string;
                  err?: unknown;
                };
              };
            };
            result?: number;
          };

          if (message.method === "logsNotification") {
            push("wallet", {
              receivedAt: Date.now(),
              slot:
                message.params?.result?.context?.slot ??
                null,
              signature:
                message.params?.result?.value
                  ?.signature ?? null,
              error:
                message.params?.result?.value?.err ??
                null,
            });
          }

          if (
            typeof message.result === "number"
          ) {
            push("subscribed", {
              subscriptionId: message.result,
            });
          }
        } catch {
          // Ignore malformed upstream messages.
        }
      });

      socket.on("error", () => {
        push("status", {
          state: "degraded",
          source: "Solana WebSocket",
        });
      });

      socket.on("close", () => {
        push("status", {
          state: "closed",
          source: "Solana WebSocket",
        });
      });

      heartbeat = setInterval(() => {
        push("heartbeat", {
          at: Date.now(),
        });
      }, 15_000);
    },

    cancel() {
      closed = true;

      if (heartbeat) {
        clearInterval(heartbeat);
      }

      if (
        socket &&
        socket.readyState === WebSocket.OPEN
      ) {
        socket.close();
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
