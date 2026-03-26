import hre from "hardhat";
import { DeployFunction } from "hardhat-deploy/dist/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

const SEQUENCER: Record<string, string> = {
  arbitrumone: "0xFdB631F5EE196F0ed6FAa767959853A9F217697D",
  opmainnet: "0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389",
};

const readAddress = (key: string, fallback: string): string => {
  const value = process.env[key];
  if (!value || value.trim().length === 0) {
    return fallback;
  }
  return hre.ethers.utils.getAddress(value.trim());
};

const func: DeployFunction = async function ({
  deployments,
  getNamedAccounts,
  network,
}: HardhatRuntimeEnvironment) {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();

  const proxyOwnerAddress = readAddress("ORACLE_PROXY_OWNER_ADDRESS", deployer);
  const oracleOwnerAddress = readAddress("ORACLE_OWNER_ADDRESS", proxyOwnerAddress);
  const nativeMarketAddress = readAddress("ORACLE_NATIVE_MARKET_ADDRESS", hre.ethers.constants.AddressZero);
  const vaiAddress = readAddress("ORACLE_VAI_ADDRESS", hre.ethers.constants.AddressZero);

  const defaultProxyAdmin = await hre.artifacts.readArtifact(
    "hardhat-deploy/solc_0.8/openzeppelin/proxy/transparent/ProxyAdmin.sol:ProxyAdmin",
  );

  const acmDeployment = await deploy("AccessControlManager", {
    from: deployer,
    log: true,
    deterministicDeployment: false,
    skipIfAlreadyDeployed: true,
    args: [],
  });

  await deploy("BoundValidator", {
    from: deployer,
    log: true,
    deterministicDeployment: false,
    skipIfAlreadyDeployed: true,
    args: [],
    proxy: {
      owner: proxyOwnerAddress,
      proxyContract: "OptimizedTransparentUpgradeableProxy",
      execute: {
        methodName: "initialize",
        args: [acmDeployment.address],
      },
      viaAdminContract: {
        name: "DefaultProxyAdmin",
        artifact: defaultProxyAdmin,
      },
    },
  });

  const boundValidator = await hre.ethers.getContract("BoundValidator");

  await deploy("ResilientOracle", {
    from: deployer,
    log: true,
    deterministicDeployment: false,
    skipIfAlreadyDeployed: true,
    args: [nativeMarketAddress, vaiAddress, boundValidator.address],
    proxy: {
      owner: proxyOwnerAddress,
      proxyContract: "OptimizedTransparentUpgradeableProxy",
      execute: {
        methodName: "initialize",
        args: [acmDeployment.address],
      },
      viaAdminContract: {
        name: "DefaultProxyAdmin",
        artifact: defaultProxyAdmin,
      },
    },
  });

  const sequencer = SEQUENCER[network.name];
  const mainOracleName = sequencer !== undefined ? "SequencerChainlinkOracle" : "ChainlinkOracle";
  await deploy(mainOracleName, {
    contract: mainOracleName,
    from: deployer,
    log: true,
    deterministicDeployment: false,
    skipIfAlreadyDeployed: true,
    args: sequencer ? [sequencer] : [],
    proxy: {
      owner: proxyOwnerAddress,
      proxyContract: "OptimizedTransparentUpgradeableProxy",
      execute: {
        methodName: "initialize",
        args: [acmDeployment.address],
      },
      viaAdminContract: {
        name: "DefaultProxyAdmin",
        artifact: defaultProxyAdmin,
      },
    },
  });

  const resilientOracle = await hre.ethers.getContract("ResilientOracle");
  const mainOracle = await hre.ethers.getContract(mainOracleName);

  if (!network.live) {
    const accessControlManager = await hre.ethers.getContract("AccessControlManager");
    await accessControlManager.giveCallPermission(mainOracle.address, "setTokenConfig(TokenConfig)", deployer);
    await accessControlManager.giveCallPermission(resilientOracle.address, "setTokenConfig(TokenConfig)", deployer);
  }

  const resilientOracleOwner = await resilientOracle.owner();
  const mainOracleOwner = await mainOracle.owner();
  const boundValidatorOwner = await boundValidator.owner();

  if (oracleOwnerAddress !== deployer && resilientOracleOwner === deployer) {
    await resilientOracle.transferOwnership(oracleOwnerAddress);
    console.log(`Ownership of ResilientOracle transfered from deployer to ${oracleOwnerAddress}`);
  }

  if (oracleOwnerAddress !== deployer && mainOracleOwner === deployer) {
    await mainOracle.transferOwnership(oracleOwnerAddress);
    console.log(`Ownership of ${mainOracleName} transfered from deployer to ${oracleOwnerAddress}`);
  }

  if (oracleOwnerAddress !== deployer && boundValidatorOwner === deployer) {
    await boundValidator.transferOwnership(oracleOwnerAddress);
    console.log(`Ownership of BoundValidator transfered from deployer to ${oracleOwnerAddress}`);
  }
};

export default func;
func.tags = ["deploy"];
