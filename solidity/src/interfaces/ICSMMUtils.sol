// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICSMMUtils {
    function applyFees(uint256 baseAmount, uint256 fee1e6) external pure returns (uint256);
    function hashCurrency(string memory currency) external pure returns (bytes32);
    function encodeHookData(uint256 nonce, address userAddress, bytes32 fiatCurrencyHash, bytes calldata signature)
        external
        pure
        returns (bytes memory);
    function decodeAndVerifyHookData(bytes memory encodedData, uint256 amount) external returns (address, bytes32);
    function generateSignaturePayload(uint256 nonce, uint256 amount) external pure returns (bytes32);
    function getOnrampFees(bytes32 currencyHash, uint256 withdrawAmount) external returns (uint256);
    function calculateHookDynamicTresholdFee(uint256 withdrawAmount) external view returns (uint256 fee1e6);
    function calculateDynamicTresholdFee(uint256 usdcAmount, uint256 currentUSDC, uint256 initialUSDC, uint256 tauBps)
        external
        pure
        returns (uint256 fee1e6);
}
