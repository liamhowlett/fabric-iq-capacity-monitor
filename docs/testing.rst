Validation record
=================

Recorded on 4-5 November 2026 in an isolated demo tenant, using a new workspace
on an existing F64 capacity. No new capacity was provisioned. The original
monitoring installation was not used as the deployment target or removed.
This is evidence for an experimental AI-assisted proof of concept, not
production certification, a security audit or an accuracy guarantee.

Runtime state and raw telemetry exports are intentionally excluded from this
repository. The README includes owner-supplied screenshots from the clean-install demo,
which show demo resource names and execution identities.

Completed
---------

* The installer created the clean workspace, its identity, monitoring
  collection, observability Eventhouse/database, capacity Eventstream,
  shareable cloud connection, Import semantic model and four-page report.
* The connection used the workspace identity rather than a personal-credential
  fallback. Import refresh and model queries succeeded. Refresh scheduling
  remained off.
* A repeated installation retained all seven tracked resource IDs. It did
  not create a replacement set of items or connections.
* Fresh capacity-operation events arrived. A newly generated ordinary
  semantic query appeared in workspace logs and matched its capacity event.
* Independently aggregated charge and request CU totals reconciled. The AI
  and Other activity filters partitioned observed operations.
* Synthetic prefix fixtures passed. They were evaluated as query fixtures,
  not inserted into collected telemetry, and do not establish genuine AI use.
* The PBIR validator reported no structural errors or warnings for the four
  report pages. Local PowerShell, template, layout and private-data exclusion
  checks passed.

Real MCP source observation
---------------------------

A remote Power BI MCP ``ExecuteQuery`` call succeeded. Its unmodified
server-generated query metadata identified the operation as
``powerbi_mcp_server_ExecuteQuery_unknown``. The operation matched a capacity
event reporting 0.512 billable CU-seconds.

The approved detector identifies only sources beginning with
``fabricaihub_mcp_server``. It therefore correctly left this different MCP
source in ``Other workloads``. The detector was not broadened, and no source
metadata was injected to force a positive result.

This proves collection and matching for that MCP operation, not a positive
Fabric IQ classification. It is also direct evidence that this detector does
not cover every current MCP route. One operation's consumption is not a
representative performance or cost benchmark.

Owner-operated Fabric IQ observation
-----------------------------------

On 5 November, the owner requested a real answer against the clean-install
semantic model through Fabric IQ. QueryEnd records at 10:29 UTC contained the
unmodified source ``fabricaihub_mcp_server_AskPowerBI_Sydney``.

The deployed functions grouped twelve statements into one operation. Ten
statements matched the approved prefix; two helper statements carried the
source ``Copilot``. The operation was classified as ``AI queries`` without
changing the detector or injecting metadata.

At inspection, this operation had query logs but no matching capacity event.
Its billable CU remained null, not zero. The capacity was Active and the
capacity Eventstream source was Running, but its Eventhouse destination was
Paused. The latest landed capacity event was from 00:33 UTC, before the
interaction. No resumption or Import refresh was performed during this
read-only investigation.

This first inspection established genuine Fabric IQ collection and positive
classification. Capacity-event matching, measured CU and Import evidence were
still pending at that point.

After owner approval to resume this destination and refresh once, the granular
destination-resume API returned HTTP 404 (EntityNotFound). A subsequent topology
read still found the same destination in Paused state. No model refresh was
submitted during that attempt; the failed API request is not recorded as
successful recovery, and neither topology nor source configuration changed.

The owner subsequently resumed the destination manually. Live reads confirmed
Running state and new capacity events landing around 11:39 UTC. The original
10:29 operation's capacity events were recovered: eighteen deduplicated charge
rows totalled 6.576 billable CU-seconds. The operation matched its twelve query
statements without multiplying that consumption by the statement count.

Exactly one approved Import refresh completed at 11:40:42 UTC. Read-only DAX
queries against the refreshed model found exactly one row for the original
operation, with Is AI true, usage type AI queries, match status Matched and
6.576000 billable CU-seconds. The snapshot exposed one measured AI operation
and both activity-filter values. Scheduled refresh remained disabled.

An owner-provided screenshot at 12:17 UTC confirmed the clean-install report
with AI queries selected and the date range extended through 5 November. It
showed one observed AI operation, twelve statements, zero failed statements,
zero query operations without events, and the original operation's Matched
row with 6.6 billable CU-seconds (the rounded display of 6.576).

This closes the logs, positive classification, capacity matching, Import-model
and rendered AI-only operation-view evidence for this real interaction. It is
not a representative cost benchmark or proof that every AI route is covered.
Existing report date selections may need extending to include newly imported
operations.

Removal and preservation
------------------------

A separate disposable workspace was used for live removal exercises. It
contained an installer-owned semantic model, a deliberately untracked
sentinel model and a reference to the clean deployment's existing connection.

* Requesting deletion of the reused connection was refused before removing
  either model.
* Whole-workspace deletion was refused while the untracked sentinel existed.
* Partial removal deleted the owned model and preserved both the sentinel and
  the reused connection.
* Repeating partial removal succeeded with the owned model already absent.
* After explicitly removing only the temporary exercise sentinel, the owned
  exercise workspace was deleted. Its absence and the continued existence of
  the reused connection were confirmed.

Additional local fixtures covered changed ownership markers, untracked
parent-dependent items and missing inventory. Cascading deletion of a live
Monitoring item or Eventhouse was not exercised. Automatic parent removal
fails closed when the completed-install inventory is missing or new untracked
items have appeared.

Browser data review
-------------------

On 4 November, the report opened in the separate demo-account browser.
Browser text and accessibility reads returned the expected content on all four
pages: overview figures and workload bars, usage-driver values, operation
table rows, and snapshot/coverage diagnostics. The snapshot contained no
positively classified AI operations; empty AI breakdowns are not evidence of
a successful AI roundtrip.

This was not a completed visual/layout review. Element and viewport screenshot
capture timed out, so capture retries were stopped. A pointer click on the
activity slicer was intercepted by another slicer container; the AI-only
selection and its resulting visuals were not established. These observations
do not establish whether the interaction problem is specific to automation
or also affects normal browser use. No report definition was changed.

On 5 November, an owner-provided screenshot of the original monitoring report
showed the activity dropdown open with AI queries selected and populated AI
operation rows. That screenshot was not of the clean-install report, so it
does not close the clean-install interaction or genuine-AI evidence gaps.

A subsequent owner screenshot confirmed the clean-install report's activity
dropdown opens normally. It listed only Other workloads, consistent with the
snapshot's zero classified AI operations. The operation-details page showed
populated cards and table rows. The earlier pointer interception therefore
did not establish a general dropdown failure. After the Import refresh, the
12:17 screenshot confirmed AI queries was selectable and the matching
operation's cards and table row rendered consistently, as recorded above.

At 12:28 UTC, owner-provided screenshots covered the other three pages. The
overview displayed the AI operation, populated workload visuals, snapshot
timestamp and scope notes. Its whole-number headline rounded 6.576 CU-seconds
to 7; the one-decimal operation and driver values rounded the same amount to
6.6. This is display precision, not different measured consumption.

Usage drivers included 4-5 November and populated both whole-capacity and AI
charts; each AI breakdown showed 6.6 CU-seconds. Coverage and methodology used
the same dates with Workspace All and displayed populated diagnostics, snapshot
details and one Matched AI row at 6.6 CU-seconds. An initial concern that these
pages were filtered to 4 November only was not supported by the screenshots.

Independent static screenshot review found no blocking rendering or data
consistency issue. Minor truncation of overview trend timestamp labels was
noted. No report definition was changed or republished. This is a review of
the shown states, not exhaustive interaction or accessibility certification.
The README includes the owner-supplied clean-install report screenshots and
the folder view. Private resource inventories and raw telemetry exports remain
excluded.

Folder organisation
-------------------

On 5 November, the owner approved adding folder-aware deployment and organising
only the existing clean-install demo. ``Deploy.ps1 -FolderOnly -WhatIf`` issued
no writes. The folder-only run created the selected root folder and moved the
five owned top-level parents; Fabric moved their generated children with them.
All eleven workspace items were in the folder afterward, with the original
item-ID inventory unchanged and no workspace-root items remaining.

The Monitoring item remained Enabled and both capacity-feed endpoints remained
Running. The latest model refresh was still the earlier 11:40:42 UTC refresh
and scheduled refresh remained off. No definitions, bindings, permissions or
collection settings were changed. A repeated folder-only run retained the same
folder and item placements.

Local fixtures exercised new item folder IDs, explicit folder reuse, legacy
root deployment, ownership and inventory refusals, saved-folder changes,
child-move verification, no-write WhatIf and repeat organisation. Removal
fixtures retained the destination folder and reused connection. A completely
new live installation directly into a folder, nested reused destinations and
folder-aware removal have not been separately exercised live.

Outstanding
-----------

* Overview trend timestamp labels show minor truncation. Full interaction and
  accessibility coverage was not exercised. The generic smoke test's earlier
  ``GenuineFabricIqConversation: NotTested`` result is historical and separate
  from the owner-operated evidence recorded above.
* Additional monitoring-source configurations, a controlled capacity
  suspension/recovery exercise and live managed-parent removal have not been
  tested. The observed destination recovery above is narrower than a controlled
  suspension/recovery exercise.
* The owner confirmed rights to the code/artwork, selected MIT and approved
  public publication as an experimental sample. These outstanding gaps remain;
  publication is not production certification or a support commitment.

Reproduction
------------

Use the prerequisites and configuration in ``installation.rst``. In a new
isolated workspace, retain the same private state throughout these commands::

   .\tests\Test-Local.ps1
   .\Deploy.ps1 -Config .\config.local.json -WhatIf
   .\Deploy.ps1 -Config .\config.local.json
   .\Deploy.ps1 -Config .\config.local.json
   .\Test.ps1 -Config .\config.local.json -GenerateActivity

The second deployment exercises the resume/update path. Compare recorded
resource IDs before and after it; a successful command alone does not prove
idempotency. Follow ``operations.rst`` for removal, preserving unrelated
items and reused connections. Review cost and permissions before any live
exercise.
