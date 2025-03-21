// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @title VerifySignature
 * @notice Library for verifying Ethereum signatures
 * @dev Provides functions to verify signatures by recovering the signer from a message hash and comparing it to a claimed signer.
 *      Follows the Ethereum signed message standard ("\x19Ethereum Signed Message:\n32" prefix).
 *
 *      How to Sign and Verify:
 *      # Signing (Off-Chain)
 *      1. Create a message to sign.
 *      2. Hash the message (e.g., using keccak256).
 *      3. Sign the hash with a private key (keep the private key secret, perform off-chain).
 *
 *      # Verification (On-Chain)
 *      1. Recreate the hash from the original message.
 *      2. Recover the signer from the signature and hash using ecrecover.
 *      3. Compare the recovered signer to the claimed signer.
 */
library SignatureLib {
    /**
     * @notice Verifies that a signature matches the claimed signer for a given message hash
     * @dev Recovers the signer from the signature and compares it to the provided signer address.
     *      The message hash is prefixed with "\x19Ethereum Signed Message:\n32" as per Ethereum standard.
     * @param signer The address claimed to have signed the message
     * @param message The original message hash (keccak256) that was signed
     * @param signature The 65-byte signature (r, s, v) produced off-chain
     * @return bool True if the signature is valid (signer matches recovered address), false otherwise
     */
    function verify(address signer, bytes32 message, bytes memory signature) internal pure returns (bool) {
        (bytes32 r, bytes32 s, uint8 v) = splitSignature(signature);
        bytes32 ethSignedMessageHash = getEthSignedMessageHash(message);

        address recovered = ecrecover(ethSignedMessageHash, v, r, s);
        return signer == recovered;
    }

    /**
     * @notice Splits a 65-byte signature into its r, s, and v components
     * @dev Uses assembly to efficiently extract r (32 bytes), s (32 bytes), and v (1 byte) from the signature.
     *      The signature format is expected to be: [r (32 bytes), s (32 bytes), v (1 byte)].
     * @param sig The 65-byte signature to split
     * @return r The first 32 bytes of the signature
     * @return s The second 32 bytes of the signature
     * @return v The recovery byte (27 or 28 typically)
     */
    function splitSignature(bytes memory sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(sig.length == 65, "invalid signature length");

        assembly {
            // First 32 bytes stores the length of the signature (skipped with add(sig, 32))
            // add(sig, 32) points to the start of the actual signature data
            // mload(p) loads 32 bytes from memory address p

            // First 32 bytes (r)
            r := mload(add(sig, 32))
            // Second 32 bytes (s)
            s := mload(add(sig, 64))
            // Final byte (v), extracted from the first byte of the next 32-byte slot
            v := byte(0, mload(add(sig, 96)))
        }

        // Implicitly returns (r, s, v)
    }

    /**
     * @notice Creates an Ethereum signed message hash from a given message hash
     * @dev Prepends the standard Ethereum prefix "\x19Ethereum Signed Message:\n32" to the message hash
     *      and computes the keccak256 hash, as required for ecrecover compatibility.
     * @param _messageHash The original message hash (keccak256) to be prefixed
     * @return bytes32 The Ethereum signed message hash ready for ecrecover
     */
    function getEthSignedMessageHash(bytes32 _messageHash) internal pure returns (bytes32) {
        // Signature is produced by signing a keccak256 hash with the format:
        // "\x19Ethereum Signed Message:\n" + len(msg) + msg
        // Here, we use a fixed length of 32 bytes for the message hash
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", _messageHash));
    }
}
