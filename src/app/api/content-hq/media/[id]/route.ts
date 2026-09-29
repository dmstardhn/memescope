import {
  getQueueMedia,
} from "@/lib/content-hq";

export const runtime =
  "nodejs";
export const dynamic =
  "force-dynamic";

export async function GET(
  _request: Request,
  context: {
    params:
      Promise<{
        id: string;
      }>;
  },
) {
  const {
    id,
  } = await context.params;

  const number =
    Number(id);

  if (
    !Number.isInteger(
      number,
    ) ||
    number <= 0
  ) {
    return new Response(
      "Invalid content id.",
      {
        status: 400,
      },
    );
  }

  const media =
    await getQueueMedia(
      number,
    );

  if (!media) {
    return new Response(
      "No media.",
      {
        status: 404,
      },
    );
  }

  return new Response(
    new Uint8Array(
      media.buffer,
    ),
    {
      headers: {
        "content-type":
          media.mime,
        "cache-control":
          "private, max-age=60",
      },
    },
  );
}