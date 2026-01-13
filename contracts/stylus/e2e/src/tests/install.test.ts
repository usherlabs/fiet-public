import { describe, it } from "vitest";
import { loadEnv, buildKernelClient } from "../setup.js";

describe.skip("intent validator install/uninstall (live network)", () => {
  it("installs validator and reports initialized", async () => {
    const env = loadEnv();
    const { kernelClient } = await buildKernelClient(env);
    // A real test would call onInstall via a UserOp; placeholder for live e2e run.
    await kernelClient; // avoid unused variable lint
  });
});

