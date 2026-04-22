// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title INativeSettlementReceiver
/// @notice Opt-in marker for contracts that may receive raw native ETH from Fiet `LiquidityHub` underlying transfer paths.
/// @dev Implementations must expose EIP-165 support for `type(INativeSettlementReceiver).interfaceId` so the Hub can
///      query capability without relying on wallet-standard heuristics. EOAs (`code.length == 0`) are not required to
///      implement this interface.
interface INativeSettlementReceiver {
    /// @notice Protocol capability marker; must exist so the interface has a stable EIP-165 id.
    function supportsNativeSettlementFromFiet() external view returns (bool);
}
