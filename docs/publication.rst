Publication and release review
==============================

Current position
----------------

The owner approved public publication on 5 November 2026 as an experimental
open-source sample, not a production-ready or supported monitoring product.
The owner chose the MIT License; ``LICENSE`` records Copyright (c) 2026
Liam Howlett. A clean demo
deployment, genuine Fabric IQ observation, four-page static screenshot review
and selected lifecycle exercises are recorded in ``testing.rst``, along with
the minor presentation issue and remaining coverage/lifecycle gaps. Public
availability does not close those gaps or certify customer suitability.
The repository URL is:

https://github.com/liamhowlett/fabric-iq-capacity-monitor

The owner's publication instruction authorises the initial commit, push and
public repository visibility for this package. It does not authorise changes
to deployed Fabric resources or claims of production readiness.

Intended public release
-----------------------

The owner selected public open source as the intended distribution on
5 November 2026. This is a preparation goal, not permission to change
visibility, publish a release or grant rights under an assumed licence.

On 5 November, the owner confirmed personal ownership and authority to release
the code and bundled artwork. This records the owner's confirmation; it is
not an independent legal assessment. The owner then explicitly selected MIT
and subsequently approved public publication with the recorded limitations.

Material covered by this release preparation includes:

* PowerShell, KQL, model and report definitions, theme and documentation.
* Six bundled PNG icons and four JPEG backgrounds, covered by the owner's
  rights confirmation.
* Any included or adapted third-party material must retain its applicable
  terms and attribution. Runtime prerequisites and Microsoft cloud services
  are not licensed by a licence added to this project.

The approved licence covers the project code, bundled artwork and documentation.
Keep local configuration, deployment state and raw telemetry exports out of
the release regardless of the licence selected. Selected demo screenshots are
included in the README; any further images require separate publication review.

Before customer sharing
-----------------------

#. Complete an installation in a brand-new isolated Fabric test workspace on
   the same existing capacity being measured. Review capacity impact and use
   an approved isolated test workload.
#. Record actual commands, dates, outcomes and remaining gaps in
   ``docs\testing.rst``. Separate local checks, deployment, event delivery,
   identifiable query correlation, report refresh and genuine AI interaction.
   Keep raw telemetry and private identifiers out of results summaries.
#. Review demo screenshots separately before publication. They can disclose
   resource names, operation IDs and execution identities. The README's demo
   images are not raw exports or proof of a different deployment's results.
#. Require fresh query activity in semantic logs and its matching capacity
   event before claiming end-to-end collection. Running components, generated
   synthetic prefix fixtures and ordinary DAX calls are not an AI roundtrip.
   A genuine Fabric IQ/Copilot interaction may need manual validation; state
   clearly if it has not been completed.
#. Test rerunning deployment with retained state and removing a partially
   deployed installation. Verify that unrelated resources and reused
   connections survive, and only an owned newly created workspace can be
   explicitly deleted.
#. Review permissions, costs, data handling, limitations and the claims made
   by every report page. A successful smoke test is not production
   certification. No security or compliance audit has been performed.
#. Obtain the owner's explicit licence choice and publication review before
   customer sharing, even if the repository remains private.

Before making the repository public
-----------------------------------

* Review all tracked files and Git history, not just the current tree. Remove
  or sanitise real identifiers, identities, private resource names, query text,
  configuration, state, runtime outputs, unapproved screenshots, PDFs, backups
  and live telemetry. If a credential was exposed, revoke it; deleting a file
  is not sufficient.
* Confirm that ignore rules cover local configuration, runtime files and
  state. They do not remove previously tracked content.
* Review included assets and dependencies for redistribution rights and
  licence compatibility. Confirm that ``LICENSE`` preserves the owner's MIT
  selection and correct copyright notice, and retain any third-party notices.
* Keep the AI disclosure prominent in the README and any customer-facing
  summary. Preserve the warnings that this is an experimental example, not
  an official Microsoft offering, billing tool or supported production
  monitoring product.
* Include the coverage limitations and known validation gaps. Do not describe
  synthetic unit tests as live AI tests or promise complete billing accuracy.
* Have the owner approve the final contents, licence, evidence and visibility
  change. This guide does not authorise changing visibility or distributing
  the repository.

Keep detailed live test artefacts in approved private storage. Publish a results
summary and only the demo images explicitly reviewed for public sharing.
