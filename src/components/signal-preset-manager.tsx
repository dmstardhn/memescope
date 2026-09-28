"use client";

import {
  Check,
  Save,
  Trash2,
} from "lucide-react";
import {
  useEffect,
  useMemo,
  useState,
} from "react";

const STORAGE_KEY =
  "memescope-signal-parameter-presets-v1";

export type SignalPresetValues = {
  minSignalScore: number;
  minLiquidityUsd: number;
  maxPairAgeHours: number;
};

type SignalPreset = {
  id: string;
  name: string;
  createdAt: number;
  values: SignalPresetValues;
};

function moneyCompact(
  value: number,
) {
  if (value <= 0) {
    return "Any";
  }

  if (value >= 1_000_000) {
    return `$${(
      value / 1_000_000
    ).toFixed(
      value % 1_000_000 === 0
        ? 0
        : 1,
    )}M+`;
  }

  if (value >= 1_000) {
    return `$${(
      value / 1_000
    ).toFixed(
      value % 1_000 === 0
        ? 0
        : 1,
    )}K+`;
  }

  return `$${value}+`;
}

function ageLabel(
  hours: number,
) {
  if (hours <= 0) {
    return "Any";
  }

  if (hours < 24) {
    return `${hours}h max`;
  }

  if (
    hours % 24 === 0
  ) {
    return `${hours / 24}d max`;
  }

  return `${hours}h max`;
}

function sameValues(
  a: SignalPresetValues,
  b: SignalPresetValues,
) {
  return (
    a.minSignalScore ===
      b.minSignalScore &&
    a.minLiquidityUsd ===
      b.minLiquidityUsd &&
    a.maxPairAgeHours ===
      b.maxPairAgeHours
  );
}

export function SignalPresetManager({
  settings,
  onApply,
}: {
  settings: SignalPresetValues;
  onApply: (
    values: SignalPresetValues,
  ) => void;
}) {
  const [presets, setPresets] =
    useState<SignalPreset[]>(
      [],
    );

  const [name, setName] =
    useState("");

  const [message, setMessage] =
    useState("");

  useEffect(() => {
    try {
      const raw =
        localStorage.getItem(
          STORAGE_KEY,
        );

      if (!raw) {
        return;
      }

      const parsed =
        JSON.parse(raw) as unknown;

      if (
        Array.isArray(parsed)
      ) {
        setPresets(
          parsed
            .filter(
              (
                item,
              ): item is SignalPreset =>
                Boolean(
                  item &&
                    typeof item ===
                      "object",
                ),
            )
            .slice(0, 20),
        );
      }
    } catch {
      // Ignore malformed local storage.
    }
  }, []);

  function persist(
    next: SignalPreset[],
  ) {
    const trimmed =
      next.slice(0, 20);

    setPresets(trimmed);

    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify(trimmed),
    );
  }

  function saveCurrent() {
    const cleanName =
      name.trim();

    if (!cleanName) {
      setMessage(
        "Enter a preset name first.",
      );

      return;
    }

    const values: SignalPresetValues =
      {
        minSignalScore:
          settings.minSignalScore,

        minLiquidityUsd:
          settings.minLiquidityUsd,

        maxPairAgeHours:
          settings.maxPairAgeHours,
      };

    const existing =
      presets.findIndex(
        (preset) =>
          preset.name.toLowerCase() ===
          cleanName.toLowerCase(),
      );

    const record: SignalPreset =
      {
        id:
          existing >= 0
            ? presets[existing].id
            : `${Date.now()}-${Math.random()
                .toString(36)
                .slice(2, 8)}`,

        name: cleanName,

        createdAt:
          Date.now(),

        values,
      };

    let next: SignalPreset[];

    if (existing >= 0) {
      next =
        presets.map(
          (preset, index) =>
            index === existing
              ? record
              : preset,
        );

      setMessage(
        `Updated preset "${cleanName}".`,
      );
    } else {
      next = [
        record,
        ...presets,
      ];

      setMessage(
        `Saved preset "${cleanName}".`,
      );
    }

    persist(next);
    setName("");
  }

  function removePreset(
    id: string,
  ) {
    const next =
      presets.filter(
        (preset) =>
          preset.id !== id,
      );

    persist(next);
    setMessage(
      "Preset deleted.",
    );
  }

  const currentPresetId =
    useMemo(() => {
      const match =
        presets.find(
          (preset) =>
            sameValues(
              preset.values,
              settings,
            ),
        );

      return match?.id ?? null;
    }, [
      presets,
      settings,
    ]);

  return (
    <section className="mb-5 rounded-2xl border border-white/10 bg-white/[0.02] p-4">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <div className="flex items-center gap-2">
            <Save className="h-4 w-4 text-cyan-300" />

            <h2 className="text-sm font-semibold text-white">
              Saved Signal Parameters
            </h2>
          </div>

          <p className="mt-1 text-[11px] leading-5 text-zinc-600">
            Save your current Score, Liquidity and Pair Age filters as reusable presets.
          </p>
        </div>

        <div className="flex w-full max-w-md gap-2 sm:w-auto">
          <input
            value={name}
            onChange={(event) =>
              setName(
                event.target.value,
              )
            }
            onKeyDown={(event) => {
              if (
                event.key ===
                "Enter"
              ) {
                saveCurrent();
              }
            }}
            placeholder="Preset name, e.g. Early Gem"
            className="min-w-0 flex-1 rounded-xl border border-white/10 bg-black/20 px-3 py-2 text-xs text-white outline-none placeholder:text-zinc-700 focus:border-cyan-400/25 sm:w-52"
          />

          <button
            type="button"
            onClick={
              saveCurrent
            }
            className="flex shrink-0 items-center gap-2 rounded-xl border border-cyan-400/20 bg-cyan-400/[0.06] px-3 py-2 text-xs text-cyan-300 hover:bg-cyan-400/10"
          >
            <Save className="h-3.5 w-3.5" />
            Save
          </button>
        </div>
      </div>

      <div className="mt-4 rounded-xl border border-white/5 bg-black/20 px-3 py-2">
        <div className="flex flex-wrap items-center gap-x-5 gap-y-2 text-[11px]">
          <span className="text-zinc-700">
            Current
          </span>

          <span className="text-zinc-300">
            Score{" "}
            <strong className="font-medium text-white">
              {settings.minSignalScore}+
            </strong>
          </span>

          <span className="text-zinc-300">
            Liq{" "}
            <strong className="font-medium text-white">
              {moneyCompact(
                settings.minLiquidityUsd,
              )}
            </strong>
          </span>

          <span className="text-zinc-300">
            Age{" "}
            <strong className="font-medium text-white">
              {ageLabel(
                settings.maxPairAgeHours,
              )}
            </strong>
          </span>
        </div>
      </div>

      {presets.length > 0 ? (
        <div className="mt-4 grid gap-2 lg:grid-cols-2 2xl:grid-cols-3">
          {presets.map(
            (preset) => {
              const active =
                currentPresetId ===
                preset.id;

              return (
                <div
                  key={
                    preset.id
                  }
                  className={`rounded-xl border p-3 ${
                    active
                      ? "border-emerald-400/20 bg-emerald-400/[0.04]"
                      : "border-white/5 bg-black/20"
                  }`}
                >
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <div className="flex items-center gap-2">
                        <div className="truncate text-xs font-medium text-zinc-200">
                          {
                            preset.name
                          }
                        </div>

                        {active && (
                          <span className="inline-flex items-center gap-1 rounded-md bg-emerald-400/10 px-1.5 py-0.5 text-[8px] uppercase tracking-[0.1em] text-emerald-300">
                            <Check className="h-2.5 w-2.5" />
                            Active
                          </span>
                        )}
                      </div>

                      <div className="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-[10px] text-zinc-600">
                        <span>
                          Score{" "}
                          {
                            preset
                              .values
                              .minSignalScore
                          }+
                        </span>

                        <span>
                          Liq{" "}
                          {moneyCompact(
                            preset
                              .values
                              .minLiquidityUsd,
                          )}
                        </span>

                        <span>
                          Age{" "}
                          {ageLabel(
                            preset
                              .values
                              .maxPairAgeHours,
                          )}
                        </span>
                      </div>
                    </div>

                    <button
                      type="button"
                      onClick={() =>
                        removePreset(
                          preset.id,
                        )
                      }
                      className="rounded-lg p-1.5 text-zinc-700 hover:bg-red-400/[0.06] hover:text-red-300"
                      aria-label={`Delete ${preset.name}`}
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </button>
                  </div>

                  <button
                    type="button"
                    onClick={() => {
                      onApply(
                        preset.values,
                      );

                      setMessage(
                        `Applied preset "${preset.name}".`,
                      );
                    }}
                    className={`mt-3 w-full rounded-lg border px-3 py-2 text-[10px] font-medium ${
                      active
                        ? "border-emerald-400/15 bg-emerald-400/[0.05] text-emerald-300"
                        : "border-white/10 text-zinc-400 hover:bg-white/5 hover:text-white"
                    }`}
                  >
                    {active
                      ? "Currently applied"
                      : "Apply preset"}
                  </button>
                </div>
              );
            },
          )}
        </div>
      ) : (
        <div className="mt-4 rounded-xl border border-dashed border-white/10 px-4 py-5 text-center text-xs text-zinc-700">
          No saved parameter presets yet.
        </div>
      )}

      {message && (
        <div className="mt-3 text-[10px] text-zinc-600">
          {message}
        </div>
      )}

      <div className="mt-3 text-[9px] leading-4 text-zinc-700">
        Presets are stored locally in this browser in V1.
      </div>
    </section>
  );
}