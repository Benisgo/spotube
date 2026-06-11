# Spotube Multi-Session Relay

Cloudflare Workers relay for Spotube's multi-session feature.

This worker exposes:

- `POST /rooms`
- `POST /rooms/:CODE/join`
- `GET /rooms/:CODE`
- `GET /rooms/:CODE/ws?token=...`

It uses a Durable Object per room to coordinate queue, playback state, and member permissions.

## Deploy from GitHub

1. Create a Cloudflare account.
2. In Cloudflare, create an API token with Workers edit permissions.
3. Copy your Cloudflare Account ID.
4. In your GitHub repo, add these repository secrets:
   - `CLOUDFLARE_API_TOKEN`
   - `CLOUDFLARE_ACCOUNT_ID`
5. Push this repo to GitHub.
6. Run the `Multi-Session Worker` workflow, or push changes to `master`.

The workflow at [.github/workflows/multi-session-worker.yml](../../.github/workflows/multi-session-worker.yml) installs dependencies, runs tests, and deploys with Wrangler.

## First deploy

If you prefer deploying once manually before GitHub Actions:

```bash
cd workers/multi_session
npm install
npx wrangler login
npx wrangler deploy
```

Cloudflare will give you a URL like:

```text
https://spotube-multi-session.<your-subdomain>.workers.dev
```

Use that URL in Spotube:

`Settings -> Playback -> Multi-Session relay`

## Local development

```bash
cd workers/multi_session
npm install
npm test
npx wrangler dev
```

## Notes

- The relay keeps guest membership until the client sends a `leave` event or the room is ended by the host.
- Host can manage member permissions.
- Room state is stored in a SQLite-backed Durable Object namespace, which Cloudflare documents as supported on the Workers free plan with applicable limits:
  - Durable Objects overview: https://developers.cloudflare.com/durable-objects/
  - WebSocket server example: https://developers.cloudflare.com/durable-objects/examples/websocket-server/
