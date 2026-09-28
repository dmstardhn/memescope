"use client";

import { AlertTriangle, RefreshCw } from "lucide-react";

export default function GlobalError({
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  return (
    <html>
      <body className="m-0 bg-[#080a0f] text-zinc-100">
        <div className="grid min-h-screen place-items-center p-6">
          <div className="w-full max-w-lg rounded-3xl border border-rose-400/15 bg-rose-400/5 p-8 text-center">
            <AlertTriangle className="mx-auto h-8 w-8 text-rose-300" />
            <h1 className="mt-4 text-2xl font-semibold">
              Something went wrong
            </h1>
            <p className="mt-2 text-sm leading-6 text-zinc-500">
              The terminal hit an unexpected client or server error.
              Your market data source may also be temporarily unavailable.
            </p>
            <button
              onClick={reset}
              className="mt-6 inline-flex items-center gap-2 rounded-xl bg-white px-4 py-2 text-sm font-medium text-black"
            >
              <RefreshCw className="h-4 w-4" />
              Try again
            </button>
          </div>
        </div>
      </body>
    </html>
  );
}
