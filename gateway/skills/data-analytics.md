---
name: Data Analytics
description: Set up product and business metrics (north star, funnels, retention, revenue), instrument events, build dashboards and analyze what to improve next
triggers: metrics, analytics, kpi, north star, dashboard, funnel, retention, cohort, conversion, activation, churn, a/b test, experiment, sql, posthog, mixpanel, amplitude, ga4, mrr, active users
---
Work like a startup's first data analyst: get the team measuring the right things from day one, then turn numbers into decisions.

1. **Pick the metrics.**
   - One **north star** that captures delivered value (e.g. weekly active teams that completed the core action), plus 3–5 input metrics the team can move this month.
   - The funnel from first touch to paying: visit → sign-up → activation (the "aha" moment, defined precisely) → retained (week 1 / week 4) → paying → referring.
   - Business: MRR/ARR, new vs expansion vs churned revenue, ARPA, CAC by channel, payback period, LTV:CAC, gross margin.
   - Guardrails: error rate, latency, support tickets, unsubscribes and refunds.
   For each metric write: name, exact definition, formula, data source, owner, target, and how often it's reviewed.
2. **Instrument it.** A tracking plan table: event name (`object_action`, e.g. `invoice_sent`), when it fires, properties (with types), and the user/account ids. Track server-side for anything money- or security-related. Default stack: PostHog (product analytics, funnels, feature flags, session replay) or Mixpanel/Amplitude; GA4 for marketing attribution; the production database or a warehouse (Postgres → BigQuery/Snowflake) for revenue. Respect consent and don't send personal data you don't need.
3. **Dashboards.** One page per audience: the founders' weekly (north star, funnel, revenue, top channel), growth (acquisition and activation by channel and cohort), product (feature adoption, retention curves). Every chart answers a question in its title.
4. **Analyze.**
   - Cohort retention curves (do they flatten? that's product-market fit signal), funnel drop-off by step and segment, activation by sign-up source.
   - Write the SQL you'd run, with comments, and say what result would change the plan.
   - Separate correlation from cause; check sample sizes and seasonality; beware averages hiding segments.
5. **Experiments.** Hypothesis ("If we X, metric Y improves by Z because…"), primary metric and guardrails, minimum detectable effect and the sample size/duration that implies, then a ship / iterate / kill call. No peeking-driven decisions.
6. **Weekly readout** in five lines: what moved, why we think it moved, what we'll do, what we stopped doing, and the one number to watch next week.

Always end with the next 1–3 actions for the team, each tied to a metric.
