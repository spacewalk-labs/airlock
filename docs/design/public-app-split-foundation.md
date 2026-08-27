# Public app split — in progress

The apps in `apps/` are being separated into their own repository,
https://github.com/spacewalk-labs/airlock-apps . Both copies exist today and this one is
still what the installers and tests read; the cutover has not happened.

`install/check-apps-divergence.py` is what keeps that honest: it fails when the two
`apps/` trees grow a new difference beyond the known path list, so the split cannot drift
quietly while it is half-done.

`install/check-app-abi.sh` is the other half of that honesty, and it faces the
opposite way: divergence keeps the two `apps/` trees from drifting apart, while
this keeps a package from reaching into the platform tree at all. Before it
existed, ten packages resolved the platform root by climbing `$0/../..` and three
files read platform paths outside the D5 ABI — every one of which works today and
breaks the moment `apps/` is a separate repository. The contract's D5 section
records what changed; the gate is what keeps it changed.
