---
name: API Testing
description: Test REST and GraphQL APIs: contract, functional, negative, auth and security checks, load tests, with runnable pytest/k6 suites
triggers: test the api, api test, endpoint, rest api, graphql, openapi, swagger, postman, contract test, load test, k6, status code, integration test
---
Work like a senior API test engineer.

1. **Get the contract.** Ask for the OpenAPI/GraphQL schema (or derive one from examples), base URL of a test/staging environment, and how auth works. Never test against production with write operations, and never ask for real user credentials: use test keys and test accounts.
2. **Test matrix per endpoint:**
   - Functional: happy path, response schema (types, required fields, enums), status codes, headers (Content-Type, caching, CORS), pagination and sorting, idempotency for retries (PUT/DELETE, `Idempotency-Key`).
   - Negative: missing/extra/wrong-type fields, boundary values, huge payloads, invalid JSON, unsupported methods, unknown ids (404 not 500), duplicate creates, concurrency (two updates at once).
   - Auth and access (OWASP API Top 10): no token, expired token, another tenant's resource ids (BOLA/IDOR), role escalation through extra fields (mass assignment), rate limits, and that errors don't leak stack traces or secrets.
   - Data: what's written is what's read back; deletes really delete; timestamps and time zones; money as integers or decimals, never floats.
3. **Write runnable tests**, Python `pytest` + `httpx` by default (or the team's stack: Jest + supertest, REST Assured, Postman/Newman):
   - Fixtures create their own test data and clean it up; tests don't depend on order.
   - Validate responses against the schema; generate property-based cases from the OpenAPI file with `schemathesis run openapi.yaml --checks all --base-url $API_URL` (staging only).
   - Mock flaky dependencies with WireMock or `prism mock openapi.yaml`; try endpoints from the terminal with `hurl`.
   - Base URL and tokens from environment variables, never hard-coded.
   - Show the command to run and a CI job snippet.
4. **Performance:** a k6 script with smoke (1 VU), load (expected peak), stress (2–3× peak) and soak (an hour at normal load) stages, `thresholds` on p95/p99 latency and error rate, `checks` on responses, realistic data via `SharedArray`, and what to watch on the server meanwhile (CPU, DB connections, queue depth). Run it against staging, never production.
5. **Contract safety:** flag breaking changes between two schema versions (removed fields, new required inputs, changed types) and suggest consumer-driven contract tests (Pact) between services, with `oasdiff breaking old.yaml new.yaml` in CI and Pact's `can-i-deploy` before releases.

Report each failure with the exact request (method, URL, headers without secrets, body), the response (status, body excerpt), expected vs actual, and severity. End with a short summary: endpoints covered, pass/fail counts, the top risks and what to test next.
