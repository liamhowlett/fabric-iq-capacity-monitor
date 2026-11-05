Installation
============

Read ``DISCLAIMER.rst`` and ``docs\limitations.rst`` first. Use an isolated,
brand-new MCAPS workspace for pre-sharing validation. A fresh workspace does
not isolate its compute from other workloads on the same capacity.

Prerequisites
-------------

* PowerShell 7.4 or later and Azure CLI (``az``), available on the command path.
  No Python, Node.js, Power BI Desktop or Blender is required at install time.
* An existing, running Fabric capacity. For the default fresh setup, the
  deployment workspace must use the same capacity that supplies operation
  events. This also keeps source and destination in the same region.
* Capacity administrator permission to subscribe to
  ``FabricCapacityOperationEvents``, plus permission to create a workspace and
  assign it to the selected capacity.
* Permission to administer the target workspace, create its identity and
  items, and create or use the required shareable connection.
* Tenant access to the relevant Fabric APIs, Eventstream capacity events and
  workspace monitoring preview. Any required tenant settings must be reviewed
  and enabled by an authorised administrator, not by this installer.
* For external monitoring databases, explicit read/query access for both the
  operator performing source checks and the target workspace identity that
  reads data for the model. The installer does not grant access in existing
  source workspaces.

Do not grant broad tenant roles merely to bypass an error. Review the failed
operation and obtain the necessary scoped permission. Existing-workspace
deployment is supported, but is not a substitute for the required fresh test.

Local setup
-----------

Open PowerShell 7.4 or later in the repository root. Sign in to the intended tenant and
make the initial local configuration copy::

   az login --tenant <tenantId>
   Copy-Item .\config.example.json .\config.local.json

Do not overwrite an existing local configuration when resuming deployment.
Azure CLI retains the credentials in its own cache. Tokens must not be put in
configuration, deployment state or Git.

Configuration
-------------

Edit ``config.local.json``. Keep actual identifiers and identity mappings
local. The example is a template, not deployable tenant configuration.

``tenantId`` and ``capacityId``
   The tenant and existing capacity to use.

``createWorkspace``, ``workspaceName`` and ``workspaceId``
   Default: create a new workspace with the chosen name. To target an existing
   workspace, set ``createWorkspace`` to ``false`` and provide ``workspaceId``.
   Keep the name consistent with the intended workspace. A matching name is
   never permission to adopt an unrelated resource.

``prefix``
   Prefix for this deployment's items. Choose it before the first run and keep
   it with the same deployment state.

``folderName`` and ``folderId``
   Optional, mutually exclusive destination selections. The example uses
   ``folderName = Fabric IQ Monitor`` and an empty ``folderId`` to create a
   root-level folder in the target workspace. A same-name folder is not adopted:
   clear ``folderName`` and supply its ``folderId`` to reuse it explicitly.
   An existing folder may be nested. Empty or omitted selections preserve
   workspace-root deployment for older configurations.

   The folder ID and ownership are saved in deployment state. Keep the same
   selection on reruns; missing or renamed saved folders stop deployment rather
   than being silently replaced. The solution's items and generated children
   share the folder. External monitoring sources, workspace identities and cloud
   connections are not moved. Folders inherit workspace permissions and do not
   create separate compute or security boundaries. The folder-creation API is
   currently preview.

``lookbackDays``
   Query horizon, at least 28 days; default 30. A longer horizon does not create
   historical data that was never collected.

``retentionDays`` and ``cacheDays``
   Custom-store retention, at least ``lookbackDays`` and default 30 days;
   cache default 7 days. These do not override the Microsoft-managed
   monitoring store's retention or upstream recovery limits.

``monitoring.mode``
   ``Create`` by default: create and enable supported workspace monitoring in
   an installer-created new target workspace. For an existing workspace, select
   ``Existing`` or ``None`` rather than changing its monitoring enrolment.
   ``Existing``: reuse explicitly configured monitoring
   sources, including legacy monitoring. ``None``: no monitoring sources and
   no query-log-based AI coverage. ``Existing`` requires at least one source;
   ``None`` requires an empty source list.

``monitoring.sources``
   A list of objects with ``endpoint`` and ``database`` for existing monitoring
   KQL databases. It is empty by default. When centralising logs from several
   workspaces, list each source database; monitoring produces per-source KQL
   databases, not an automatically combined query-log database.

``identityMappings``
   Optional list of ``type``, ``value`` and ``label`` objects for local identity
   labels. Empty by default. Labels are not proof of the question author's
   identity and do not require automatic directory lookups.

``existingConnectionId``
   Optional existing shareable connection to reuse. The operator must ensure
   that its endpoint, authentication and permissions suit this deployment.
   Teardown must preserve a reused connection.

``stateFile``
   Default ``.state/deployment.json``. Retain the same file for retries,
   updates and cleanup. Do not commit it.

``operationTimeoutSeconds``
   Default 600 seconds for long-running operations. A timeout does not prove
   that the service failed to create the requested resource.

Deploy
------

Review the non-changing plan, then deploy::

   .\Deploy.ps1 -Config .\config.local.json -WhatIf
   .\Deploy.ps1 -Config .\config.local.json

The plan is not a successful cloud validation. The deployment uses public
REST APIs to create the owned items and configure:

#. A workspace identity, with Contributor access only in the target workspace.
   This is needed for monitoring data reads.
#. The selected destination folder, when configured. Newly created items include
   its ID in their creation requests.
#. Workspace monitoring when requested, plus a separate custom observability
   Eventhouse for writable capacity-event storage and KQL functions.
#. An Eventstream using ``FabricCapacityOperationEvents`` with compatibility
   version ``1.1``, targeting the existing selected capacity.
#. A ``WorkspaceIdentity`` AzureDataExplorer shareable connection, or the
   explicitly selected existing connection.
#. The Import semantic model and four-page report, model connection binding,
   and one model refresh request.

No tenant settings, source-workspace roles, capacity creation or resumption,
Operations Agent, Activator alerts or scheduled refresh are silently enabled.

Organise an existing installation
--------------------------------

Set ``folderName`` or ``folderId`` in the existing local configuration, then run::

   .\Deploy.ps1 -Config .\config.local.json -FolderOnly -WhatIf
   .\Deploy.ps1 -Config .\config.local.json -FolderOnly

This mode requires saved deployment state and the correct tenant, but does not
require an active capacity. It creates or explicitly reuses only the selected
folder and moves recorded owned parent items. Fabric moves children with their
parent; the script never moves a KQL database independently from its Eventhouse.
Resource IDs and report/model bindings are preserved. No definitions, collection
settings, permissions, capacity state or model refresh are changed.

Before moving existing Monitoring or Eventhouse parents, the script requires
the completed-install item inventory and refuses when new untracked items have
appeared. This conservative guard can also stop movement after unrelated items
were added elsewhere in a busy workspace. Reconcile ownership and dependencies
explicitly instead of bypassing the guard or adopting name-matching items.
Rerunning an already organised installation performs no duplicate folder
creation or item moves. A failure can leave completed moves in place; keep the
same state and folder selection when resuming.

Monitoring API and source readiness
-----------------------------------

The public Monitoring API is documented as of October 2026. Creation uses
``POST /v1/workspaces/{workspaceId}/monitoringItems`` with a ``MonitoringV1``
definition. Its ``dataCollectionSettings`` select
``sources.workspaceDiagnostics.mode = All`` and
``destinations.eventhouse.mode = Auto``. Collection is then enabled through
``POST .../monitoringItems/{id}/enableDataCollection``. The retrieved runtime
state must report ``Enabled``.

The automatically created monitoring Eventhouse is Microsoft-managed,
read-only telemetry. It is not the custom, writable observability Eventhouse.
Do not replace one with the other or attempt to write fixtures into it.
Existing legacy monitoring must be reused explicitly, never silently
migrated, deleted or replaced.

Preview rollout, unsupported API or permission failures must stop clearly.
Do not work around them with undocumented browser endpoints. Monitoring has
no backfill. ``SemanticModelLogs`` can be absent until suitable activity
occurs; source inventory must distinguish a pending table from a ready source.
Unreachable sources, denied query access and missing required columns need
diagnosis, not silent omission. An empty log result is not proof of zero AI.

Next steps and failures
-----------------------

Run ``.\Test.ps1 -Config .\config.local.json -GenerateActivity`` and follow
``docs\operations.rst``. A running source/destination or successful refresh
does not establish end-to-end collection or genuine AI classification.

If installation fails, preserve ``.state`` and the local configuration.
Inspect the failed step, resource ownership and service state, correct the
cause, and rerun Deploy with the same state. Do not start a second deployment
by deleting state. Cleanup is described in ``docs\operations.rst``.

Official references
-------------------

* `Create monitoring <https://learn.microsoft.com/en-us/rest/api/fabric/monitoring/items/create-monitoring>`_
* `Enable data collection <https://learn.microsoft.com/en-us/rest/api/fabric/monitoring/data-collection/enable>`_
* `Monitoring definition <https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/monitoring-definition>`_
* `Workspace monitoring overview <https://learn.microsoft.com/en-us/fabric/fundamentals/workspace-monitoring-overview>`_
* `Consume events through the Eventstream REST API <https://learn.microsoft.com/en-us/fabric/real-time-hub/consume-events-with-event-stream-rest-api>`_
* `Create connection <https://learn.microsoft.com/en-us/rest/api/fabric/core/connections/create-connection>`_
* `Bind semantic model connection <https://learn.microsoft.com/en-us/rest/api/fabric/semanticmodel/items/bind-semantic-model-connection>`_
* `Create folder <https://learn.microsoft.com/en-us/rest/api/fabric/core/folders/create-folder>`_
* `Move item and children <https://learn.microsoft.com/en-us/rest/api/fabric/core/items/move-item>`_
