# Endpoint-qualified rank rollout

Agent Tree ranks use Herdr's lexical token ordering. The format is
`h<16 lowercase hex>-<six-digit preorder rank>`. The prefix is a domain-separated SHA-256
truncation over the validated `/etc/machine-id` and canonical `HERDR_SOCKET_PATH`. It is
stable for subscriber restarts on one endpoint and distinguishes multiple Herdr sessions on
the same host. Neither input is published in a token. The 24-character format is below
Herdr's 80-character token-value limit; within one endpoint, zero-padded ranks preserve
preorder ordering.

Both identity inputs are required. If either is unavailable or invalid, the subscriber logs
a clear error, removes only its own branch/legacy/rank metadata when possible, and makes a
source-checked attempt to clear only its own view. A foreign view and foreign token sources
are preserved. It does not fall back to hostname or numeric-only ranks. The identity is
recomputed on every reconcile pass, so an identity failure after startup cannot leave stale
numeric ranks silently driving an active `tree` view.

## Upgrade and mixed-version behavior

On an upgraded endpoint, normal reconciliation rewrites prior six-digit ranks to the new
endpoint-qualified form. Existing release/clear cleanup removes ranks for panes that are no
longer owned. Deploy this update to every endpoint participating in a merged Agents panel.
During a mixed rollout, old numeric ranks sort lexically before the new `h...` ranks, and
old endpoints may continue colliding/interleaving with each other until each is upgraded.
The updated endpoint's own family remains ordered together under its common prefix, but this
is not a claim that a mixed-version merged panel is globally grouped.

## Live merged-client validation (2026-09-28)

Approved live dogfood in a desktop-wsl combined client validated two endpoint families: the
x1nano `herdr-agent-tree` root was immediately followed by its Task Worker, then the desktop
`ffsync` root was immediately followed by its Task Worker. The observed endpoint-qualified
ranks were `ha99dee8df1923c08-000001/000002` on x1nano and
`he4cfca619976c0cb-000001/000002` on desktop. This is live merged-client evidence, distinct
from isolated single-endpoint tests.

This validation covers those two endpoint families only; it does not establish global grouping
for a mixed-version panel. Cartlab was not upgraded, remains on the old 0.1.0 plugin, and had
no current agents, so it was not validated. Cross-endpoint correctness beyond the two observed
families still requires validation after the remaining rollout.
