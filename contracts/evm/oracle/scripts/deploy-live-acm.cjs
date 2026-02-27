// Purpose: Deploy a fresh Venus AccessControlManager (ACM) and print its address.
//
// Operation:
// - This is a small Hardhat runtime script invoked by `just deploy-oracle` in MODE=LIVE.
// - It deploys `AccessControlManager` using the configured deployer account for the target network.
// - It prints `ACM_DEPLOYED_ADDRESS=<address>` so the caller can parse and inject it into the
//   downstream oracle deployment flow (without modifying `deploy/1-deploy-oracles.ts`).
//
// Notes:
// - Ownership/admin: Venus ACM uses OpenZeppelin AccessControl. The deployer EOA will hold
//   `DEFAULT_ADMIN_ROLE` after deployment, which matches the desired MODE=LIVE default.
// - This script intentionally does not write deployment manifests; the caller is responsible for
//   persisting the address as needed.

const hre = require("hardhat");

async function main() {
  const factory = await hre.ethers.getContractFactory("AccessControlManager");
  const acm = await factory.deploy();

  if (typeof acm.waitForDeployment === "function") {
    await acm.waitForDeployment();
  } else if (typeof acm.deployed === "function") {
    await acm.deployed();
  }

  let addr = acm.target || acm.address;
  if (!addr && typeof acm.getAddress === "function") {
    addr = await acm.getAddress();
  }
  if (!addr) {
    throw new Error("Failed to resolve deployed ACM address");
  }

  console.log(`ACM_DEPLOYED_ADDRESS=${addr}`);
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});

