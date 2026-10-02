import {
  runXAutoSlot,
  type XAutoSlot,
} from "@/lib/x-auto";

export const runtime =
  "nodejs";

export const dynamic =
  "force-dynamic";

export const maxDuration =
  60;

const VALID_SLOTS:
  XAutoSlot[] = [
    "text",
    "result",
    "last72",
  ];

function authorized(
  request: Request,
) {
  const secret =
    process.env
      .CRON_SECRET
      ?.trim();

  return Boolean(
    secret &&
      request.headers.get(
        "authorization",
      ) ===
        `Bearer ${secret}`,
  );
}

export async function GET(
  request: Request,
) {
  if (
    !authorized(
      request,
    )
  ) {
    return Response.json(
      {
        ok:
          false,
        error:
          "Unauthorized.",
      },
      {
        status:
          401,
      },
    );
  }

  const url =
    new URL(
      request.url,
    );

  const slot =
    url.searchParams.get(
      "slot",
    ) as
      | XAutoSlot
      | null;

  if (
    !slot ||
    !VALID_SLOTS.includes(
      slot,
    )
  ) {
    return Response.json(
      {
        ok:
          false,
        error:
          "slot must be text, result, or last72.",
      },
      {
        status:
          400,
      },
    );
  }

  try {
    const result =
      await runXAutoSlot(
        slot,
      );

    return Response.json(
      result,
    );
  } catch (error) {
    return Response.json(
      {
        ok:
          false,
        slot,
        error:
          error instanceof
          Error
            ? error.message
            : String(
                error,
              ),
      },
      {
        status:
          500,
      },
    );
  }
}