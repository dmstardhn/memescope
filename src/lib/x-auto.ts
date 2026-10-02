import crypto from "node:crypto";

import {
  buildXBestResultDraft,
  buildXLast72Draft,
  buildXTextOnlyDraft,
  xAutoContentSqlClient,
  type MemeScopeXAutoDraft,
} from "@/lib/content-hq-v5/content";

export type XAutoSlot =
  | "text"
  | "result"
  | "last72";

type XTokenPayload = {
  token_type?: string;
  expires_in?: number;
  access_token?: string;
  scope?: string;
  refresh_token?: string;
};

type XPostPayload = {
  data?: {
    id?: string;
    text?: string;
  };
  errors?: unknown;
};

type XMediaPayload = {
  data?: {
    id?: string;
    media_key?: string;
  };
  errors?: unknown;
};

function requiredEnv(
  name: string,
) {
  const value =
    process.env[
      name
    ]?.trim();

  if (!value) {
    throw new Error(
      `${name} is not configured.`,
    );
  }

  return value;
}

function clientId() {
  return requiredEnv(
    "X_CLIENT_ID",
  );
}

function clientSecret() {
  return requiredEnv(
    "X_CLIENT_SECRET",
  );
}

function redirectUri() {
  return (
    process.env
      .X_REDIRECT_URI
      ?.trim() ||
    "https://memescopes.vercel.app/api/x/callback"
  );
}

function basicAuth() {
  return Buffer.from(
    `${clientId()}:${clientSecret()}`,
    "utf8",
  ).toString(
    "base64",
  );
}

function base64Url(
  value: Buffer,
) {
  return value
    .toString(
      "base64",
    )
    .replace(
      /\+/g,
      "-",
    )
    .replace(
      /\//g,
      "_",
    )
    .replace(
      /=+$/g,
      "",
    );
}

function jakartaDateKey() {
  const parts =
    new Intl.DateTimeFormat(
      "en-US",
      {
        timeZone:
          "Asia/Jakarta",
        year:
          "numeric",
        month:
          "2-digit",
        day:
          "2-digit",
      },
    ).formatToParts(
      new Date(),
    );

  const get =
    (
      type:
        | "year"
        | "month"
        | "day",
    ) =>
      parts.find(
        (part) =>
          part.type ===
          type,
      )?.value ?? "";

  return `${get(
    "year",
  )}-${get(
    "month",
  )}-${get(
    "day",
  )}`;
}

export async function ensureXAutoSchema() {
  const sql =
    xAutoContentSqlClient();

  await sql`
    CREATE TABLE IF NOT EXISTS
      memescope_x_auth (
        id INTEGER PRIMARY KEY,
        access_token TEXT NOT NULL,
        refresh_token TEXT,
        expires_at TIMESTAMPTZ NOT NULL,
        scope TEXT,
        updated_at TIMESTAMPTZ
          NOT NULL DEFAULT NOW()
      )
  `;

  await sql`
    CREATE TABLE IF NOT EXISTS
      memescope_x_oauth_state (
        state TEXT PRIMARY KEY,
        code_verifier TEXT NOT NULL,
        expires_at TIMESTAMPTZ NOT NULL,
        created_at TIMESTAMPTZ
          NOT NULL DEFAULT NOW()
      )
  `;

  await sql`
    CREATE TABLE IF NOT EXISTS
      memescope_x_posts (
        id BIGSERIAL PRIMARY KEY,
        source_key TEXT
          NOT NULL UNIQUE,
        content_type TEXT
          NOT NULL,
        status TEXT
          NOT NULL DEFAULT
          'publishing',
        x_post_id TEXT,
        text_body TEXT,
        error_text TEXT,
        posted_at TIMESTAMPTZ,
        updated_at TIMESTAMPTZ
          NOT NULL DEFAULT NOW(),
        created_at TIMESTAMPTZ
          NOT NULL DEFAULT NOW()
      )
  `;

  await sql`
    CREATE INDEX IF NOT EXISTS
      memescope_x_posts_status_idx
    ON memescope_x_posts (
      status,
      content_type
    )
  `;

  await sql`
    DELETE FROM
      memescope_x_oauth_state
    WHERE
      expires_at <
      NOW()
  `;
}

export async function buildXAuthorizeUrl() {
  await ensureXAutoSchema();

  const sql =
    xAutoContentSqlClient();

  const state =
    crypto
      .randomBytes(
        24,
      )
      .toString(
        "hex",
      );

  const verifier =
    base64Url(
      crypto.randomBytes(
        48,
      ),
    );

  const challenge =
    base64Url(
      crypto
        .createHash(
          "sha256",
        )
        .update(
          verifier,
        )
        .digest(),
    );

  await sql`
    INSERT INTO
      memescope_x_oauth_state (
        state,
        code_verifier,
        expires_at
      )
    VALUES (
      ${state},
      ${verifier},
      NOW() +
        INTERVAL '10 minutes'
    )
  `;

  const params =
    new URLSearchParams({
      response_type:
        "code",
      client_id:
        clientId(),
      redirect_uri:
        redirectUri(),
      scope:
        [
          "tweet.read",
          "tweet.write",
          "users.read",
          "offline.access",
          "media.write",
        ].join(
          " ",
        ),
      state,
      code_challenge:
        challenge,
      code_challenge_method:
        "S256",
    });

  return (
    "https://x.com/i/oauth2/authorize?" +
    params.toString()
  );
}

async function tokenRequest(
  params: URLSearchParams,
) {
  const response =
    await fetch(
      "https://api.x.com/2/oauth2/token",
      {
        method:
          "POST",
        headers: {
          Authorization:
            `Basic ${basicAuth()}`,
          "Content-Type":
            "application/x-www-form-urlencoded",
        },
        body:
          params.toString(),
        cache:
          "no-store",
      },
    );

  const raw =
    await response.text();

  let payload:
    XTokenPayload = {};

  try {
    payload =
      JSON.parse(
        raw,
      ) as XTokenPayload;
  } catch {
    // handled below
  }

  if (
    !response.ok ||
    !payload.access_token
  ) {
    throw new Error(
      `X token request failed (${response.status}): ${raw}`,
    );
  }

  return payload;
}

async function storeTokens(
  token:
    XTokenPayload,
  fallbackRefresh?: string,
) {
  const access =
    token.access_token;

  if (!access) {
    throw new Error(
      "X access token missing.",
    );
  }

  const expiresIn =
    Math.max(
      60,
      Number(
        token.expires_in ??
          7200,
      ),
    );

  const refresh =
    token.refresh_token ??
    fallbackRefresh ??
    null;

  const expiresAt =
    new Date(
      Date.now() +
        expiresIn *
          1000,
    ).toISOString();

  const sql =
    xAutoContentSqlClient();

  await sql`
    INSERT INTO
      memescope_x_auth (
        id,
        access_token,
        refresh_token,
        expires_at,
        scope,
        updated_at
      )
    VALUES (
      1,
      ${access},
      ${refresh},
      ${expiresAt},
      ${token.scope ?? null},
      NOW()
    )
    ON CONFLICT (id)
    DO UPDATE SET
      access_token =
        EXCLUDED.access_token,
      refresh_token =
        EXCLUDED.refresh_token,
      expires_at =
        EXCLUDED.expires_at,
      scope =
        EXCLUDED.scope,
      updated_at =
        NOW()
  `;
}

export async function completeXOAuth(
  code: string,
  state: string,
) {
  await ensureXAutoSchema();

  const sql =
    xAutoContentSqlClient();

  const rows =
    await sql`
      DELETE FROM
        memescope_x_oauth_state
      WHERE
        state =
          ${state}
        AND expires_at >
          NOW()
      RETURNING
        code_verifier
    `;

  if (!rows.length) {
    throw new Error(
      "Invalid or expired X OAuth state.",
    );
  }

  const verifier =
    String(
      rows[0]
        .code_verifier ??
        "",
    );

  if (!verifier) {
    throw new Error(
      "X PKCE verifier missing.",
    );
  }

  const params =
    new URLSearchParams({
      grant_type:
        "authorization_code",
      code,
      redirect_uri:
        redirectUri(),
      code_verifier:
        verifier,
    });

  const token =
    await tokenRequest(
      params,
    );

  await storeTokens(
    token,
  );

  return true;
}

async function refreshAccessToken(
  refreshToken: string,
) {
  const params =
    new URLSearchParams({
      grant_type:
        "refresh_token",
      refresh_token:
        refreshToken,
    });

  const token =
    await tokenRequest(
      params,
    );

  await storeTokens(
    token,
    refreshToken,
  );

  if (
    !token.access_token
  ) {
    throw new Error(
      "X refresh returned no access token.",
    );
  }

  return token.access_token;
}

async function validAccessToken() {
  await ensureXAutoSchema();

  const sql =
    xAutoContentSqlClient();

  const rows =
    await sql`
      SELECT
        access_token,
        refresh_token,
        expires_at
      FROM
        memescope_x_auth
      WHERE
        id = 1
      LIMIT 1
    `;

  if (!rows.length) {
    throw new Error(
      "X account is not connected. Open /api/x/connect first.",
    );
  }

  const row =
    rows[0];

  const access =
    String(
      row.access_token ??
        "",
    );

  const refresh =
    String(
      row.refresh_token ??
        "",
    );

  const expiresAt =
    new Date(
      String(
        row.expires_at,
      ),
    ).getTime();

  if (
    access &&
    Number.isFinite(
      expiresAt,
    ) &&
    expiresAt >
      Date.now() +
        5 * 60 * 1000
  ) {
    return access;
  }

  if (!refresh) {
    throw new Error(
      "X refresh token is missing. Reconnect the X account.",
    );
  }

  return refreshAccessToken(
    refresh,
  );
}

async function uploadImage(
  accessToken: string,
  image: Buffer,
) {
  const response =
    await fetch(
      "https://api.x.com/2/media/upload",
      {
        method:
          "POST",
        headers: {
          Authorization:
            `Bearer ${accessToken}`,
          "Content-Type":
            "application/json",
        },
        body:
          JSON.stringify({
            media:
              image.toString(
                "base64",
              ),
            media_category:
              "tweet_image",
          }),
        cache:
          "no-store",
      },
    );

  const raw =
    await response.text();

  let payload:
    XMediaPayload = {};

  try {
    payload =
      JSON.parse(
        raw,
      ) as XMediaPayload;
  } catch {
    // handled below
  }

  const id =
    payload.data?.id;

  if (
    !response.ok ||
    !id
  ) {
    throw new Error(
      `X media upload failed (${response.status}): ${raw}`,
    );
  }

  return id;
}

async function createXPost(
  accessToken: string,
  text: string,
  mediaId?: string,
) {
  const body:
    Record<
      string,
      unknown
    > = {
      text,
    };

  if (mediaId) {
    body.media = {
      media_ids: [
        mediaId,
      ],
    };
  }

  const response =
    await fetch(
      "https://api.x.com/2/tweets",
      {
        method:
          "POST",
        headers: {
          Authorization:
            `Bearer ${accessToken}`,
          "Content-Type":
            "application/json",
        },
        body:
          JSON.stringify(
            body,
          ),
        cache:
          "no-store",
      },
    );

  const raw =
    await response.text();

  let payload:
    XPostPayload = {};

  try {
    payload =
      JSON.parse(
        raw,
      ) as XPostPayload;
  } catch {
    // handled below
  }

  const id =
    payload.data?.id;

  if (
    !response.ok ||
    !id
  ) {
    throw new Error(
      `X create post failed (${response.status}): ${raw}`,
    );
  }

  return {
    id,
    text:
      payload.data?.text ??
      text,
  };
}

async function createDraft(
  slot: XAutoSlot,
) {
  const dateKey =
    jakartaDateKey();

  if (
    slot ===
    "text"
  ) {
    return buildXTextOnlyDraft(
      dateKey,
    );
  }

  if (
    slot ===
    "result"
  ) {
    return buildXBestResultDraft();
  }

  return buildXLast72Draft(
    dateKey,
  );
}

async function claimDraft(
  draft:
    MemeScopeXAutoDraft,
) {
  const sql =
    xAutoContentSqlClient();

  const rows =
    await sql`
      INSERT INTO
        memescope_x_posts (
          source_key,
          content_type,
          status,
          text_body,
          updated_at
        )
      VALUES (
        ${draft.sourceKey},
        ${draft.contentType},
        'publishing',
        ${draft.text},
        NOW()
      )
      ON CONFLICT (
        source_key
      )
      DO UPDATE SET
        status =
          'publishing',
        text_body =
          EXCLUDED.text_body,
        error_text =
          NULL,
        updated_at =
          NOW()
      WHERE
        memescope_x_posts.status
          <> 'published'
      RETURNING
        source_key
    `;

  return (
    rows.length >
    0
  );
}

async function markPublished(
  sourceKey: string,
  postId: string,
) {
  const sql =
    xAutoContentSqlClient();

  await sql`
    UPDATE
      memescope_x_posts
    SET
      status =
        'published',
      x_post_id =
        ${postId},
      posted_at =
        NOW(),
      error_text =
        NULL,
      updated_at =
        NOW()
    WHERE
      source_key =
        ${sourceKey}
  `;
}

async function markFailed(
  sourceKey: string,
  error: string,
) {
  const sql =
    xAutoContentSqlClient();

  await sql`
    UPDATE
      memescope_x_posts
    SET
      status =
        'failed',
      error_text =
        ${error.slice(
          0,
          4000,
        )},
      updated_at =
        NOW()
    WHERE
      source_key =
        ${sourceKey}
  `;
}

export async function runXAutoSlot(
  slot: XAutoSlot,
) {
  await ensureXAutoSchema();

  const draft =
    await createDraft(
      slot,
    );

  if (!draft) {
    return {
      ok:
        true,
      slot,
      published:
        false,
      skipped:
        true,
      reason:
        "no-eligible-content",
    };
  }

  const claimed =
    await claimDraft(
      draft,
    );

  if (!claimed) {
    return {
      ok:
        true,
      slot,
      published:
        false,
      skipped:
        true,
      reason:
        "already-published",
      sourceKey:
        draft.sourceKey,
    };
  }

  try {
    const token =
      await validAccessToken();

    let mediaId:
      | string
      | undefined;

    if (draft.image) {
      mediaId =
        await uploadImage(
          token,
          draft.image,
        );
    }

    const post =
      await createXPost(
        token,
        draft.text,
        mediaId,
      );

    await markPublished(
      draft.sourceKey,
      post.id,
    );

    return {
      ok:
        true,
      slot,
      published:
        true,
      sourceKey:
        draft.sourceKey,
      xPostId:
        post.id,
    };
  } catch (error) {
    const message =
      error instanceof
      Error
        ? error.message
        : String(
            error,
          );

    await markFailed(
      draft.sourceKey,
      message,
    );

    throw error;
  }
}

export async function getXAutoStatus() {
  await ensureXAutoSchema();

  const sql =
    xAutoContentSqlClient();

  const auth =
    await sql`
      SELECT
        expires_at,
        scope,
        updated_at
      FROM
        memescope_x_auth
      WHERE
        id = 1
      LIMIT 1
    `;

  const posts =
    await sql`
      SELECT
        source_key,
        content_type,
        status,
        x_post_id,
        posted_at,
        error_text
      FROM
        memescope_x_posts
      ORDER BY
        created_at DESC
      LIMIT 10
    `;

  return {
    connected:
      auth.length >
      0,
    auth:
      auth.length
        ? {
            expiresAt:
              auth[0]
                .expires_at,
            scope:
              auth[0]
                .scope,
            updatedAt:
              auth[0]
                .updated_at,
          }
        : null,
    schedule: {
      timezone:
        "Asia/Jakarta",
      text:
        "09:00",
      result:
        "14:00",
      last72:
        "20:00",
    },
    recentPosts:
      posts,
  };
}