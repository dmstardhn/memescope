import {
  completeXOAuth,
} from "@/lib/x-auto";

export const runtime =
  "nodejs";

export const dynamic =
  "force-dynamic";

export async function GET(
  request: Request,
) {
  const url =
    new URL(
      request.url,
    );

  const error =
    url.searchParams.get(
      "error",
    );

  if (error) {
    return new Response(
      `X authorization failed: ${error}`,
      {
        status:
          400,
      },
    );
  }

  const code =
    url.searchParams.get(
      "code",
    );

  const state =
    url.searchParams.get(
      "state",
    );

  if (
    !code ||
    !state
  ) {
    return new Response(
      "Missing X OAuth code/state.",
      {
        status:
          400,
      },
    );
  }

  try {
    await completeXOAuth(
      code,
      state,
    );

    return new Response(
      `<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>MemeScope X Connected</title>
</head>
<body style="background:#050806;color:#e9f3ee;font-family:Arial,sans-serif;padding:48px">
<h1>MemeScope connected to X.</h1>
<p>Auto Post is ready.</p>
<p>09:00 WIB — Text Only</p>
<p>14:00 WIB — Best Unposted Result</p>
<p>20:00 WIB — Last 72 Hours</p>
<p>You can close this tab.</p>
</body>
</html>`,
      {
        headers: {
          "content-type":
            "text/html; charset=utf-8",
        },
      },
    );
  } catch (errorValue) {
    const message =
      errorValue instanceof
      Error
        ? errorValue.message
        : String(
            errorValue,
          );

    return new Response(
      message,
      {
        status:
          500,
      },
    );
  }
}