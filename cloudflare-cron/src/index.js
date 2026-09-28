export default {
  async scheduled(controller, env, ctx) {
    const response = await fetch(
      "https://memescopes.vercel.app/api/telegram/cron",
      {
        method: "GET",
        headers: {
          Authorization: `Bearer ${env.CRON_SECRET}`,
          "User-Agent": "MemeScope-Cloudflare-Cron"
        }
      }
    );

    const body = await response.text();

    console.log(
      "MemeScope recorder:",
      response.status,
      body.slice(0, 1000)
    );

    if (!response.ok) {
      throw new Error(
        `MemeScope cron returned ${response.status}: ${body}`
      );
    }
  }
};