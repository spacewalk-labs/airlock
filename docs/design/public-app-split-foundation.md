# Public app split — in progress

The apps in `apps/` are being separated into their own repository,
https://github.com/spacewalk-labs/airlock-apps . Both copies exist today and this one is
still what the installers and tests read; the cutover has not happened.

The two `apps/` trees are allowed to differ: the mirror trailing this repository is the
designed state (`docs/tasks/active/apps-mirror-divergence-analysis.md` §0), so no gate
compares them any more.

`install/check-app-abi.sh` is what keeps the split honest: it keeps a package from
reaching into the platform tree at all. Before it
existed, ten packages resolved the platform root by climbing `$0/../..` and three
files read platform paths outside the D5 ABI — every one of which works today and
breaks the moment `apps/` is a separate repository. The contract's D5 section
records what changed; the gate is what keeps it changed.
