/* eslint-disable no-console */
/**
 * Yarn v3 can fail if a workspace lifecycle script runs `yarn ...` during `yarn install`
 * (nested Yarn invocation before the node_modules state exists).
 *
 * Our `forge install` vendor dependency `lib/oracle` has:
 *   "postinstall": "yarn patch-package"
 *
 * This script rewrites it to:
 *   "postinstall": "patch-package"
 *
 * It is intentionally dependency-free (Node built-ins only) so it can run in `preinstall`.
 */
const fs = require("fs");
const path = require("path");

const oraclePkgPath = path.join(process.cwd(), "lib", "oracle", "package.json");

function patchPostinstall() {
  if (!fs.existsSync(oraclePkgPath)) {
    // Likely `forge install` hasn't been run yet; nothing to do.
    return;
  }

  const raw = fs.readFileSync(oraclePkgPath, "utf8");
  let pkg;
  try {
    pkg = JSON.parse(raw);
  } catch (err) {
    throw new Error(`Failed to parse ${oraclePkgPath} as JSON: ${err && err.message ? err.message : err}`);
  }

  const scripts = pkg && pkg.scripts ? pkg.scripts : null;
  const current = scripts && typeof scripts.postinstall === "string" ? scripts.postinstall : null;

  // Only touch the exact problematic value (avoid clobbering upstream changes).
  if (current !== "yarn patch-package") {
    console.log(`[patch-oracle] Already patched for lib/oracle postinstall`);
    return;
  }

  pkg.scripts.postinstall = "patch-package";
  fs.writeFileSync(oraclePkgPath, `${JSON.stringify(pkg, null, 2)}\n`);

  console.log(`[patch-oracle] Patched lib/oracle postinstall: "yarn patch-package" -> "patch-package"`);
}

function main() {
  patchPostinstall();
}

main();

