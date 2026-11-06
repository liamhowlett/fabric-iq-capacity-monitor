Limitations and interpretation
==============================

This proof of concept was made with extensive generative AI assistance.
Code, classification assumptions and report measures can be wrong.
``DISCLAIMER.rst`` applies to every result. No security or compliance audit
has been performed, and a smoke test is not production certification.

AI coverage is partial
----------------------

Only query metadata whose ``sources[].Operation`` starts with
``fabricaihub_mcp_server``, case-insensitively, counts as AI. No particular
suffix is required. Application names, an identity, query text or an ordinary
DAX ``executeQueries`` call are not sufficient evidence of AI use.

The capacity feed covers the whole selected capacity. Semantic logs cover
only configured monitored workspaces and supported logged operations. The
identified AI subset is a lower bound. Missing sources, pending tables,
unmatched identifiers or changed metadata can reduce it further. Empty logs
are not proof of zero AI, and unclassified activity is not proven non-AI.

Monitoring is preview, subject to tenant rollout and schema differences.
There is no backfill, and relevant tables may appear only after activity.
Cross-workspace centralisation needs each source database and explicit read
permissions; monitoring does not automatically provide capacity-wide logs.
Source readiness and missing-column diagnostics must accompany usage figures.

Counts and attribution
----------------------

Request counts represent correlated engine operations, not prompts, chat
conversations or distinct business questions. A single interaction can cause
several engine operations.

An execution principal is not necessarily the question author. Optional
identity labels do not establish end-user attribution. The report does not
provide a reliable caller or question-author breakdown.

Capacity events are deduplicated by source and event ID. Costs and statements
are aggregated independently, then joined by capacity, workspace, item and
operation IDs. This avoids multiplying costs by statement count, but cannot
guarantee that every operation is logged or matched. Log-only rows have unknown
CU, not zero CU.

CU seconds are not a bill
-------------------------

Billable CU seconds describe Fabric compute represented in observed events.
They exclude Microsoft 365 credits, Cowork charges and Databricks currency
costs. They are not end-to-end AI billing, an invoice reconciliation, an audit
record or accurate real-time smoothed capacity metrics.

The hourly denominator is the observed SKU's CUs multiplied by 3,600, for hours
with observed events. A missing hour cannot distinguish powered-on idle
capacity from paused capacity or missed delivery. Full-hour budgeting makes
partial-hour percentages approximate. Do not interpret this denominator as
authoritative capacity uptime, purchased availability or invoiced utilisation.

Freshness and retention
-----------------------

The report is an Import snapshot, with scheduled refresh off by default.
``Data as of`` is not the latest event timestamp. Rolling 24-hour, 7-day and
28-day windows end at the latest feed-data hour, not wall clock time.
Collection delay, model refresh delay and source gaps are separate issues.

Lookback is not a guarantee of collected history. Monitoring has no backfill.
Subscription suspension, owner permission loss and replay can affect the feed.
Retention and upstream recovery windows constrain repairs; missing historical
events cannot be assumed recoverable. Local retention settings do not extend
Microsoft-managed monitoring retention.

Operational overhead and risk
-----------------------------

Eventstream, Eventhouse storage and queries, workspace monitoring and semantic
model refresh all consume resources. The monitor may dominate a small measured
AI workload. Compare overhead explicitly before drawing cost-saving conclusions.

The default fresh path reuses the measured capacity, not a new capacity. A
new workspace is not an independent compute sandbox and can affect existing
workloads. Source and destination region constraints still apply.

The Microsoft-managed monitoring Eventhouse is read-only telemetry. The custom
observability Eventhouse is a separate writable store. Existing legacy
monitoring must not be silently migrated or replaced.

Telemetry can expose UPNs, query text and business metadata. Restrict access
and review data policy and retention. Keep live configuration, state, exports,
PDFs and backups out of Git. The README includes selected demo screenshots;
additional screenshots need explicit publication review before inclusion.
Successful installation does not establish that these controls are sufficient
for a customer environment.
