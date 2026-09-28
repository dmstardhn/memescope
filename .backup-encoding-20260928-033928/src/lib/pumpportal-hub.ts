import WebSocket from "ws";
import type { PumpLiveEvent } from "@/lib/discover-types";

type Listener = (event: PumpLiveEvent) => void;

type PumpHub = {
  socket: WebSocket | null;
  connecting: boolean;
  listeners: Set<Listener>;
  reconnectTimer: ReturnType<typeof setTimeout> | null;
};

declare global {
  var __memeScopePumpHub: PumpHub | undefined;
}

function getHub(): PumpHub {
  if (!globalThis.__memeScopePumpHub) {
    globalThis.__memeScopePumpHub = {
      socket: null,
      connecting: false,
      listeners: new Set(),
      reconnectTimer: null,
    };
  }

  return globalThis.__memeScopePumpHub;
}

function normalizeEvent(raw: Record<string, unknown>): PumpLiveEvent {
  const rawType =
    typeof raw.txType === "string"
      ? raw.txType
      : typeof raw.type === "string"
        ? raw.type
        : typeof raw.event === "string"
          ? raw.event
          : null;

  const lower = rawType?.toLowerCase() || "";

  let type: PumpLiveEvent["type"] = "unknown";

  if (
    lower.includes("create") ||
    lower.includes("new")
  ) {
    type = "new-token";
  } else if (
    lower.includes("migrat") ||
    lower.includes("complete")
  ) {
    type = "migration";
  }

  const value = (key: string) =>
    typeof raw[key] === "string"
      ? (raw[key] as string)
      : null;

  return {
    receivedAt: Date.now(),
    type,
    mint:
      value("mint") ||
      value("tokenAddress") ||
      value("address"),
    name: value("name"),
    symbol: value("symbol"),
    signature:
      value("signature") || value("sig"),
    rawType,
  };
}

function broadcast(event: PumpLiveEvent) {
  const hub = getHub();
  for (const listener of hub.listeners) {
    try {
      listener(event);
    } catch {
      // Never let one browser listener break the hub.
    }
  }
}

export function pumpConfigured() {
  return Boolean(
    process.env.PUMPPORTAL_API_KEY?.trim(),
  );
}

export function ensurePumpConnection() {
  const apiKey =
    process.env.PUMPPORTAL_API_KEY?.trim();

  if (!apiKey) return false;

  const hub = getHub();

  if (
    hub.socket?.readyState === WebSocket.OPEN ||
    hub.socket?.readyState === WebSocket.CONNECTING ||
    hub.connecting
  ) {
    return true;
  }

  hub.connecting = true;

  const socket = new WebSocket(
    `wss://pumpportal.fun/api/data?api-key=${encodeURIComponent(
      apiKey,
    )}`,
  );

  hub.socket = socket;

  socket.on("open", () => {
    hub.connecting = false;

    socket.send(
      JSON.stringify({
        method: "subscribeNewToken",
      }),
    );

    socket.send(
      JSON.stringify({
        method: "subscribeMigration",
      }),
    );
  });

  socket.on("message", (data) => {
    try {
      const raw = JSON.parse(
        data.toString(),
      ) as Record<string, unknown>;

      broadcast(normalizeEvent(raw));
    } catch {
      // Ignore malformed upstream messages.
    }
  });

  socket.on("error", () => {
    // close handler will schedule reconnect.
  });

  socket.on("close", () => {
    hub.connecting = false;
    hub.socket = null;

    if (
      hub.listeners.size > 0 &&
      !hub.reconnectTimer
    ) {
      hub.reconnectTimer = setTimeout(() => {
        hub.reconnectTimer = null;
        ensurePumpConnection();
      }, 3_000);
    }
  });

  return true;
}

export function subscribePump(listener: Listener) {
  const hub = getHub();
  hub.listeners.add(listener);
  ensurePumpConnection();

  return () => {
    hub.listeners.delete(listener);
  };
}

