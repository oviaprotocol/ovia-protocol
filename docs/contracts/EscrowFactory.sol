// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Escrow.sol";

/**
 * @title EscrowFactory (Ovia Protocol v1)
 * @notice Deploys minimal non-custodial escrow contracts for trustless payments.
 *
 * The factory:
 *  - Deploys a fresh Escrow contract per job
 *  - Tracks all escrows per user
 *  - Emits events for indexing (subgraphs, explorers, dapps)
 *  - Ensures deterministic ownership
 *
 * Future-proof for:
 *  - Ovia Graph integration
 *  - Proof-of-Delivery automation
 *  - On-chain reputation scoring
 */
contract EscrowFactory {

    // -----------------------
    // EVENTS
    // -----------------------

    event EscrowCreated(
        address indexed client,
        address indexed freelancer,
        uint256 amount,
        address escrowAddress,
        uint256 timestamp
    );

    // -----------------------
    // STORAGE
    // -----------------------

    /// List of all deployed escrows
    address[] public allEscrows;

    /// Track escrows per client
    mapping(address => address[]) public escrowsByClient;

    /// Track escrows per freelancer
    mapping(address => address[]) public escrowsByFreelancer;

    // -----------------------
    // PUBLIC VIEW FUNCTIONS
    // -----------------------

    function getAllEscrows() external view returns (address[] memory) {
        return allEscrows;
    }

    function getEscrowsByClient(address client) external view returns (address[] memory) {
        return escrowsByClient[client];
    }

    function getEscrowsByFreelancer(address freelancer) external view returns (address[] memory) {
        return escrowsByFreelancer[freelancer];
    }

    // -----------------------
    // MAIN FUNCTION: CREATE ESCROW
    // -----------------------

    /**
     * @notice Deploy a new Escrow contract.
     *
     * @param freelancer  The address that will receive funds after proof.
     *
     * Requirements:
     *  - msg.value must match the initial escrow amount
     *  - freelancer cannot be zero address
     */
    function createEscrow(address freelancer)
        external
        payable
        returns (address)
    {
        require(freelancer != address(0), "Invalid freelancer");
        require(msg.value > 0, "Amount must be > 0");

        // Deploy minimal escrow clone
        Escrow escrow = new Escrow(
            msg.sender,    // client
            freelancer,    // freelancer
            msg.value      // escrow amount
        );

        // Transfer funds to the escrow contract
        (bool sent, ) = address(escrow).call{value: msg.value}("");
        require(sent, "Funding failed");

        // Indexing
        allEscrows.push(address(escrow));
        escrowsByClient[msg.sender].push(address(escrow));
        escrowsByFreelancer[freelancer].push(address(escrow));

        // Event
        emit EscrowCreated(
            msg.sender,
            freelancer,
            msg.value,
            address(escrow),
            block.timestamp
        );

        return address(escrow);
    }
}
