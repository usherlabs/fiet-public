// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ERC165} from "openzeppelin-contracts/contracts/utils/introspection/ERC165.sol";
import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
import {INativeSettlementReceiver} from "./interfaces/INativeSettlementReceiver.sol";
import {Errors} from "./libraries/Errors.sol";

/// @title MMQueueCustodian
/// @notice One queue custodian per beneficiary: Hub queue owner for that MM domain; actual LCC and underlying balances
///         on this contract are the receivable state (no shadow ledger).
/// @dev `COLLECT_AVAILABLE_LIQUIDITY` settles when needed, then `release` credits the locker
///      through `MMPositionManager` pull flows (`TAKE`), not direct beneficiary push payout from this contract.
contract MMQueueCustodian is IMMQueueCustodian, ERC165, INativeSettlementReceiver {
    /// @notice Underlying released to the position manager after settlement paths deliver underlying to this custodian.
    event UnderlyingReleasedToManager(address indexed lcc, uint256 amount);

    address public immutable override positionManager;
    address public immutable override beneficiary;

    modifier onlyPositionManager() {
        if (msg.sender != positionManager) revert Errors.InvalidSender();
        _;
    }

    /// @dev Accept native underlying from `LiquidityHub` settlement for native-backed LCC markets.
    receive() external payable {}

    constructor(address _positionManager, address _beneficiary) {
        if (_positionManager == address(0) || _positionManager.code.length == 0) {
            revert Errors.InvalidAddress(_positionManager);
        }
        if (_beneficiary == address(0)) revert Errors.InvalidAddress(_beneficiary);
        positionManager = _positionManager;
        beneficiary = _beneficiary;
    }

    /// @inheritdoc INativeSettlementReceiver
    function supportsNativeSettlementFromFiet() external pure override returns (bool) {
        return true;
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(INativeSettlementReceiver).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IMMQueueCustodian
    function totalQueuedLcc(address lcc) external view override returns (uint256) {
        return IERC20(lcc).balanceOf(address(this));
    }

    /// @inheritdoc IMMQueueCustodian
    /// @notice Hub `unwrap` as this contract: shortfall queues to `address(this)`; immediate underlying is forwarded to `forwardUnderlyingTo`.
    /// @dev `MMPM` must transfer `amount` LCC to this contract before calling. Canonical Hub: `ILCC(lcc).hub()`.
    function unwrapLcc(address lcc, address forwardUnderlyingTo, uint256 amount) external onlyPositionManager {
        if (amount == 0) return;
        if (forwardUnderlyingTo == address(0)) revert Errors.InvalidAddress(forwardUnderlyingTo);

        ILiquidityHub hub = ILiquidityHub(ILCC(lcc).hub());

        address underlying = ILCC(lcc).underlying();
        uint256 uBalBefore =
            underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));

        uint256 qBefore = hub.settleQueue(lcc, address(this));
        hub.unwrap(lcc, amount);
        uint256 queuedDelta = hub.settleQueue(lcc, address(this)) - qBefore;

        if (queuedDelta > 0) {
            uint256 bal = IERC20(lcc).balanceOf(address(this));
            if (bal < queuedDelta) revert Errors.InsufficientBalance(bal, queuedDelta);
        }

        uint256 uBalAfter =
            underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));
        uint256 immediateReceived = uBalAfter - uBalBefore;

        if (immediateReceived > 0) {
            Currency.wrap(underlying).transfer(forwardUnderlyingTo, immediateReceived);
        }
    }

    /// @inheritdoc IMMQueueCustodian
    function release(address lcc, uint256 amount) external override onlyPositionManager {
        if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
        if (amount == 0) return;

        address underlying = ILCC(lcc).underlying();
        uint256 available =
            underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));
        uint256 toSend = Math.min(amount, available);
        if (toSend == 0) return;

        address to = positionManager;
        Currency.wrap(underlying).transfer(to, toSend);
        emit UnderlyingReleasedToManager(lcc, toSend);
    }
}
