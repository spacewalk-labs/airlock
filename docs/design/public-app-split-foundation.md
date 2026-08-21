# Public app split — in progress

Live installers and tests still read this repository's `apps/`.
The public copy is https://github.com/spacewalk-labs/airlock-apps .
Cutover has not happened. `install/check-apps-divergence.py` fails
when the two `apps/` trees grow a new split past the known path list.
