// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Local-dev stub for porep-market Client.transfer().
/// Curio/devnet gen-env defaults META_ALLOCATOR to the deployer EOA, which
/// has no code and causes FEVM transfers to revert. This no-op implements the
/// IMetaAllocator.addVerifiedClient surface so allocations can proceed when the
/// Client contract already holds DataCap (granted via lotus filplus).
contract NoOpMetaAllocator {
    error AmountEqualZero();

    event DatacapAllocated(address indexed allocator, bytes indexed client, uint256 amount);

    function addVerifiedClient(bytes calldata clientAddress, uint256 amount) external {
        if (amount == 0) revert AmountEqualZero();
        emit DatacapAllocated(msg.sender, clientAddress, amount);
    }
}
