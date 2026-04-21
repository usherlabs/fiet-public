// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMMQueueCustodian} from "./interfaces/IMMQueueCustodian.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {Errors} from "./libraries/Errors.sol";

/// @dev Minimal view for `weth9()` on the LCC’s canonical Hub (same as `LiquidityHubLib.transferUnderlying`).
interface ILiquidityHubWeth9 {
    function weth9() external view returns (address);
}

/// @title MMQueueCustodian
/// @notice Per-NFT-recipient queue owner: one custodian serves many commitment NFTs (`bucketId == tokenId`; utility uses `0`).
/// @dev The Hub `settleQueue(lcc, address(this))` entry is owned by this contract; beneficiary-scoped `_queuedLcc`
///      tracks who may collect underlying after `LiquidityHub.processSettlementFor` pays this contract.
///
///      Intended model:
///      - `beneficiary` is the MM batch locker (owner, operator, or seizer) entitled to that staged principal slice.
///      - `COLLECT_AVAILABLE_LIQUIDITY` settles LCC against the Hub queue when needed, then forwards underlying to the
///        beneficiary via `collectUnderlyingToBeneficiary`, including underlying already paid to this contract when the
///        Hub queue was settled earlier (for example permissionless `processSettlementFor`).
///      - `unwrapLcc` calls Hub `unwrap` as this contract (queue owner == `address(this)`), then forwards any
///        immediately-received underlying to `forwardUnderlyingTo` (typically MMPM for native, locker or MMPM for ERC20).
contract MMQueueCustodian is IMMQueueCustodian {
    /// @notice Beneficiary-scoped custody increased (MM-backed LCC staged for later Hub settlement).
    event CustodyRecorded(uint256 indexed tokenId, address indexed lcc, address indexed beneficiary, uint256 amount);

    /// @notice Underlying paid out after Hub settlement burned custodied LCC against this contract.
    event UnderlyingPaid(uint256 indexed tokenId, address indexed lcc, address indexed beneficiary, uint256 amount);

    address public override positionManager;

    /// @dev Per-bucket aggregate for `isBucketEmpty(bucketId)` (decommit / transfer guards).
    mapping(uint256 bucketId => uint256) private _bucketQueuedTotal;

    // tokenId => lcc => beneficiary => queued custody balance
    mapping(uint256 tokenId => mapping(address lcc => mapping(address beneficiary => uint256 amount))) private
        _queuedLcc;

    /// @dev Sum of all outstanding `_queuedLcc` entries per `lcc` (LCC units), maintained in `_record` / collect.
    mapping(address lcc => uint256) private _totalQueuedLcc;

    modifier onlyPositionManager() {
        if (msg.sender != positionManager) revert Errors.InvalidSender();
        _;
    }

    /// @dev Accept native underlying from `LiquidityHub` settlement for native-backed LCC markets.
    receive() external payable {}

    constructor(address _positionManager) {
        if (_positionManager == address(0) || _positionManager.code.length == 0) {
            revert Errors.InvalidAddress(_positionManager);
        }
        positionManager = _positionManager;
    }

    /// @inheritdoc IMMQueueCustodian
    function record(uint256 tokenId, address lcc, address beneficiary, uint256 amount)
        external
        override
        onlyPositionManager
    {
        _record(tokenId, lcc, beneficiary, amount);
    }

    function _record(uint256 tokenId, address lcc, address beneficiary, uint256 amount) private {
        if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
        if (beneficiary == address(0)) revert Errors.InvalidAddress(beneficiary);
        if (amount == 0) return;
        _queuedLcc[tokenId][lcc][beneficiary] += amount;
        _bucketQueuedTotal[tokenId] += amount;
        _totalQueuedLcc[lcc] += amount;
        emit CustodyRecorded(tokenId, lcc, beneficiary, amount);
    }

    /// @inheritdoc IMMQueueCustodian
    function totalQueuedLcc(address lcc) external view override returns (uint256) {
        return _totalQueuedLcc[lcc];
    }

    /// @notice Hub `unwrap` as this contract: shortfall queues to `address(this)`; immediate underlying is forwarded to `forwardUnderlyingTo`.
    /// @dev `MMPM` must transfer `amount` LCC to this contract before calling. Native: forward to MMPM (`positionManager`) for delta credit; ERC20: forward per MM routing (`to` or MMPM).
    function unwrapLccViaHub(
        address lcc,
        address forwardUnderlyingTo,
        address beneficiary,
        uint256 bucketId,
        uint256 amount,
        ILiquidityHub hub
    ) external onlyPositionManager {
        if (amount == 0) return;
        if (forwardUnderlyingTo == address(0)) revert Errors.InvalidAddress(forwardUnderlyingTo);

        address underlying = ILCC(lcc).underlying();
        uint256 uBalBefore =
            underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));

        uint256 qBefore = hub.settleQueue(lcc, address(this));
        hub.unwrap(lcc, amount);
        uint256 queuedDelta = hub.settleQueue(lcc, address(this)) - qBefore;

        uint256 uBalAfter =
            underlying == address(0) ? address(this).balance : IERC20(underlying).balanceOf(address(this));
        uint256 immediateReceived = uBalAfter - uBalBefore;

        if (queuedDelta > 0) {
            uint256 bal = IERC20(lcc).balanceOf(address(this));
            if (bal < queuedDelta) revert Errors.InsufficientBalance(bal, queuedDelta);
            _record(bucketId, lcc, beneficiary, queuedDelta);
        }

        if (immediateReceived > 0) {
            if (underlying == address(0)) {
                _payNativeWithWethFallback(forwardUnderlyingTo, immediateReceived, lcc);
            } else {
                Currency.wrap(underlying).transfer(forwardUnderlyingTo, immediateReceived);
            }
        }
    }

    /// @inheritdoc IMMQueueCustodian
    function collectUnderlyingToBeneficiary(uint256 tokenId, address lcc, address beneficiary, uint256 amount)
        external
        override
        onlyPositionManager
    {
        if (beneficiary == address(0)) revert Errors.InvalidAddress(beneficiary);
        if (lcc == address(0)) revert Errors.InvalidAddress(lcc);
        if (amount == 0) return;

        uint256 q = _queuedLcc[tokenId][lcc][beneficiary];
        if (amount > q) revert Errors.InsufficientBalance(q, amount);
        _queuedLcc[tokenId][lcc][beneficiary] = q - amount;
        _bucketQueuedTotal[tokenId] -= amount;
        _totalQueuedLcc[lcc] -= amount;

        address underlying = ILCC(lcc).underlying();
        if (underlying == address(0)) {
            _payNativeWithWethFallback(beneficiary, amount, lcc);
        } else {
            Currency.wrap(underlying).transfer(beneficiary, amount);
        }
        emit UnderlyingPaid(tokenId, lcc, beneficiary, amount);
    }

    /// @dev Matches Hub native settlement liveness: direct ETH first, then wrap via canonical Hub `weth9` and transfer ERC20 WETH.
    function _payNativeWithWethFallback(address to, uint256 amount, address lcc) private {
        (bool ok,) = to.call{value: amount}("");
        if (ok) return;

        address wrappedNative = ILiquidityHubWeth9(ILCC(lcc).hub()).weth9();
        if (wrappedNative == address(0)) revert Errors.InvalidAddress(wrappedNative);

        IWETH9(wrappedNative).deposit{value: amount}();
        Currency.wrap(wrappedNative).transfer(to, amount);
    }

    /// @inheritdoc IMMQueueCustodian
    function isBucketEmpty(uint256 bucketId) external view override returns (bool) {
        return _bucketQueuedTotal[bucketId] == 0;
    }

    function queued(uint256 tokenId, address lcc, address beneficiary) external view override returns (uint256) {
        return _queuedLcc[tokenId][lcc][beneficiary];
    }
}
