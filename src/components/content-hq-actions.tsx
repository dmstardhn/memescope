"use client";

import {
  useState,
} from "react";

type Props = {
  id: number;
  initialCaption:
    string;
};

export function ContentActions({
  id,
  initialCaption,
}: Props) {
  const [
    caption,
    setCaption,
  ] =
    useState(
      initialCaption,
    );

  const [
    busy,
    setBusy,
  ] =
    useState(false);

  const [
    message,
    setMessage,
  ] =
    useState("");

  async function act(
    action: string,
    value?: string,
  ) {
    const key =
      window.localStorage.getItem(
        "memescope-content-hq-key",
      ) ??
      window.prompt(
        "Content HQ owner key",
      ) ??
      "";

    if (!key) {
      return;
    }

    window.localStorage.setItem(
      "memescope-content-hq-key",
      key,
    );

    setBusy(true);
    setMessage("");

    try {
      const response =
        await fetch(
          "/api/content-hq/action",
          {
            method:
              "POST",
            headers: {
              "content-type":
                "application/json",
              "x-content-hq-key":
                key,
            },
            body:
              JSON.stringify({
                action,
                id,
                value,
              }),
          },
        );

      const body =
        (await response.json()) as {
          ok?: boolean;
          message?: string;
          error?: string;
        };

      if (!response.ok) {
        throw new Error(
          body.error ??
            "Action failed.",
        );
      }

      setMessage(
        body.message ??
          "Done.",
      );

      window.setTimeout(
        () =>
          window.location.reload(),
        650,
      );
    } catch (error) {
      setMessage(
        error instanceof Error
          ? error.message
          : "Action failed.",
      );
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="mt-4 space-y-3">
      <textarea
        value={caption}
        onChange={(event) =>
          setCaption(
            event.target.value,
          )
        }
        className="min-h-28 w-full rounded-xl border border-white/10 bg-black/30 p-3 text-sm text-zinc-200 outline-none"
      />

      <div className="flex flex-wrap gap-2">
        <button
          disabled={busy}
          onClick={() =>
            void act(
              "approve",
            )
          }
          className="rounded-lg border border-emerald-400/30 px-3 py-2 text-xs text-emerald-200"
        >
          Approve
        </button>

        <button
          disabled={busy}
          onClick={() =>
            void act(
              "reject",
            )
          }
          className="rounded-lg border border-red-400/30 px-3 py-2 text-xs text-red-200"
        >
          Reject
        </button>

        <button
          disabled={busy}
          onClick={() =>
            void act(
              "regenerate",
            )
          }
          className="rounded-lg border border-white/10 px-3 py-2 text-xs text-zinc-200"
        >
          Regenerate Screenshot
        </button>

        <button
          disabled={busy}
          onClick={() =>
            void act(
              "caption",
            )
          }
          className="rounded-lg border border-white/10 px-3 py-2 text-xs text-zinc-200"
        >
          Next Caption
        </button>

        <button
          disabled={busy}
          onClick={() =>
            void act(
              "edit_caption",
              caption,
            )
          }
          className="rounded-lg border border-white/10 px-3 py-2 text-xs text-zinc-200"
        >
          Save Caption
        </button>

        <button
          disabled={busy}
          onClick={() =>
            void act(
              "publish",
            )
          }
          className="rounded-lg border border-sky-400/30 px-3 py-2 text-xs text-sky-200"
        >
          Publish Now
        </button>
      </div>

      {message ? (
        <div className="text-xs text-zinc-500">
          {message}
        </div>
      ) : null}
    </div>
  );
}