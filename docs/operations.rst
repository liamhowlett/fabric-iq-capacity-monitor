Operations and validation
=========================

This is an experimental proof of concept. Read ``DISCLAIMER.rst`` before
operating it. See ``docs\testing.rst`` for recorded live outcomes and gaps;
repeat the relevant validation in your own environment.

Validation levels
-----------------

Run local checks without tenant side effects::

   .\tests\Test-Local.ps1

Local syntax, schema and synthetic classification tests are not deployment
validation. Prefix fixtures are synthetic unit checks only; they must never
be inserted into production telemetry or described as genuine AI activity.

After deployment, request fresh identifiable query activity and run live
validation::

   .\Test.ps1 -Config .\config.local.json -GenerateActivity

Check each level separately:

#. Deployment: expected owned resources, connection binding and model refresh
   succeed. Monitoring runtime state is ``Enabled`` where requested.
#. Collection: the Eventstream source and destination run, and real new
   capacity events arrive. ``Running`` alone is not evidence of delivery.
#. Query correlation: a fresh identifiable query appears in semantic logs and
   has a matching capacity event. End-to-end collection passes only after this
   match, not after either source independently produces data.
#. Genuine AI: perform a real Fabric IQ or Copilot interaction where available
   and inspect the resulting source metadata and correlated operation.
   This may require a manual user interaction. Ordinary DAX
   ``executeQueries`` activity is not an AI test and must not be labelled AI.
   A real MCP call may also use a different source prefix: the observed
   ``powerbi_mcp_server_ExecuteQuery_unknown`` route is not included in the
   approved ``fabricaihub_mcp_server`` detector. Do not inject a source label
   or silently broaden the detector to obtain a passing result.
#. Report: refresh the Import model and inspect coverage, recent operations
   and freshness indicators. Confirm that unmatched log rows retain blank CU
   rather than becoming zero.

If suitable query activity cannot be generated, a table is pending, or no
matching event arrives within the observation period, record that level as
pending or failed with the reason. Do not promote a partial test to a pass.
Use a brand-new MCAPS workspace before customer sharing. A successful smoke
test is not production certification or a security/compliance audit.

Reading the report
------------------

Overview includes ``About these numbers`` and should be read with the
Coverage/methodology page. Usage drivers compares whole-capacity activity with
the identified AI subset, not with all possible AI use. Operation details has
eight filters; choose ``Show activity`` then ``AI queries`` to include AI
query-log-only rows. Blank CU means unmeasured, not free.

Counts are engine operations, not questions or conversations. Execution
principals may be services, delegated users or other identities; they do not
establish who authored a question. Optional identity labels only improve
readability.

Freshness and refresh
---------------------

The model uses Import snapshots. Deployment requests one refresh; no scheduled
refresh is configured. If repeat refresh is required, the operator must review
credentials, access, cost and timing, then explicitly configure a supported
Fabric refresh schedule or request manual refreshes.

Check the model refresh result and feed/query-log watermarks independently.
``Data as of`` describes the snapshot, not the latest source event. Rolling
24-hour, 7-day and 28-day measures end at the latest feed-data hour, not wall
clock time. A recently refreshed model can still contain stale events.

Monitoring and Eventstream collection start without historical backfill.
Configured 30-day lookback and retention do not imply 30 days of observations.
Monitor the source inventory for pending tables, coverage gaps and incompatible
schemas, and check the health function before treating a quiet chart as low
usage.

KQL pipeline
------------

Seven functions separate the measurement stages:

* ``ObservabilitySettings``: deployment capacity, horizon and source count.
* ``ObservabilityIdentityMap``: optional operator-supplied identity labels.
* ``ObservabilityCharges``: capacity events deduplicated by source and event ID.
* ``ObservabilityStatements``: monitored query statements and AI source metadata.
* ``ObservabilityCapacity``: observed-hour SKU-based capacity budgets.
* ``ObservabilityRequests``: independently aggregated costs and statements
  joined using capacity, workspace, item and operation IDs.
* ``ObservabilityHealth``: coverage and data-quality diagnostics.

Do not join raw statement rows directly to charge rows and then sum CU:
multiple statements can multiply an operation's measured cost.

Recovery and partially failed installation
------------------------------------------

#. Keep ``config.local.json`` and ``.state\deployment.json`` private and intact.
   Deployment state records ownership, not tokens.
#. Read the failed step and verify the corresponding service operation before
   retrying, particularly after a timeout.
#. Correct the specific permission, API availability, schema or configuration
   issue. Do not widen unrelated permissions or use browser-only endpoints.
#. Rerun ``.\Deploy.ps1 -Config .\config.local.json`` with the same state.
   It resumes or updates owned resources; it does not adopt foreign resources
   just because their names match.
#. Repeat affected validation levels and the model refresh.

If state is lost, stop before redeploying or deleting resources and reconcile
ownership explicitly. Do not delete name-matching items as a shortcut.

The capacity subscription can stop after suspension or when its owner loses
subscription permission. Check that the selected capacity is running, the
subscription owner retains the required permission, and the source and
destination still deliver events. After recovery, check watermarks, event
replay and deduplication. Retention and service recovery windows limit what can
be recovered; a gap outside those windows must remain a documented gap.

For missing semantic logs, distinguish collection disabled, activity not yet
present, pending table, denied source access and missing required columns.
Check both the operator's query access and the target workspace identity's
read access. An empty source must not silently become zero AI.

Safe removal
------------

Preserve state until removal has completed. Review the owned resource list and
keep any required evidence in approved private storage. To remove tracked
deployment resources without requesting workspace deletion::

   .\Remove.ps1 -Config .\config.local.json -ConfirmWorkspaceName '<exact name>'

Workspace deletion is a separate, optional destructive step. Use it only for
an owned workspace newly created by this deployment, after checking that no
unrelated items or dependencies have been added::

   .\Remove.ps1 -Config .\config.local.json -DeleteWorkspace -ConfirmWorkspaceName '<exact name>'

Use the exact workspace name. Do not use this option for a pre-existing
workspace. The selected capacity, external monitoring sources and any reused
connection must be preserved. Deleting a new workspace removes its contents,
so resource ownership checks are not a substitute for reviewing the workspace.

For partial removal, keep the same state, inspect what remains and rerun
removal after correcting the failure. Verify in Fabric that owned resources
and ongoing ingestion have stopped as intended. Do not assume all costs stop
merely because the report or model was deleted.

Removal checks every tracked ownership marker before deleting any item.
Eventhouse and Monitoring deletion can cascade to dependent items: these
parents are not removed automatically without a saved completed-install
inventory, or when untracked items have since been added. Inspect dependent
resources before manually removing a parent from a partial installation.
Requesting deletion of a reused connection is refused before any item removal.
Removal requires the correct signed-in tenant, but does not require the
capacity to be active.

Folder placement is not an ownership marker. Removal still uses saved item
IDs and ownership checks, not the contents of a folder. Partial removal retains
the destination folder, whether newly created or explicitly reused; remove it
manually only when empty and no longer needed. Explicit deletion of an owned
workspace also deletes its folders. Keep the saved folder selection when
rerunning ``Deploy.ps1``; use ``-FolderOnly`` to organise without model refresh
or definition updates, as described in ``installation.rst``.

Data handling
-------------

Restrict workspace and connection access. Query text, UPNs, source metadata
and identity mappings can be sensitive. Review retention, exports and recovery
copies under the applicable data policy. Local configuration, runtime files
and state are ignored by Git, but that is not a security boundary. Do not
commit live screenshots, PDFs, backups, logs or exported telemetry.
