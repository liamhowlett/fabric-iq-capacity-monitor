Experimental proof of concept
=============================

.. warning::

   I used generative AI extensively to help write the deployment scripts,
   queries and report. This is an experimental proof of concept, shared as an
   example of a measurement approach. AI-generated code and assumptions can be
   wrong. Review the code, permissions and costs, and test it in an isolated
   environment before use. It is not a production-ready monitoring product, an
   official Microsoft offering or a billing tool. No accuracy or support
   commitment is made.

No security or compliance audit has been performed. Installation, a refresh or
even a successful end-to-end smoke test is not production certification. The
owner must assess security, data protection, reliability, support and costs
before deciding whether any wider use is appropriate.

Figures are estimates from observed Fabric engine activity and the available
query logs. They do not measure every AI interaction, identify every question
author, establish an invoice, or provide an audit record. Missing data must not
be presented as zero usage. Review ``docs\limitations.rst`` with the report.

The monitor itself consumes Fabric compute and storage. Its overhead can
exceed the AI usage being measured. Query logs and exports may contain
sensitive identities, business data and query text. Apply appropriate access
controls, retention and data-handling rules.

The project code, bundled artwork and documentation are licensed under the
MIT License in ``LICENSE``. Runtime prerequisites and Microsoft cloud services
retain their own terms. The licence does not certify suitability, establish
support commitments or replace the warnings above.

Publication preparation is described in ``docs\publication.rst``. Recorded
demo outcomes and remaining gaps are described in ``docs\testing.rst``.
Assess the example in your own isolated environment before wider use.
