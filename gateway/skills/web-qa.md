---
name: Web QA
description: Test web apps end to end: test plans, exploratory charters, Playwright tests, accessibility and cross-browser checks
triggers: test the website, web app test, e2e test, end to end, playwright, cypress, selenium, regression test, smoke test, qa the site, cross-browser, accessibility test
---
Work like a senior QA engineer testing a web app.

1. **Understand what changed and who uses it.** Ask for the URL, the user flows that matter (sign-up, checkout, search…), browsers/devices, and test accounts only if you can't assume them. Never ask for real passwords: use test accounts.
2. **Look first, then act.** Before writing locators, open the page, wait for it to settle, take a screenshot and read the accessibility tree (`await page.locator('body').ariaSnapshot()`); pick selectors from what actually rendered. `npx playwright codegen <url>` bootstraps a flow.
3. **Risk-based test plan.** List the flows ranked by risk (money, data loss, auth, first impression). For each: happy path, edge cases (empty, long, unicode, slow network, double-click, back button, refresh mid-flow), error states and permissions.
4. **Write runnable tests**, Playwright + TypeScript by default:
   - `getByRole` / `getByLabel` locators, never brittle CSS or XPath; no fixed `waitForTimeout`, use web-first assertions.
   - One behaviour per test, a clear name (`checkout › rejects an expired card`), setup through the API when it's faster than the UI.
   - Include `playwright.config.ts` projects for Chromium, WebKit and Firefox, plus one mobile viewport.
   - Isolate every test: log in once in a setup project and reuse `storageState`; seed data through the API in fixtures (`test.extend`); stub third parties (payments, analytics, maps) with `page.route`.
   - Group long flows with `test.step`; use `expect.soft` for multi-field checks and `expect.poll` for backend state that settles later.
   - Fail the test on `pageerror`, console errors and unexpected 4xx/5xx responses (keep an allowlist).
   - Visual regression where layout matters: `await expect(page).toHaveScreenshot({ mask: [...] })`, run in a pinned Docker image so fonts match.
   - Flakiness: run new tests with `--repeat-each=10` before merging; in CI use `retries: 2` with `trace: 'on-first-retry'` and open it with `npx playwright show-trace`. Mark known failures with `test.fixme`, don't delete them.
   - CI: `npx playwright install --with-deps`, `--shard=1/4` plus `merge-reports`, tag smoke tests `@smoke` and run them with `--grep @smoke`; lint with `@typescript-eslint/no-floating-promises` and `tsc --noEmit` (a missing `await` is the most common flake).
   - Show how to run: `npx playwright test --project=chromium`, `--ui` to explore and `--debug` to step through.
5. **Always check:** accessibility (axe: `@axe-core/playwright`, keyboard-only navigation, focus order, contrast), console errors and failed network requests during the flow, responsive layout at 375/768/1280 px, and Core Web Vitals on the key pages (Lighthouse CI), and offline/slow network (`context.setOffline(true)`, CDP throttling).
6. **Exploratory charter** for what automation won't catch: "Explore <area> with <resources> to discover <risks>", 30–60 minutes, with notes to take.
7. **Bug reports** in this shape: title (what's broken, where), severity (blocker/critical/major/minor) and why, environment, steps to reproduce (numbered, minimal), expected vs actual, evidence (screenshot, trace, console/network log), and a suspected cause if you have one.

Practices adapted from Anthropic's `webapp-testing` skill and the Playwright best-practices guide.

Finish with a short **Release verdict**: ship / ship with known issues (list) / don't ship (blockers), and what you'd automate next.
