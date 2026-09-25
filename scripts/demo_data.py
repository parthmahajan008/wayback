# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Parth Mahajan

"""Generate a fictional Claude Code + Codex history for demos and README screenshots.

    python3 scripts/demo_data.py /tmp/wayback-demo
    WAYBACK_CLAUDE_DIR=/tmp/wayback-demo/claude WAYBACK_CODEX_DIR=/tmp/wayback-demo/codex \\
    WAYBACK_DATA=/tmp/wayback-demo/data  <run the backend>

Every project, person and conversation here is made up.
"""

from __future__ import annotations

import json
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

NOW = datetime.now(timezone.utc).replace(microsecond=0)
HOME = "/Users/demo/code"

# (tool, project, branch, days_ago, title, [(role, text-or-command), ...])
# role: "user" | "agent" | "$" (a shell command the agent ran)
SESSIONS = [
    ("claude", "payments-api", "fix/stripe-webhooks", 3, "Fix Stripe webhook signature failures", [
        ("user", "Stripe webhooks started failing with `No signatures found matching the expected signature for payload` after we added the JSON body parser. Can you figure out why?"),
        ("$", "rg -n \"express.json|bodyParser\" src/"),
        ("$", "sed -n '1,60p' src/routes/webhooks.ts"),
        ("agent", "Found it. `app.use(express.json())` is registered globally in `src/app.ts`, so by the time the request reaches `/webhooks/stripe` the raw body has already been parsed and re-serialized. Stripe signs the **exact raw bytes**, so `stripe.webhooks.constructEvent` can never match.\n\nFix: mount the webhook route with `express.raw({ type: 'application/json' })` *before* the global JSON parser:\n\n```ts\napp.post('/webhooks/stripe', express.raw({ type: 'application/json' }), stripeWebhookHandler);\napp.use(express.json());\n```"),
        ("user", "makes sense, do it and add a test"),
        ("$", "npm test -- webhooks"),
        ("agent", "Done. Moved the route above `express.json()` and added `webhooks.test.ts`, which signs a payload with a test secret via `stripe.webhooks.generateTestHeaderString` and asserts a 200. All 14 webhook tests pass. I also added a comment warning not to move the route below the JSON parser again."),
    ]),
    ("codex", "payments-api", "main", 9, "Add idempotency keys to refunds", [
        ("user", "Refunds are occasionally issued twice when the client retries on a timeout. Add idempotency."),
        ("$", "rg -n \"refunds.create\" src"),
        ("agent", "The refund endpoint calls `stripe.refunds.create` without an idempotency key, so a client retry after a 504 creates a second refund. I added an `Idempotency-Key` header requirement on `POST /refunds`, store the key with the response in a `refund_requests` table (unique index on `key`), and pass it through to Stripe as `idempotencyKey`. A retry with the same key now returns the stored response instead of refunding again."),
        ("user", "what TTL on the stored keys?"),
        ("agent", "24 hours, matching Stripe's own idempotency window. A nightly job deletes rows older than that (`DELETE FROM refund_requests WHERE created_at < now() - interval '24 hours'`)."),
    ]),
    ("claude", "web-dashboard", "chore/vite", 6, "Migrate the dashboard from webpack to Vite", [
        ("user", "Our webpack dev server takes 40s to start. Migrate web-dashboard to Vite."),
        ("$", "cat webpack.config.js package.json"),
        ("agent", "Plan:\n1. Add `vite` and `@vitejs/plugin-react`, remove webpack + 11 loaders.\n2. Move `public/index.html` to the root and point it at `/src/main.tsx`.\n3. Replace `process.env.REACT_APP_*` with `import.meta.env.VITE_*` (23 usages).\n4. Port the SVG loader to `vite-plugin-svgr` and the `@/` alias to `resolve.alias`."),
        ("$", "npx vite build"),
        ("agent", "Migration done. Cold dev start went from **41s to 1.8s**, HMR is near-instant, and the production bundle is 12% smaller. One gotcha: `moment` locales were being bundled wholesale, so I added `optimizeDeps.exclude` and a manual locale import."),
    ]),
    ("claude", "web-dashboard", "feat/dark-mode", 21, "Dark mode toggle with system preference", [
        ("user", "Add a dark mode toggle that defaults to the OS setting and remembers the user's choice."),
        ("agent", "I'll use CSS custom properties on `:root` with a `[data-theme=dark]` override, read `prefers-color-scheme` on first load, and persist an explicit choice in `localStorage`. To avoid a flash of the wrong theme, a tiny inline script in `index.html` sets `data-theme` before React hydrates."),
        ("$", "npm run test:visual -- --update-snapshots"),
        ("agent", "Shipped: `ThemeToggle` in the header (Light / Dark / System), tokens for 18 colors, and updated visual snapshots. Charts read their palette from the same tokens, so they switch too."),
    ]),
    ("codex", "infra", "fix/api-oom", 2, "Debug OOMKilled api pods", [
        ("user", "api pods keep getting OOMKilled every few hours in prod. memory limit is 512Mi."),
        ("$", "kubectl top pods -n prod -l app=api"),
        ("$", "kubectl describe pod api-7f9c6d-x2kq -n prod | grep -A3 'Last State'"),
        ("agent", "Memory climbs linearly from ~180Mi to 512Mi over ~3 hours, so this is a leak rather than a spike. Heap snapshots from staging show retained `Socket` objects growing: the websocket handler adds a `setInterval` heartbeat per connection but never clears it on `close`, so every disconnected client leaks its closure."),
        ("user", "nice catch. fix + should we raise the limit anyway?"),
        ("agent", "Fixed: `clearInterval(heartbeat)` in the `close` and `error` handlers, plus a regression test that opens and closes 1,000 sockets and asserts heap growth stays under 5 MB. I'd keep the limit at 512Mi and set requests to 256Mi. Raising the limit would only have hidden the leak for longer."),
    ]),
    ("claude", "infra", "chore/gha-cache", 13, "Speed up CI with dependency caching", [
        ("user", "CI takes 14 minutes, mostly npm install and docker builds. Can we cache?"),
        ("agent", "Three changes:\n- `actions/setup-node` with `cache: npm` (keyed on `package-lock.json`)\n- Docker layer cache via `docker/build-push-action` with `cache-from: type=gha` and `cache-to: type=gha,mode=max`\n- Split the Playwright job and cache `~/.cache/ms-playwright`"),
        ("$", "gh run list --workflow ci.yml --limit 5"),
        ("agent", "Median CI time dropped from 14m10s to **4m35s** across the last 5 runs. Cold-cache runs are about 9 minutes."),
    ]),
    ("codex", "ml-pipeline", "main", 5, "Fix flaky feature-store test", [
        ("user", "test_feature_backfill is flaky in CI, fails maybe 1 in 5 runs with a timeout"),
        ("$", "pytest tests/test_backfill.py -x --count 20 -p no:randomly"),
        ("agent", "It's a race. The test starts the backfill worker, then immediately polls Postgres for rows, but the worker commits in batches of 500 and the fixture only inserts 480. Sometimes the final partial batch lands after the 5s timeout. The worker only flushes partial batches on its 10s idle timer."),
        ("agent", "Fix: added `worker.flush()` in the test teardown path and made the idle flush interval configurable (`BACKFILL_FLUSH_SECONDS`, set to 0.5 in tests). 200 consecutive runs pass locally, and I removed the `@pytest.mark.flaky` retry decorator."),
    ]),
    ("claude", "ml-pipeline", "perf/slow-query", 17, "Speed up the daily metrics query", [
        ("user", "The daily_metrics job went from 2 minutes to 25 minutes this month. Can you look at the query?"),
        ("$", "psql $DATABASE_URL -c 'EXPLAIN (ANALYZE, BUFFERS) SELECT ...'"),
        ("agent", "The planner switched to a sequential scan on `events` (now 180M rows) because the filter is `date_trunc('day', created_at) = $1`, which can't use the btree index on `created_at`. Rewriting it as a range makes the index usable:\n\n```sql\nWHERE created_at >= $1 AND created_at < $1 + interval '1 day'\n```\n\nI also added a composite index on `(account_id, created_at)` for the GROUP BY."),
        ("agent", "Job runtime is now **48 seconds**. EXPLAIN shows an index-only scan with 99% of buffers hit."),
    ]),
    ("codex", "mobile-app", "feat/oauth", 11, "Add Sign in with Apple", [
        ("user", "Add Sign in with Apple to the iOS app next to the Google button"),
        ("agent", "I added `ASAuthorizationAppleIDProvider` with the `.fullName` and `.email` scopes. The identity token goes to our `/auth/apple` endpoint, which verifies it against Apple's JWKS (`https://appleid.apple.com/auth/keys`), checks `aud` equals our bundle ID, and upserts the user by the stable `sub`. Apple only sends the name on the *first* sign-in, so the client forwards it on that call and the server stores it."),
        ("$", "xcodebuild test -scheme App -destination 'platform=iOS Simulator,name=iPhone 17'"),
        ("agent", "Tests pass. Remember to enable the Sign in with Apple capability in the App Store Connect identifier, or TestFlight builds will fail with error 1000."),
    ]),
    ("claude", "payments-api", "feat/rate-limit", 26, "Rate limit the public API with Redis", [
        ("user", "We need per-API-key rate limiting on the public API, 100 req/min, returning proper headers."),
        ("agent", "I'll use a sliding-window counter in Redis: `ZADD` the request timestamp to `rl:{key}`, `ZREMRANGEBYSCORE` anything older than 60s, then `ZCARD`, all in one `MULTI` so it's atomic. Responses include `X-RateLimit-Limit`, `X-RateLimit-Remaining` and `Retry-After` on 429s."),
        ("$", "npm run test -- ratelimit && npx autocannon -c 50 -d 10 localhost:3000/v1/charges"),
        ("agent", "The load test shows exactly 100 accepted requests per minute per key and 429s after that, with p99 added latency of 0.7 ms. If Redis is down the limiter fails open and logs a warning, so an outage never blocks legitimate traffic."),
    ]),
    ("codex", "infra", "feat/terraform-s3", 33, "Terraform the uploads bucket", [
        ("user", "Move the uploads S3 bucket into terraform, it was created by hand"),
        ("$", "terraform import aws_s3_bucket.uploads acme-prod-uploads"),
        ("agent", "Imported the bucket and wrote `modules/uploads` with versioning, SSE-KMS encryption, a lifecycle rule moving objects to Glacier after 90 days, and `block_public_access` on all four settings. `terraform plan` now shows no drift apart from the encryption change, which is intentional."),
    ]),
    ("claude", "web-dashboard", "fix/table-perf", 8, "Virtualize the transactions table", [
        ("user", "The transactions page freezes with 20k rows. Fix the table performance."),
        ("agent", "React renders all 20k `<tr>` elements, about 180k DOM nodes. I switched the table body to `@tanstack/react-virtual`, which renders only the ~30 visible rows plus overscan, and memoized the row component. Sorting now runs in a Web Worker so the main thread stays responsive."),
        ("$", "npx playwright test perf/transactions.spec.ts"),
        ("agent", "Initial render went from 3.9s to 140ms, scrolling holds 60fps, and INP improved from 820ms to 90ms in the Playwright perf trace."),
    ]),
    ("codex", "ml-pipeline", "feat/retry", 40, "Retry flaky upstream API calls", [
        ("user", "the enrichment step fails the whole DAG when the vendor API returns 503. add retries"),
        ("agent", "I wrapped the vendor client in `tenacity` with exponential backoff and jitter (`wait_random_exponential(multiplier=1, max=30)`, `stop_after_attempt(6)`), retrying only on 429, 5xx and connection errors. Non-retryable 4xx errors fail fast, and each retry is logged with the attempt number."),
    ]),
    ("claude", "infra", "fix/cert-renewal", 45, "Fix expired TLS certificate on staging", [
        ("user", "staging.acme.dev cert expired and cert-manager didn't renew it. why?"),
        ("$", "kubectl describe certificate staging-tls -n ingress"),
        ("agent", "cert-manager's HTTP-01 challenge was failing because a new ingress rule redirected every HTTP request to HTTPS, including `/.well-known/acme-challenge/`. The ACME server got a 308 and gave up. I excluded the challenge path from the redirect and triggered a renewal with `cmctl renew staging-tls -n ingress`. The new cert is valid until December, and I added an alert for any certificate expiring within 14 days."),
    ]),
]


def ts(days_ago: float, minute: int) -> str:
    return (NOW - timedelta(days=days_ago) + timedelta(minutes=minute)).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def write_claude(root: Path, project: str, branch: str, days: int, title: str, turns) -> None:
    cwd = f"{HOME}/{project}"
    sid = str(uuid.uuid4())
    d = root / "projects" / cwd.replace("/", "-")
    d.mkdir(parents=True, exist_ok=True)
    lines = []
    for i, (role, text) in enumerate(turns):
        base = {"timestamp": ts(days, i * 3), "cwd": cwd, "sessionId": sid, "gitBranch": branch}
        if role == "user":
            lines.append({**base, "type": "user", "message": {"role": "user", "content": text}})
        elif role == "$":
            lines.append({**base, "type": "assistant", "message": {"role": "assistant", "content": [
                {"type": "tool_use", "id": f"toolu_{i}", "name": "Bash", "input": {"command": text}}]}})
        else:
            lines.append({**base, "type": "assistant", "message": {"role": "assistant", "content": [
                {"type": "text", "text": text}]}})
    lines.append({"type": "ai-title", "aiTitle": title, "sessionId": sid})
    (d / f"{sid}.jsonl").write_text("\n".join(json.dumps(x) for x in lines) + "\n")


def write_codex(root: Path, project: str, branch: str, days: int, title: str, turns) -> None:
    cwd = f"{HOME}/{project}"
    sid = str(uuid.uuid4())
    start = NOW - timedelta(days=days)
    d = root / "sessions" / start.strftime("%Y/%m/%d")
    d.mkdir(parents=True, exist_ok=True)
    lines = [{"timestamp": ts(days, 0), "type": "session_meta", "payload": {
        "id": sid, "timestamp": ts(days, 0), "cwd": cwd, "originator": "codex-tui", "source": "cli",
        "git": {"branch": branch}}}]
    for i, (role, text) in enumerate(turns):
        t = ts(days, i * 3 + 1)
        if role == "$":
            payload = {"type": "function_call", "name": "shell",
                       "arguments": json.dumps({"command": ["bash", "-lc", text]})}
        else:
            kind = "input_text" if role == "user" else "output_text"
            payload = {"type": "message", "role": "user" if role == "user" else "assistant",
                       "content": [{"type": kind, "text": text}]}
        lines.append({"timestamp": t, "type": "response_item", "payload": payload})
    name = f"rollout-{start.strftime('%Y-%m-%dT%H-%M-%S')}-{sid}.jsonl"
    (d / name).write_text("\n".join(json.dumps(x) for x in lines) + "\n")
    with open(root / "session_index.jsonl", "a") as fh:
        fh.write(json.dumps({"id": sid, "thread_name": title, "updated_at": ts(days, 30)}) + "\n")


def main() -> None:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "wayback-demo")
    claude, codex = out / "claude", out / "codex"
    codex.mkdir(parents=True, exist_ok=True)
    (codex / "session_index.jsonl").write_text("")
    for tool, project, branch, days, title, turns in SESSIONS:
        (write_claude if tool == "claude" else write_codex)(
            claude if tool == "claude" else codex, project, branch, days, title, turns)
    print(f"Wrote {len(SESSIONS)} demo sessions to {out}")


if __name__ == "__main__":
    main()
