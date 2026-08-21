# Public app split — in progress

The apps in `apps/` are being separated into their own repository,
https://github.com/spacewalk-labs/airlock-apps . Both copies exist today and this one is
still what the installers and tests read; the cutover has not happened.

`install/check-apps-divergence.py` is what keeps that honest: it fails when the two
`apps/` trees grow a new difference beyond the known path list, so the split cannot drift
quietly while it is half-done.
