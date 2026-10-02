import {
  buildXAuthorizeUrl,
} from "@/lib/x-auto";

export const runtime =
  "nodejs";

export const dynamic =
  "force-dynamic";

export async function GET() {
  const url =
    await buildXAuthorizeUrl();

  return Response.redirect(
    url,
    302,
  );
}