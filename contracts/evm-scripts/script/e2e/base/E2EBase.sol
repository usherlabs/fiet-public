// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {DeployFullStackBase} from "./deploy/DeployFullStackBase.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ILiquidityHub} from "src/interfaces/ILiquidityHub.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Token} from "../../setup/MockERC20.s.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {GlobalConfig} from "src/GlobalConfig.sol";
import {VTSConfigs} from "src/libraries/VTSConfigs.sol";
import {MarketVTSConfiguration} from "src/types/VTS.sol";
import {IResilientOracle} from "src/interfaces/IResilientOracle.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {HookFlags} from "src/libraries/HookFlags.sol";
import {ProxyHook} from "src/ProxyHook.sol";

abstract contract E2EBase is DeployFullStackBase {
    struct CoreDeployment {
        FullStack stack;
    }

    struct StandaloneMarket {
        FullStack stack;
        bytes32 marketId; // core pool id (bytes32)
        address underlying0;
        address underlying1;
        address lcc0;
        address lcc1;
    }

    function _sort(address a, address b) internal pure returns (address lo, address hi) {
        return a < b ? (a, b) : (b, a);
    }

    function _configureMockOracle(address resilientOracle, address mainOracle, address asset) internal {
        IResilientOracle.TokenConfig memory cfg;
        cfg.asset = asset;
        cfg.oracles[uint256(IResilientOracle.OracleRole.MAIN)] = mainOracle;
        cfg.enableFlagsForOracles[uint256(IResilientOracle.OracleRole.MAIN)] = true;
        IResilientOracle(resilientOracle).getTokenConfig(asset); // touch interface
        // Using the mock's permissive API via low-level call (keeps E2EBase decoupled from mock type).
        (bool ok1,) =
            resilientOracle.call(abi.encodeWithSignature("setTokenConfig((address,address[3],bool[3],bool))", cfg));
        require(ok1, "oracle: setTokenConfig failed");
        // Prices are written to MAIN oracle (ResilientOracle reads MAIN.getPrice()).
        (bool ok2,) = mainOracle.call(abi.encodeWithSignature("setPrice(address,uint256)", asset, 1e18));
        require(ok2, "oracle: main setPrice failed");
    }

    /// @dev Deploy stack only (libraries + core contracts).
    function _deployCoreContracts() internal returns (CoreDeployment memory d) {
        d.stack = _deployAll();
    }

    /// @dev Create market (deploy underlyings + configure oracle + mine ProxyHook salt + createMarket + resolve LCCs).
    function _createMarket(CoreDeployment memory d, address lp) internal returns (StandaloneMarket memory m) {
        // Create market via GlobalConfig.proxyCall (MarketFactory is owned by GlobalConfig).
        vm.startBroadcast(_getDeployerPrivateKey());

        m.stack = d.stack;

        // Deploy two mock underlyings and mint to LP.
        Token t0 = new Token("E2E Token0", "E2E0", 0);
        Token t1 = new Token("E2E Token1", "E2E1", 0);
        t0.mint(lp, 1_000_000e18);
        t1.mint(lp, 1_000_000e18);

        // Sort assets for consistent market creation + getLCC lookups.
        (m.underlying0, m.underlying1) = _sort(address(t0), address(t1));

        // Configure mock oracle so MarketFactory.createMarket passes validateMarketOracles().
        _configureMockOracle(m.stack.contracts.resilientOracle, m.stack.contracts.mainOracle, m.underlying0);
        _configureMockOracle(m.stack.contracts.resilientOracle, m.stack.contracts.mainOracle, m.underlying1);

        MarketVTSConfiguration memory cfg = VTSConfigs.getDefaultConfig();
        // IMPORTANT: ProxyHook is deployed via CREATE2 from `MarketVaultDeployer`.
        // BaseHook validates the deployed hook address encodes the expected hook flags, so we must mine a salt.
        address marketVaultDeployer = MarketFactory(m.stack.contracts.marketFactory).marketVaultDeployer();
        (address expectedProxyHook, bytes32 salt) = HookMiner.find(
            marketVaultDeployer,
            HookFlags.PROXY_HOOK_FLAGS,
            type(ProxyHook).creationCode,
            abi.encode(config.poolManager, m.stack.contracts.marketFactory)
        );
        console.log("Expected ProxyHook:", expectedProxyHook);
        uint160 initialSqrtPriceX96 = 79228162514264337593543950336; // 1:1

        bytes memory ret = GlobalConfig(m.stack.contracts.globalConfig)
            .proxyCall(
                m.stack.contracts.marketFactory,
                abi.encodeWithSelector(
                    MarketFactory.createMarket.selector,
                    m.underlying0,
                    m.underlying1,
                    uint24(0), // fee
                    int24(60), // tickSpacing
                    initialSqrtPriceX96,
                    salt,
                    cfg
                )
            );

        // Decode returned PoolIds (abi-encoded as bytes32).
        (bytes32 corePoolIdBytes32,) = abi.decode(ret, (bytes32, bytes32));
        m.marketId = corePoolIdBytes32;

        // Resolve LCCs for the created market.
        ILiquidityHub hub = ILiquidityHub(m.stack.contracts.liquidityHub);
        m.lcc0 = hub.getLCC(m.marketId, m.underlying0);
        m.lcc1 = hub.getLCC(m.marketId, m.underlying1);
        require(m.lcc0 != address(0) && m.lcc1 != address(0), "market: LCCs not created");

        vm.stopBroadcast();
    }

    /// @dev Approve + wrap a single underlying into its LCC, minting the LCC to `to`.
    ///      Must be called inside a broadcast (i.e. after `vm.startBroadcast(...)`).
    function _wrapAndMintLcc(ILiquidityHub hub, bytes32 marketId, address underlying, address to, uint256 amount)
        internal
        returns (address lcc)
    {
        lcc = hub.getLCC(marketId, underlying);
        if (amount == 0) return lcc;

        IERC20(underlying).approve(address(hub), amount);
        hub.wrapTo(underlying, marketId, to, amount);
    }

    /// @dev Approve + wrap underlying into LCC for both assets, minting LCC to `to`.
    ///      Uses `_wrapAndMintLcc` under the hood so it can be reused elsewhere.
    ///      Must be called inside a broadcast (i.e. after `vm.startBroadcast(...)`).
    function _wrapAndMintLccPair(ILiquidityHub hub, StandaloneMarket memory m, address to, uint256 amount)
        internal
        returns (address lcc0, address lcc1)
    {
        lcc0 = _wrapAndMintLcc(hub, m.marketId, m.underlying0, to, amount);
        lcc1 = _wrapAndMintLcc(hub, m.marketId, m.underlying1, to, amount);
        console.log("lcc0:", lcc0);
        console.log("lcc1:", lcc1);
    }
}

