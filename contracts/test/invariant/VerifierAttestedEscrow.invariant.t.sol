// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MockUSD} from "../../src/MockUSD.sol";
import {VerifierAttestedEscrow} from "../../src/VerifierAttestedEscrow.sol";
import {EscrowHandler} from "./EscrowHandler.sol";
import {EscrowInvariants} from "./EscrowInvariants.sol";

/// The shared actions plus the two ways mechanism C settles a submitted task.
contract VerifierAttestedHandler is EscrowHandler {
    VerifierAttestedEscrow immutable escrowC;

    constructor(MockUSD token_, VerifierAttestedEscrow escrow_) EscrowHandler(token_, escrow_) {
        escrowC = escrow_;
    }

    function attest(uint256 taskSeed, bool pass) external countSettlements {
        uint256 taskId = _task(taskSeed);
        vm.prank(escrowC.verifier());
        escrowC.attest(taskId, pass);
    }

    function verifierTimeout(uint256 taskSeed) external countSettlements {
        uint256 taskId = _task(taskSeed);
        vm.prank(_requester(taskId));
        escrowC.verifierTimeout(taskId);
    }

    /// The verifier collects fees, so its balance counts as well.
    function tokensOutsideEscrow() public view override returns (uint256) {
        return super.tokensOutsideEscrow() + token.balanceOf(escrowC.verifier());
    }
}

contract VerifierAttestedEscrowInvariantTest is EscrowInvariants {
    function setUp() public {
        token = new MockUSD();
        // Windows of 6 blocks, verifier fee 20,000 units.
        VerifierAttestedEscrow escrowC = new VerifierAttestedEscrow(token, 6, 6, 6, makeAddr("verifier"), 20_000);
        escrow = escrowC;
        handler = new VerifierAttestedHandler(token, escrowC);

        targetContract(address(handler));
    }
}
