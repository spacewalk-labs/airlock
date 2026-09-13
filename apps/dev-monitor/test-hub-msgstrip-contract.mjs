// Compatibility entry point for the original hub-strip CI contract. The strip is no
// longer a private inline renderer: importing the shared contract executes the hub,
// Dev Monitor and iframe assertions together, including their common .ms-row output.
import './test-inbox-module-contract.mjs';
