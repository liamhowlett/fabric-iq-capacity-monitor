Fabric IQ capacity monitor proof of concept
===========================================

Experimental measurement of Fabric compute associated with identifiable AI
queries, using capacity operation events and workspace semantic model logs.

.. warning::

   I used generative AI extensively to help write the deployment scripts,
   queries and report. This is an experimental proof of concept, shared as an
   example of a measurement approach. AI-generated code and assumptions can be
   wrong. Review the code, permissions and costs, and test it in an isolated
   environment before use. It is not a production-ready monitoring product, an
   official Microsoft offering or a billing tool. No accuracy or support
   commitment is made.

The project code, bundled artwork and documentation are licensed under the
MIT License; see ``LICENSE``. Runtime prerequisites and Microsoft cloud
services retain their own terms. Licensing does not change the experimental
status or the warnings above.

A clean demo deployment, repeated install and selected removal exercises
are recorded in ``docs\testing.rst``. One owner-operated Fabric IQ operation
was positively classified, matched to capacity consumption and verified in the
refreshed Import model and rendered AI-only operation view. All four report
pages have been reviewed in owner-provided screenshots, with a minor overview
axis-label truncation noted. Broader coverage/lifecycle exercises remain
incomplete; this is not comprehensive validation or production certification.

What it measures
----------------

* A public Eventstream capacity-operation feed for one existing capacity.
* Query logs from the configured monitored workspaces, correlated to capacity
  events by capacity, workspace, item and operation identifiers.
* AI identification only when a query's ``sources[].Operation`` begins with
  ``fabricaihub_mcp_server``, case-insensitively.
* Billable Fabric CU seconds, operation counts and coverage diagnostics.
  Counts represent engine operations, not prompts or chat conversations.

The capacity feed covers the capacity, but query logs cover only configured
workspaces. Identified AI usage is therefore a lower bound, not all AI use.
An execution identity is not necessarily the person who asked the question.
Missing or unmatched CU is unknown, not zero.

Installation at a glance
------------------------

Use PowerShell 7.4 or later and Azure CLI. Installation does not require Python,
Node.js, Power BI Desktop or Blender. Use an isolated, new workspace on the
same existing capacity being measured. The subscription requires capacity
administrator permission; no capacity is created or resumed.

The example configuration creates a ``Fabric IQ Monitor`` folder for the
solution's items and generated children. To reuse an existing folder, clear
``folderName`` and set ``folderId`` explicitly. Empty or omitted selections
retain workspace-root deployment. Folders organise items; they do not isolate
workspace permissions or capacity usage. The folder-creation API is preview.

Run from the repository root. Copy the example only for the first setup, then
edit the local configuration before deploying::

   az login --tenant <tenantId>
   Copy-Item .\config.example.json .\config.local.json
   .\Deploy.ps1 -Config .\config.local.json -WhatIf
   .\Deploy.ps1 -Config .\config.local.json
   .\Test.ps1 -Config .\config.local.json -GenerateActivity

Read ``docs\installation.rst`` before running these commands. The installer
uses supported public APIs, creates a target workspace identity and a shareable
connection, binds the Import model and requests one refresh. Scheduled refresh
is off. Monitoring is a preview feature and collection has no backfill.

Rerun deployment with the same configuration and ``.state`` to resume or
update. Do not delete the state directory or replace it with a fresh file to
recover from a failure. Matching names do not authorise adoption of resources.

To organise an already completed installation without redeploying definitions
or refreshing the model, select a folder in the same local configuration and run::

   .\Deploy.ps1 -Config .\config.local.json -FolderOnly -WhatIf
   .\Deploy.ps1 -Config .\config.local.json -FolderOnly

Only recorded owned parents are moved; Fabric moves their generated children
with them. Existing external monitoring sources and cloud connections stay put.
Retain the saved installation inventory; unknown items block parent moves.

Report
------

The report has four pages:

* Overview, including ``About these numbers``.
* Usage drivers, comparing all-capacity activity with identified AI.
* Operation details, with eight filters. ``Show activity`` then ``AI queries``
  includes log-only rows; a blank CU value is not zero.
* Coverage/methodology, for missing data and interpretation.

The Import snapshot is not a live meter. ``Data as of`` is not the latest event
time. Rolling 24-hour, 7-day and 28-day views end at the latest feed-data hour,
not the current clock time.

Read before use
---------------

* ``DISCLAIMER.rst``: AI disclosure and suitability warning.
* ``LICENSE``: MIT reuse terms and warranty disclaimer.
* ``docs\installation.rst``: prerequisites, configuration and supported setup.
* ``docs\operations.rst``: validation, refresh, recovery and safe removal.
* ``docs\limitations.rst``: accounting, coverage, security and cost limitations.
* ``docs\publication.rst``: private testing and release gates.

No security or compliance audit has been performed. A successful smoke test
would not certify production readiness. Telemetry can contain UPNs and query
text; restrict access and do not commit live exports, state or configuration.
