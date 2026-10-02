import {
  getXAutoStatus,
} from "@/lib/x-auto";

export const runtime =
  "nodejs";

export const dynamic =
  "force-dynamic";

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

  try {
    return Response.json({
      ok:
        true,
      ...(
        await getXAutoStatus()
      ),
    });
  } catch (error) {
    return Response.json(
      {
        ok:
          false,
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