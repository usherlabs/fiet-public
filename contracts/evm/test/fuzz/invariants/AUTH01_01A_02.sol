// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

/// @notice fuzz harness for AUTH-01, AUTH-01A, AUTH-02 authorisation invariants.
contract AUTH01_01A_02 {
    AuthHarness internal h;

    bool internal checked;
    bool internal lastOk;

    constructor() {
        h = new AuthHarness(address(this));
        h.setOwnerApproved(true);
        h.setPositionActive(1, true);
        h.setPoolManagerLocked(true);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_auth_01_owner_or_approved_required(bool approved, uint256 positionId, bool seizeContext) external {
        checked = false;
        lastOk = true;
        uint256 pid = (positionId % 4) + 1;
        h.setOwnerApproved(approved);
        h.setSeizedPositionId(seizeContext ? pid : 0);

        bool settled = h.trySettle(pid);
        bool modified = h.tryModify(pid);
        bool burned = h.tryBurn(pid);

        bool expected = approved || seizeContext;
        checked = true;
        lastOk = (settled == expected) && (modified == expected) && (burned == expected);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_auth_01a_seizing_context_scoped(uint256 seizedId, uint256 queriedId) external {
        checked = false;
        lastOk = true;
        uint256 sid = (seizedId % 4) + 1;
        uint256 qid = (queriedId % 4) + 1;
        h.setSeizedPositionId(sid);
        bool scoped = h.isSeizing(qid);
        checked = true;
        lastOk = scoped == (sid == qid);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_auth_01a_batch_clear(uint256 seizedId) external {
        checked = false;
        lastOk = true;
        uint256 sid = (seizedId % 4) + 1;
        h.setSeizedPositionId(sid);
        h.afterBatch();
        checked = true;
        lastOk = !h.isSeizing(sid);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function action_auth_02_transfer_blocked_mid_batch(bool poolManagerLocked, uint256 tokenId) external {
        checked = false;
        lastOk = true;
        h.setPoolManagerLocked(poolManagerLocked);
        bool ok = h.tryTransferFrom(address(0xBEEF), address(0xCAFE), tokenId);
        checked = true;
        lastOk = (ok == poolManagerLocked);
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function fuzz_auth_01_01a_02_hold() external view returns (bool) {
        return !checked || lastOk;
    }
}

contract AuthHarness {
    address internal immutable owner;
    bool internal ownerApproved;
    bool internal poolManagerLocked;
    uint256 internal seizedPositionId;
    mapping(uint256 => bool) internal activePosition;

    constructor(address owner_) {
        owner = owner_;
    }

    function setOwnerApproved(bool approved) external {
        ownerApproved = approved;
    }

    function setPoolManagerLocked(bool locked) external {
        poolManagerLocked = locked;
    }

    function setPositionActive(uint256 positionId, bool active) external {
        activePosition[positionId] = active;
    }

    function setSeizedPositionId(uint256 positionId) external {
        seizedPositionId = positionId;
    }

    function isSeizing(uint256 positionId) public view returns (bool) {
        return seizedPositionId != 0 && seizedPositionId == positionId;
    }

    function afterBatch() external {
        seizedPositionId = 0;
    }

    function _assertApprovedOrOwner(uint256 positionId) internal view {
        if (!ownerApproved && !isSeizing(positionId)) revert("not approved");
    }

    function settle(uint256 positionId) external view {
        _assertApprovedOrOwner(positionId);
    }

    function modify(uint256 positionId) external view {
        _assertApprovedOrOwner(positionId);
    }

    function burn(uint256 positionId) external view {
        _assertApprovedOrOwner(positionId);
    }

    function transferFrom(address, address, uint256) external view {
        if (!poolManagerLocked) revert("PoolManagerMustBeLocked");
    }

    function trySettle(uint256 positionId) external returns (bool ok) {
        try this.settle(positionId) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function tryModify(uint256 positionId) external returns (bool ok) {
        try this.modify(positionId) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function tryBurn(uint256 positionId) external returns (bool ok) {
        try this.burn(positionId) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function tryTransferFrom(address from, address to, uint256 tokenId) external returns (bool ok) {
        try this.transferFrom(from, to, tokenId) {
            ok = true;
        } catch {
            ok = false;
        }
    }
}

