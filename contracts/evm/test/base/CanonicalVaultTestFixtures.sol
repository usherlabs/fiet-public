// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";

import {ICanonicalVault} from "../../src/interfaces/ICanonicalVault.sol";
import {Errors} from "../../src/libraries/Errors.sol";

import {MockERC20} from "../_mocks/MockERC20.sol";

/// @dev Minimal ERC6909 PoolManager mock for CanonicalVault custody paths.
contract MockPoolManagerCV is IERC6909Claims {
    mapping(address => mapping(uint256 => uint256)) internal _claimBalances;
    mapping(address => mapping(address => bool)) internal _operators;

    function setClaimBalance(address owner, Currency currency, uint256 amount) external {
        _claimBalances[owner][currency.toId()] = amount;
    }

    function balanceOf(address owner, uint256 id) external view returns (uint256) {
        return _claimBalances[owner][id];
    }

    function allowance(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function isOperator(address owner, address spender) external view returns (bool) {
        return _operators[owner][spender];
    }

    function transfer(address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    function burn(address from, uint256 id, uint256 amount) external {
        uint256 bal = _claimBalances[from][id];
        require(bal >= amount, "burn>bal");
        _claimBalances[from][id] = bal - amount;
    }

    function mint(address to, uint256 id, uint256 amount) external {
        _claimBalances[to][id] += amount;
    }

    function sync(Currency) external pure {}

    function settle() external payable returns (uint256 paid) {
        return msg.value;
    }

    function take(Currency currency, address to, uint256 amount) external {
        if (currency.isAddressZero()) {
            (bool ok,) = payable(to).call{value: amount}("");
            require(ok, "eth take failed");
        } else {
            MockERC20(Currency.unwrap(currency)).transfer(to, amount);
        }
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        _operators[msg.sender][operator] = approved;
        return true;
    }

    receive() external payable virtual {}
}

/// @dev Hub mock aligned with archived MarketVault unit tests + `issue` for LCC paths.
contract MockLiquidityHubCV {
    mapping(address => uint256) internal _queued;
    mapping(address => uint256) internal _reserveDirect;
    mapping(address => uint256) internal _reserveMarket;
    address internal _nativeSettleLcc;

    address public lastConfirmLcc;
    uint256 public lastConfirmAmount;
    bool public lastConfirmShouldEmit;
    uint256 public confirmCalls;

    address public lastCancelLcc;
    address public lastCancelFrom;
    uint256 public lastCancelAmount;
    uint256 public cancelCalls;

    address public lastQueueLcc;
    address public lastQueueRecipient;
    uint256 public lastQueueAmount;
    uint256 public queueCalls;

    function setTotalQueued(address lcc, uint256 amount) external {
        _queued[lcc] = amount;
    }

    function totalQueued(address lcc) external view returns (uint256) {
        return _queued[lcc];
    }

    function unfundedQueueOfUnderlying(address lcc) external view returns (uint256) {
        uint256 queued = _queued[lcc];
        uint256 reserve = _reserveMarket[lcc];
        return queued > reserve ? queued - reserve : 0;
    }

    function setReserve(address lcc, uint256 amount) external {
        _reserveDirect[lcc] = amount;
    }

    function setMarketReserve(address lcc, uint256 amount) external {
        _reserveMarket[lcc] = amount;
    }

    function confirmTake(address lcc, uint256 amount, bool shouldEmit) external virtual {
        lastConfirmLcc = lcc;
        lastConfirmAmount = amount;
        lastConfirmShouldEmit = shouldEmit;
        confirmCalls++;
    }

    function cancel(address lcc, address from, uint256 amount) external {
        lastCancelLcc = lcc;
        lastCancelFrom = from;
        lastCancelAmount = amount;
        cancelCalls++;
    }

    function queueForTransferRecipient(address lcc, address recipient, uint256 amount) external {
        lastQueueLcc = lcc;
        lastQueueRecipient = recipient;
        lastQueueAmount = amount;
        queueCalls++;
    }

    function setNativeSettleLcc(address lcc) external {
        _nativeSettleLcc = lcc;
    }

    function prepareSettle(address lcc, uint256 amount) external virtual {
        uint256 direct = _reserveDirect[lcc];
        if (amount > direct) {
            revert Errors.InsufficientLiquidityToSettle();
        }
        _reserveDirect[lcc] = direct - amount;
        if (lcc == _nativeSettleLcc) {
            (bool ok,) = payable(msg.sender).call{value: amount}("");
            require(ok, "native settle transfer failed");
        }
    }

    function issue(address, address, uint256) external virtual {}

    receive() external payable virtual {}
}

contract MockLiquidityHubRejectEthCV {
    mapping(address => uint256) internal _queued;
    mapping(address => uint256) internal _reserveDirect;
    mapping(address => uint256) internal _reserveMarket;

    function setTotalQueued(address lcc, uint256 amount) external {
        _queued[lcc] = amount;
    }

    function unfundedQueueOfUnderlying(address lcc) external view returns (uint256) {
        uint256 queued = _queued[lcc];
        uint256 reserve = _reserveMarket[lcc];
        return queued > reserve ? queued - reserve : 0;
    }

    function setMarketReserve(address lcc, uint256 amount) external {
        _reserveMarket[lcc] = amount;
    }

    function setReserve(address lcc, uint256 amount) external {
        _reserveDirect[lcc] = amount;
    }

    function confirmTake(address, uint256, bool) external {}

    function cancel(address, address, uint256) external {}

    function queueForTransferRecipient(address, address, uint256) external {}

    function prepareSettle(address lcc, uint256 amount) external {
        uint256 direct = _reserveDirect[lcc];
        if (amount > direct) {
            revert Errors.InsufficientLiquidityToSettle();
        }
        _reserveDirect[lcc] = direct - amount;
    }

    function issue(address, address, uint256) external {}

    receive() external payable {
        revert("reject");
    }
}

/// @dev Factory whose address is `marketFactory` on CanonicalVault; can register markets and answer `isMarketFacade` / `bounds`.
contract CanonicalTestFactory {
    address public liquidityHubAddr;
    address public canonical;
    address public vtsAddr;
    mapping(address => bool) internal _bound;
    mapping(bytes32 => mapping(address => bool)) internal _facade;

    function configure(address hub, address can, address vtsAddress) external {
        liquidityHubAddr = hub;
        canonical = can;
        vtsAddr = vtsAddress;
    }

    function liquidityHub() external view returns (address) {
        return liquidityHubAddr;
    }

    function canonicalVault() external view returns (address) {
        return canonical;
    }

    function bounds(address a) external view returns (bool) {
        return _bound[a];
    }

    function setBound(address a, bool v) external {
        _bound[a] = v;
    }

    function isMarketFacade(bytes32 m, address f) external view returns (bool) {
        return _facade[m][f];
    }

    function setMarketFacade(bytes32 m, address f, bool ok) external {
        _facade[m][f] = ok;
    }

    function vts() external view returns (address) {
        return vtsAddr;
    }

    function registerVaultMarket(
        address vault,
        bytes32 marketId,
        address facade,
        address lcc0,
        address lcc1,
        address underlying0,
        address underlying1
    ) external {
        ICanonicalVault(vault).registerMarket(marketId, facade, lcc0, lcc1, underlying0, underlying1);
    }
}
