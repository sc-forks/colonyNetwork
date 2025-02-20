/*
  This file is part of The Colony Network.

  The Colony Network is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  The Colony Network is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with The Colony Network. If not, see <http://www.gnu.org/licenses/>.
*/

pragma solidity 0.5.8;
pragma experimental "ABIEncoderV2";

import "../lib/dappsys/math.sol";
import "./IColonyNetwork.sol";
import "./PatriciaTree/PatriciaTreeProofs.sol";
import "./ITokenLocking.sol";
import "./ReputationMiningCycleStorage.sol";
import {Bits} from "./PatriciaTree/Bits.sol";


// TODO (post CCv1, possibly never): Can we handle all possible disputes regarding the very first hash that should be set?
// Currently, at the very least, we can't handle a dispute if the very first entry is disputed.
// A possible workaround would be to 'kick off' reputation mining with a known dummy state...
// Given the approach we a taking for launch, we are able to guarantee that we are the only reputation miner for 100+ of the first cycles, even if we decided to lengthen a cycle length. As a result, maybe we just don't care about this special case?
contract ReputationMiningCycleRespond is ReputationMiningCycleStorage, PatriciaTreeProofs, DSMath {

  /// @notice A modifier that checks if the challenge corresponding to the hash in the passed `round` and `id` is open
  /// @param round The round number of the hash under consideration
  /// @param idx The index in the round of the hash under consideration
  modifier challengeOpen(uint256 round, uint256 idx) {
    // Check the binary search has finished, but not necessarily confirmed
    require(idx < disputeRounds[round].length, "colony-reputation-mining-index-beyond-round-length");
    require(disputeRounds[round][idx].lowerBound == disputeRounds[round][idx].upperBound, "colony-reputation-binary-search-incomplete");
    // Check the binary search result has been confirmed
    Submission storage submission = reputationHashSubmissions[disputeRounds[round][idx].firstSubmitter];
    require(
      2**(disputeRounds[round][idx].challengeStepCompleted-2)>submission.jrhNNodes,
      "colony-reputation-mining-binary-search-result-not-confirmed"
    );
    // Check that we have not already responded to the challenge
    require(
      2**(disputeRounds[round][idx].challengeStepCompleted-3)<=submission.jrhNNodes,
      "colony-reputation-mining-challenge-already-responded"
    );
    _;
  }

  uint constant U_ROUND = 0;
  uint constant U_IDX = 1;
  uint constant U_REPUTATION_BRANCH_MASK = 2;
  uint constant U_AGREE_STATE_NNODES = 3;
  uint constant U_AGREE_STATE_BRANCH_MASK = 4;
  uint constant U_DISAGREE_STATE_NNODES = 5;
  uint constant U_DISAGREE_STATE_BRANCH_MASK = 6;
  uint constant U_PREVIOUS_NEW_REPUTATION_BRANCH_MASK = 7;
  uint constant U_LOG_ENTRY_NUMBER = 8;
  uint constant U_DECAY_TRANSITION = 9;
  uint constant U_USER_ORIGIN_SKILL_REPUTATION_BRANCH_MASK = 10;

  uint constant U_AGREE_STATE_REPUTATION_VALUE = 11;
  uint constant U_AGREE_STATE_REPUTATION_UID = 12;
  uint constant U_DISAGREE_STATE_REPUTATION_VALUE = 13;
  uint constant U_DISAGREE_STATE_REPUTATION_UID= 14;
  uint constant U_PREVIOUS_NEW_REPUTATION_VALUE = 15;
  uint constant U_PREVIOUS_NEW_REPUTATION_UID = 16;
  uint constant U_USER_ORIGIN_REPUTATION_VALUE = 17;
  uint constant U_USER_ORIGIN_REPUTATION_UID = 18;
  uint constant U_CHILD_REPUTATION_BRANCH_MASK = 19;
  uint constant U_CHILD_REPUTATION_VALUE = 20;
  uint constant U_CHILD_REPUTATION_UID = 21;
  uint constant U_GLOBAL_CHILD_UPDATE = 22;
  uint constant U_ADJACENT_REPUTATION_BRANCH_MASK = 23;
  uint constant U_ADJACENT_REPUTATION_VALUE = 24;
  uint constant U_ADJACENT_REPUTATION_UID = 25;
  uint constant U_NEW_REPUTATION = 26;
  uint constant U_USER_ORIGIN_ADJACENT_REPUTATION_VALUE = 27;
  uint constant U_CHILD_ADJACENT_REPUTATION_VALUE = 28;

  uint constant B_REPUTATION_KEY_COLONY = 0;
  uint constant B_REPUTATION_KEY_SKILLID = 1;
  uint constant B_REPUTATION_KEY_USER = 2;
  uint constant B_REPUTATION_KEY_HASH = 3;
  uint constant B_PREVIOUS_NEW_REPUTATION_KEY_HASH = 4;
  uint constant B_ADJACENT_REPUTATION_KEY_HASH = 5;
  uint constant B_ORIGIN_ADJACENT_REPUTATION_KEY_HASH = 6;
  uint constant B_CHILD_ADJACENT_REPUTATION_KEY_HASH = 7;

  uint constant DECAY_NUMERATOR =    992327946262944; // 24-hr mining cycles
  uint constant DECAY_DENOMINATOR = 1000000000000000;

  function getDecayConstant() public pure returns (uint256, uint256) {
    return (DECAY_NUMERATOR, DECAY_DENOMINATOR);
  }

  function respondToChallenge(
    uint256[29] memory u, //An array of 29 UINT Params, ordered as given above.
    bytes32[8] memory b32, // An array of 8 bytes32 params, ordered as given above
    bytes32[] memory reputationSiblings,
    bytes32[] memory agreeStateSiblings,
    bytes32[] memory disagreeStateSiblings,
    bytes32[] memory previousNewReputationSiblings,
    bytes32[] memory userOriginReputationSiblings,
    bytes32[] memory childReputationSiblings,
    bytes32[] memory adjacentReputationSiblings
  ) public
    challengeOpen(u[U_ROUND], u[U_IDX])
  {
    u[U_DECAY_TRANSITION] = 0;
    u[U_GLOBAL_CHILD_UPDATE] = 0;
    u[U_NEW_REPUTATION] = 0;
    // Require disagree state nnodes - agree state nnodes is either 0 or 1. Its a uint, so we can simplify this to < 2.
    require(u[U_DISAGREE_STATE_NNODES] - u[U_AGREE_STATE_NNODES] < 2, "colony-network-mining-more-than-one-node-added");
    // TODO: More checks that this is an appropriate time to respondToChallenge (maybe in modifier);
    /* bytes32 jrh = disputeRounds[round][idx].jrh; */
    // The contract knows
    // 1. the jrh for this submission
    // 2. The first index where this submission and its opponent differ.
    // Need to prove
    // 1. The reputation that is updated that we disagree on's value, before the first index
    //    where we differ, and in the first index where we differ.
    // 2. That no other changes are made to the reputation state. The proof for those
    //    two reputations in (1) is therefore required to be the same.
    // 3. That our 'after' value is correct. This is done by doing the calculation on-chain, perhaps
    //    after looking up the corresponding entry in the reputation update log (the alternative is
    //    that it's a decay calculation - not yet implemented.)

    // Check the supplied key is appropriate.
    checkKey(u, b32);

    // Prove the reputation's starting value is in some state, and that state is in the appropriate index in our JRH
    proveBeforeReputationValue(u, b32, reputationSiblings, agreeStateSiblings);

    // Prove the reputation's final value is in a particular state, and that state is in our JRH in the appropriate index (corresponding to the first disagreement between these miners)
    // By using the same branchMask and siblings, we know that no other changes to the reputation state tree have been slipped in.
    proveAfterReputationValue(u, b32, reputationSiblings, disagreeStateSiblings);

    // Perform the reputation calculation ourselves.
    performReputationCalculation(u);

    if (u[U_DECAY_TRANSITION] == 0) {
      checkUserOriginReputation(u, b32, agreeStateSiblings, userOriginReputationSiblings);
    }

    if (u[U_GLOBAL_CHILD_UPDATE] == 1) {
      checkChildReputation(u, b32, agreeStateSiblings, childReputationSiblings);
    }

    if (u[U_NEW_REPUTATION] == 1) {
      checkAdjacentReputation(u, b32, adjacentReputationSiblings, agreeStateSiblings, disagreeStateSiblings);
    }

    // If necessary, check the supplied previousNewRepuation is, in fact, in the same reputation state as the 'agree' state.
    // i.e. the reputation they supplied is in the 'agree' state.
    checkPreviousReputationInState(
      u,
      b32,
      agreeStateSiblings,
      previousNewReputationSiblings);

    // Save the index for tiebreak scenarios later.
    saveProvedReputation(u);

    confirmChallengeCompleted(u);

    // Safety net?
    /* if (disputeRounds[round][idx].challengeStepCompleted==disputeRounds[round][opponentIdx].challengeStepCompleted){
      // Freeze the reputation mining system.
    } */
  }

  /////////////////////////
  // Internal functions
  /////////////////////////

  function checkAdjacentReputation(
    uint256[29] memory u,
    bytes32[8] memory b32,
    bytes32[] memory adjacentReputationSiblings,
    bytes32[] memory agreeStateSiblings,
    bytes32[] memory disagreeStateSiblings
    ) internal view
  {
    DisputedEntry storage disputedEntry = disputeRounds[u[U_ROUND]][u[U_IDX]];
    // Check this proof is valid for the agree state
    // We binary searched to the first disagreement, so the last agreement is the one before
    bytes memory adjacentReputationValue = abi.encodePacked(u[U_ADJACENT_REPUTATION_VALUE], u[U_ADJACENT_REPUTATION_UID]);

    bytes32 reputationRootHash = getImpliedRootNoHashKey(
      b32[B_ADJACENT_REPUTATION_KEY_HASH],
      adjacentReputationValue,
      u[U_ADJACENT_REPUTATION_BRANCH_MASK],
      adjacentReputationSiblings
    );
    bytes memory jhLeafValue = abi.encodePacked(uint256(reputationRootHash), u[U_AGREE_STATE_NNODES]);
    // Prove that state is in our JRH, in the index corresponding to the last state that the two submissions agree on
    bytes32 impliedRoot = getImpliedRootNoHashKey(
      bytes32(disputedEntry.lowerBound - 1),
      jhLeafValue,
      u[U_AGREE_STATE_BRANCH_MASK],
      agreeStateSiblings);

    require(
      impliedRoot == reputationHashSubmissions[disputedEntry.firstSubmitter].jrh,
      "colony-reputation-mining-adjacent-agree-state-disagreement");

    // The bit added to the branchmask is based on where the (hashes of the) two keys first differ.
    uint256 firstDifferenceBit = uint256(
      Bits.highestBitSet(uint256(b32[B_ADJACENT_REPUTATION_KEY_HASH] ^ b32[B_REPUTATION_KEY_HASH]))
    );
    uint256 afterInsertionBranchMask = u[U_ADJACENT_REPUTATION_BRANCH_MASK] | uint256(2**firstDifferenceBit);
    // If a key that exists in the lastAgreeState has been passed in as the reputationKey, the adjacent key will already have a branch at the
    // first difference bit, and this check will fail.
    require(afterInsertionBranchMask != u[U_ADJACENT_REPUTATION_BRANCH_MASK], "colony-reputation-mining-adjacent-branchmask-incorrect");

    bytes32[] memory afterInsertionAdjacentReputationSiblings = new bytes32[](adjacentReputationSiblings.length + 1);
    afterInsertionAdjacentReputationSiblings = buildNewSiblingsArray(u, b32, firstDifferenceBit, adjacentReputationSiblings);

    reputationRootHash = getImpliedRootNoHashKey(
      b32[B_ADJACENT_REPUTATION_KEY_HASH],
      adjacentReputationValue,
      afterInsertionBranchMask,
      afterInsertionAdjacentReputationSiblings
    );

    jhLeafValue = abi.encodePacked(uint256(reputationRootHash), u[U_DISAGREE_STATE_NNODES]);
    // Prove that state is in our JRH, in the index corresponding to the first state that the two submissions disagree on
    impliedRoot = getImpliedRootNoHashKey(
      bytes32(disputedEntry.lowerBound),
      jhLeafValue,
      u[U_DISAGREE_STATE_BRANCH_MASK],
      disagreeStateSiblings);

    require(
      impliedRoot == reputationHashSubmissions[disputedEntry.firstSubmitter].jrh,
      "colony-reputation-mining-adjacent-disagree-state-disagreement");
  }

  function buildNewSiblingsArray(
    uint256[29] memory u,
    bytes32[8] memory b32,
    uint256 firstDifferenceBit,
    bytes32[] memory adjacentReputationSiblings
    ) internal pure returns (bytes32[] memory)
  {
    bytes32 newSibling = keccak256(
      abi.encodePacked(
        keccak256(
          abi.encodePacked(
            u[U_DISAGREE_STATE_REPUTATION_VALUE],
            u[U_DISAGREE_STATE_REPUTATION_UID]
          )
        ),
        firstDifferenceBit,
        b32[B_REPUTATION_KEY_HASH] << (256 - firstDifferenceBit)
      )
    );

    // Copy in to afterInsertionAdjacentReputationSiblings, inserting the new sibling.
    // Where do we insert it? Depends how many branches there are before the new bit we just inserted
    uint insert = 0;
    uint i = 2**255;
    // This can be > or >= because the adjacent reputation branchmask will be a 0 in the
    // bit where the two keys first differ.
    while (i > 2**firstDifferenceBit) {
      if (i & u[U_ADJACENT_REPUTATION_BRANCH_MASK] == i) {
        insert += 1;
      }
      i >>= 1;
    }
    bytes32[] memory afterInsertionAdjacentReputationSiblings = new bytes32[](adjacentReputationSiblings.length + 1);

    // Now actually build the new siblings array
    i = 0;
    while (i < afterInsertionAdjacentReputationSiblings.length) {
      if (i < insert) {
        afterInsertionAdjacentReputationSiblings[i] = adjacentReputationSiblings[i];
      } else if (i == insert) {
        afterInsertionAdjacentReputationSiblings[i] = newSibling;
      } else {
        afterInsertionAdjacentReputationSiblings[i] = adjacentReputationSiblings[i-1];
      }
      i += 1;
    }

    return afterInsertionAdjacentReputationSiblings;
  }

  function checkUserOriginReputation(
    uint256[29] memory u,
    bytes32[8] memory b32,
    bytes32[] memory agreeStateSiblings,
    bytes32[] memory userOriginReputationSiblings) internal view
  {
    ReputationLogEntry storage logEntry = reputationUpdateLog[u[U_LOG_ENTRY_NUMBER]];
    if (logEntry.amount >= 0) {
      return;
    }

    // Check the user origin reputation key matches the colony, user address and skill id of the log
    bytes32 userOriginReputationKeyBytesHash = keccak256(abi.encodePacked(logEntry.colony, logEntry.skillId, logEntry.user));

    checkUserOriginReputationInState(
      u,
      b32,
      agreeStateSiblings,
      userOriginReputationKeyBytesHash,
      userOriginReputationSiblings);
  }

  function checkChildReputation(
    uint256[29] memory u,
    bytes32[8] memory b32,
    bytes32[] memory agreeStateSiblings,
    bytes32[] memory childReputationSiblings) internal view
  {
    // If we think we need to check the child reputation because of the update number, but the origin reputation value is
    // zero, we don't need check the child reputation because it isn't actually used in the calculation.
    if (u[U_USER_ORIGIN_REPUTATION_VALUE] == 0) {return;}
    // This function is only called if the dispute is over a child reputation update of a colony-wide reputation total
    ReputationLogEntry storage logEntry = reputationUpdateLog[u[U_LOG_ENTRY_NUMBER]];

    uint256 relativeUpdateNumber = getRelativeUpdateNumber(u, logEntry);
    uint256 expectedSkillId = IColonyNetwork(colonyNetworkAddress).getChildSkillId(logEntry.skillId, relativeUpdateNumber);
    bytes memory childReputationKey = abi.encodePacked(logEntry.colony, expectedSkillId, logEntry.user);

    checkChildReputationInState(
      u,
      agreeStateSiblings,
      childReputationKey,
      childReputationSiblings,
      b32[B_CHILD_ADJACENT_REPUTATION_KEY_HASH]);
  }

  function confirmChallengeCompleted(uint256[29] memory u) internal {
    // If everthing checked out, note that we've responded to the challenge.
    disputeRounds[u[U_ROUND]][u[U_IDX]].challengeStepCompleted += 1;
    disputeRounds[u[U_ROUND]][u[U_IDX]].lastResponseTimestamp = now;
    Submission storage submission = reputationHashSubmissions[disputeRounds[u[U_ROUND]][u[U_IDX]].firstSubmitter];

    emit ChallengeCompleted(submission.proposedNewRootHash, submission.nNodes, submission.jrh);
  }

  function checkKey(uint256[29] memory u, bytes32[8] memory b32) internal view {
    // If the state transition we're checking is less than the number of nodes in the currently accepted state, it's a decay transition
    // Otherwise, look up the corresponding entry in the reputation log.
    uint256 updateNumber = disputeRounds[u[U_ROUND]][u[U_IDX]].lowerBound - 1;
    if (updateNumber < IColonyNetwork(colonyNetworkAddress).getReputationRootHashNNodes()) {
      checkKeyDecay(u, updateNumber);
      u[U_DECAY_TRANSITION] = 1;
    } else {
      checkKeyLogEntry(u, b32);
    }
  }

  function checkKeyDecay(uint256[29] memory u, uint256 _updateNumber) internal pure {
    // We check that the reputation UID is right for the decay transition being disputed.
    // The key is then implicitly checked when they prove that the key+value they supplied is in the
    // right intermediate state in their justification tree.
    require(u[U_AGREE_STATE_REPUTATION_UID]-1 == _updateNumber, "colony-reputation-mining-uid-not-decay");
  }

  function checkKeyLogEntry(uint256[29] memory u, bytes32[8] memory b32) internal view {
    ReputationLogEntry storage logEntry = reputationUpdateLog[u[U_LOG_ENTRY_NUMBER]];

    uint256 expectedSkillId;
    address expectedAddress;
    (expectedSkillId, expectedAddress) = getExpectedSkillIdAndAddress(u, logEntry);

    require(expectedAddress == address(uint256(b32[B_REPUTATION_KEY_USER])), "colony-reputation-mining-user-address-mismatch");
    require(logEntry.colony == address(uint256(b32[B_REPUTATION_KEY_COLONY])), "colony-reputation-mining-colony-address-mismatch");
    require(expectedSkillId == uint256(b32[B_REPUTATION_KEY_SKILLID]), "colony-reputation-mining-skill-id-mismatch");

    require(
      keccak256(
        buildReputationKey(b32[B_REPUTATION_KEY_COLONY], b32[B_REPUTATION_KEY_SKILLID], b32[B_REPUTATION_KEY_USER])
      ) == b32[B_REPUTATION_KEY_HASH],
      "colony-reputation-mining-reputation-key-and-hash-mismatch"
    );
  }

  function getExpectedSkillIdAndAddress(uint256[29] memory u, ReputationLogEntry storage logEntry) internal view
  returns (uint256 expectedSkillId, address expectedAddress)
  {
    uint256 relativeUpdateNumber = getRelativeUpdateNumber(u, logEntry);
    uint256 nChildUpdates;
    uint256 nParentUpdates;
    (nChildUpdates, nParentUpdates) = getChildAndParentNUpdatesForLogEntry(u);

    // Work out the expected userAddress and skillId for this updateNumber in this logEntry.
    if (relativeUpdateNumber < logEntry.nUpdates / 2) {
      // Then we're updating a colony-wide total, so we expect an address of 0x0
      expectedAddress = address(0x0);
    } else {
      // We're updating a user-specific total
      expectedAddress = logEntry.user;
    }

    // Expected skill Id
    // We update skills in the order children, then parents, then the skill listed in the log itself.
    // If the amount in the log is positive, then no children are being updated.
    uint256 _relativeUpdateNumber = relativeUpdateNumber % (logEntry.nUpdates/2);
    if (_relativeUpdateNumber < nChildUpdates) {
      expectedSkillId = IColonyNetwork(colonyNetworkAddress).getChildSkillId(logEntry.skillId, _relativeUpdateNumber);
    } else if (_relativeUpdateNumber < (nChildUpdates+nParentUpdates)) {
      expectedSkillId = IColonyNetwork(colonyNetworkAddress).getParentSkillId(logEntry.skillId, _relativeUpdateNumber - nChildUpdates);
    } else {
      expectedSkillId = logEntry.skillId;
    }
  }

  function proveBeforeReputationValue(
    uint256[29] memory u,
    bytes32[8] memory b32,
    bytes32[] memory reputationSiblings,
    bytes32[] memory agreeStateSiblings
  ) internal view
  {
    if (u[U_DISAGREE_STATE_NNODES] - u[U_AGREE_STATE_NNODES] == 1) {
      // This implies they are claiming that this is a new hash.
      // Flag we need to check the adjacent hash
      u[U_NEW_REPUTATION] = 1;
      return;
    }
    // Otherwise, it's an existing hash and we've just changed its value.
    // We binary searched to the first disagreement, so the last agreement is the one before.
    uint256 lastAgreeIdx = disputeRounds[u[U_ROUND]][u[U_IDX]].lowerBound - 1;

    bytes memory agreeStateReputationValue = abi.encodePacked(u[U_AGREE_STATE_REPUTATION_VALUE], u[U_AGREE_STATE_REPUTATION_UID]);

    bytes32 reputationRootHash = getImpliedRootNoHashKey(
      b32[B_REPUTATION_KEY_HASH],
      agreeStateReputationValue,
      u[U_REPUTATION_BRANCH_MASK],
      reputationSiblings);

    bytes memory jhLeafValue = abi.encodePacked(uint256(reputationRootHash), u[U_AGREE_STATE_NNODES]);

    // Prove that state is in our JRH, in the index corresponding to the last state that the two submissions agree on.
    bytes32 impliedRoot = getImpliedRootNoHashKey(bytes32(lastAgreeIdx), jhLeafValue, u[U_AGREE_STATE_BRANCH_MASK], agreeStateSiblings);

    Submission storage submission = reputationHashSubmissions[disputeRounds[u[U_ROUND]][u[U_IDX]].firstSubmitter];
    require(impliedRoot == submission.jrh, "colony-reputation-mining-invalid-before-reputation-proof");
    // Check that they have not changed nNodes from the agree state
    // There is a check at the very start of RespondToChallenge that this difference is either 0 or 1.
    // There is an 'if' statement above that returns if this difference is 1.
    // Therefore the difference is 0, and this should always be true.
    assert(u[U_DISAGREE_STATE_NNODES] == u[U_AGREE_STATE_NNODES]);
    // They've actually verified whatever they claimed.
    // In the event that our opponent lied about this reputation not existing yet in the tree, they will fail on checkAdjacentReputation,
    // as the branchmask generated will indicate that the node already exists
  }

  function proveAfterReputationValue(
    uint256[29] memory u,
    bytes32[8] memory b32,
    bytes32[] memory reputationSiblings,
    bytes32[] memory disagreeStateSiblings
  ) internal view
  {
    Submission storage submission = reputationHashSubmissions[disputeRounds[u[U_ROUND]][u[U_IDX]].firstSubmitter];
    uint256 firstDisagreeIdx = disputeRounds[u[U_ROUND]][u[U_IDX]].lowerBound;

    bytes memory disagreeStateReputationValue = abi.encodePacked(u[U_DISAGREE_STATE_REPUTATION_VALUE], u[U_DISAGREE_STATE_REPUTATION_UID]);

    bytes32 reputationRootHash = getImpliedRootNoHashKey(
      b32[B_REPUTATION_KEY_HASH],
      disagreeStateReputationValue,
      u[U_REPUTATION_BRANCH_MASK],
      reputationSiblings
    );
    // Prove that state is in our JRH, in the index corresponding to the last state that the two submissions agree on.
    bytes memory jhLeafValue = abi.encodePacked(uint256(reputationRootHash), u[U_DISAGREE_STATE_NNODES]);

    bytes32 impliedRoot = getImpliedRootNoHashKey(
      bytes32(firstDisagreeIdx),
      jhLeafValue,
      u[U_DISAGREE_STATE_BRANCH_MASK],
      disagreeStateSiblings
    );
    require(submission.jrh==impliedRoot, "colony-reputation-mining-invalid-after-reputation-proof");
  }

  function performReputationCalculation(
    uint256[29] memory u
  ) internal
  {

    proveUID(
      u,
      u[U_AGREE_STATE_REPUTATION_UID],
      u[U_DISAGREE_STATE_REPUTATION_UID]);

    proveValue(
      u,
      int256(u[U_AGREE_STATE_REPUTATION_VALUE]),
      int256(u[U_DISAGREE_STATE_REPUTATION_VALUE]));
  }

  function proveUID(
    uint256[29] memory u,
    uint256 _agreeStateReputationUID,
    uint256 _disagreeStateReputationUID
  ) internal
  {
    if (_agreeStateReputationUID != 0) {
      // i.e. if this was an existing reputation, then require that the ID hasn't changed.
      require(_agreeStateReputationUID == _disagreeStateReputationUID, "colony-reputation-mining-uid-changed-for-existing-reputation");
      emit ProveUIDSuccess(_agreeStateReputationUID, _disagreeStateReputationUID, true);
    } else {
      require(u[U_PREVIOUS_NEW_REPUTATION_UID] + 1 == _disagreeStateReputationUID, "colony-reputation-mining-new-uid-incorrect");

      emit ProveUIDSuccess(u[U_PREVIOUS_NEW_REPUTATION_UID], _disagreeStateReputationUID, false);
    }
  }

  function proveValue(
    uint256[29] memory u,
    int256 _agreeStateReputationValue,
    int256 _disagreeStateReputationValue
  ) internal
  {
    ReputationLogEntry storage logEntry = reputationUpdateLog[u[U_LOG_ENTRY_NUMBER]];

    int256 userOriginReputationValue = int256(u[U_USER_ORIGIN_REPUTATION_VALUE]);

    // We don't care about underflows for the purposes of comparison, but for the calculation we deem 'correct'.
    // i.e. a reputation can't be negative.
    if (u[U_DECAY_TRANSITION] == 1) {
      require(uint256(_disagreeStateReputationValue) == (uint256(_agreeStateReputationValue)*DECAY_NUMERATOR)/DECAY_DENOMINATOR, "colony-reputation-mining-decay-incorrect");
    } else {
      if (logEntry.amount >= 0) {
        // Don't allow reputation to overflow
        if (_agreeStateReputationValue + logEntry.amount >= MAX_INT128) {
          require(_disagreeStateReputationValue == MAX_INT128, "colony-reputation-mining-reputation-not-max-int128");
        } else {
          require(_agreeStateReputationValue + logEntry.amount == _disagreeStateReputationValue, "colony-reputation-mining-increased-reputation-value-incorrect");
        }
      } else {
        // We are working with a negative amount, which needs to be treated differently for child updates and everything else
        // Child reputations do not lose the whole of logEntry.amount, but the same fraction logEntry amount is
        // of the user's reputation in skill given by logEntry.skillId, i.e. the "origin skill"
        // Check if we are working with a child reputation update
        uint256 relativeUpdateNumber = getRelativeUpdateNumber(u, logEntry);
        uint256 nChildUpdates;
        (nChildUpdates, ) = getChildAndParentNUpdatesForLogEntry(u);

        int256 reputationChange;

        // Skip origin reputation checks for anything but child reputation updates
        if (relativeUpdateNumber % (logEntry.nUpdates/2) < nChildUpdates) {
          int256 userChildReputationValue;

          if (relativeUpdateNumber < nChildUpdates) {
            u[U_GLOBAL_CHILD_UPDATE] = 1;
            userChildReputationValue = int256(u[U_CHILD_REPUTATION_VALUE]);
          } else {
            userChildReputationValue = int256(u[U_AGREE_STATE_REPUTATION_VALUE]);
          }

          int256 childReputationChange;
          if (userOriginReputationValue == 0) {
            // If the origin reputation value is 0, the change is 0
            reputationChange = 0;
          } else {
            // Calculate the proportional change expected
            childReputationChange = logEntry.amount * userChildReputationValue / userOriginReputationValue;
            // Cap change based on current value of the user's child reputation.
            if (userChildReputationValue + childReputationChange < 0) {
              reputationChange = -1 * userChildReputationValue;
            } else {
              reputationChange = childReputationChange;
            }
          }

        } else {
          // Cap change based on origin reputation value
          // Note we are not worried about underflows here; colony-wide totals for origin skill and all parents are greater than or equal to a user's origin skill.
          // If we're subtracting the origin reputation value, we therefore can't underflow, and if we're subtracting the logEntryAmount, it was absolutely smaller than
          // the origin reputation value, and so can't underflow either.
          if (userOriginReputationValue + logEntry.amount < 0) {
            reputationChange = -1 * userOriginReputationValue;
          } else {
            reputationChange = logEntry.amount;
          }
        }

        require(_agreeStateReputationValue + reputationChange == _disagreeStateReputationValue, "colony-reputation-mining-decreased-reputation-value-incorrect");
      }
    }

    emit ProveValueSuccess(_agreeStateReputationValue, _disagreeStateReputationValue, userOriginReputationValue);
  }

  // Get the update number relative in the context of the log entry currently considered
  // e.g. for log entry with 6 updates, the relative update number range is [0 .. 5] (inclusive)
  function getRelativeUpdateNumber(uint256[29] memory u, ReputationLogEntry memory logEntry) internal view returns (uint256) {
    uint256 nNodes = IColonyNetwork(colonyNetworkAddress).getReputationRootHashNNodes();
    uint256 updateNumber = sub(sub(disputeRounds[u[U_ROUND]][u[U_IDX]].lowerBound, 1), nNodes);

    // Check that the supplied log entry corresponds to this update number
    require(updateNumber >= logEntry.nPreviousUpdates, "colony-reputation-mining-update-number-part-of-previous-log-entry-updates");
    require(
      updateNumber < logEntry.nUpdates + logEntry.nPreviousUpdates,
      "colony-reputation-mining-update-number-part-of-following-log-entry-updates");

    uint256 relativeUpdateNumber = updateNumber - logEntry.nPreviousUpdates;
    return relativeUpdateNumber;
  }

  function getChildAndParentNUpdatesForLogEntry(uint256[29] memory u) internal view returns (uint128, uint128) {
    ReputationLogEntry storage logEntry = reputationUpdateLog[u[U_LOG_ENTRY_NUMBER]];
    uint128 nParents = IColonyNetwork(colonyNetworkAddress).getSkill(logEntry.skillId).nParents;

    uint128 nChildUpdates;
    if (logEntry.amount < 0) {
      nChildUpdates = logEntry.nUpdates/2 - 1 - nParents;
      // NB This is not necessarily the same as nChildren. However, this is the number of child updates
      // that this entry in the log was expecting at the time it was created
    }

    return (nChildUpdates, nParents);
  }

  function checkPreviousReputationInState(
    uint256[29] memory u,
    bytes32[8] memory b32,
    bytes32[] memory agreeStateSiblings,
    bytes32[] memory previousNewReputationSiblings
    ) internal view
  {
    // We binary searched to the first disagreement, so the last agreement is the one before
    uint256 lastAgreeIdx = disputeRounds[u[U_ROUND]][u[U_IDX]].lowerBound - 1;

    bytes memory previousNewReputationValue = abi.encodePacked(u[U_PREVIOUS_NEW_REPUTATION_VALUE], u[U_PREVIOUS_NEW_REPUTATION_UID]);

    bytes32 reputationRootHash = getImpliedRootNoHashKey(
      b32[B_PREVIOUS_NEW_REPUTATION_KEY_HASH],
      previousNewReputationValue,
      u[U_PREVIOUS_NEW_REPUTATION_BRANCH_MASK],
      previousNewReputationSiblings
    );
    bytes memory jhLeafValue = abi.encodePacked(uint256(reputationRootHash), u[U_AGREE_STATE_NNODES]);
    // Prove that state is in our JRH, in the index corresponding to the last state that the two submissions agree on
    bytes32 impliedRoot = getImpliedRootNoHashKey(bytes32(lastAgreeIdx), jhLeafValue, u[U_AGREE_STATE_BRANCH_MASK], agreeStateSiblings);
    Submission storage submission = reputationHashSubmissions[disputeRounds[u[U_ROUND]][u[U_IDX]].firstSubmitter];
    require(impliedRoot == submission.jrh, "colony-reputation-mining-last-state-disagreement");
  }

  function checkKeyHashesAdjacent(bytes32 hash1, bytes32 hash2, uint256 branchMask) internal pure returns (bool) {
    // The bit that would be added to the branchmask is based on where the (hashes of the) two keys first differ.
    uint256 firstDifferenceBit = uint256(Bits.highestBitSet(uint256(hash1 ^ hash2)));
    uint256 afterInsertionBranchMask = branchMask | uint256(2**firstDifferenceBit);
    // If key1 and key2 both exist in a tree, there will already be a branch at the first difference bit,
    // and so the branchmask will be unchanged.
    return afterInsertionBranchMask != branchMask;
  }

  function checkUserOriginReputationInState(
    uint256[29] memory u,
    bytes32[8] memory b32,
    bytes32[] memory agreeStateSiblings,
    bytes32 userOriginReputationKeyHash,
    bytes32[] memory userOriginReputationStateSiblings
    ) internal view
  {
    // We binary searched to the first disagreement, so the last agreement is the one before
    uint256 lastAgreeIdx = disputeRounds[u[U_ROUND]][u[U_IDX]].lowerBound - 1;

    bytes memory userOriginReputationValueBytes = abi.encodePacked(u[U_USER_ORIGIN_REPUTATION_VALUE], u[U_USER_ORIGIN_REPUTATION_UID]);

    bytes32 reputationRootHash = getImpliedRootNoHashKey(
      userOriginReputationKeyHash,
      userOriginReputationValueBytes,
      u[U_USER_ORIGIN_SKILL_REPUTATION_BRANCH_MASK],
      userOriginReputationStateSiblings
    );

    bytes memory jhLeafValue = abi.encodePacked(uint256(reputationRootHash), u[U_AGREE_STATE_NNODES]);

    // Prove that state is in our JRH, in the index corresponding to the last state that the two submissions agree on
    bytes32 impliedRoot = getImpliedRootNoHashKey(bytes32(lastAgreeIdx), jhLeafValue, u[U_AGREE_STATE_BRANCH_MASK], agreeStateSiblings);

    Submission storage submission = reputationHashSubmissions[disputeRounds[u[U_ROUND]][u[U_IDX]].firstSubmitter];
    if (impliedRoot == submission.jrh) {
      // They successfully proved the user origin value is in the lastAgreeState, so we're done here
      return;
    }
    require(u[U_USER_ORIGIN_REPUTATION_VALUE] == 0, "colony-reputation-mining-origin-reputation-nonzero");

    // Otherwise, maybe the user's origin skill doesn't exist. If that's true, they can prove it.
    // In which case, the proof they supplied should be for a reputation that proves the origin reputation doesn't exist in the tree
    require(
      checkKeyHashesAdjacent(userOriginReputationKeyHash, b32[B_ORIGIN_ADJACENT_REPUTATION_KEY_HASH], u[U_USER_ORIGIN_SKILL_REPUTATION_BRANCH_MASK]),
      "colony-reputation-mining-adjacent-origin-not-adjacent-or-already-exists"
    );
    // We assume that the proof they supplied is for the origin-adjacent reputation, not the origin reputation.
    // So use the key and value for the origin-adjacent reputation, but uid, branchmask and siblings that were supplied.
    bytes memory userOriginAdjacentReputationValueBytes = abi.encodePacked(
      u[U_USER_ORIGIN_ADJACENT_REPUTATION_VALUE],
      u[U_USER_ORIGIN_REPUTATION_UID]
    );

    // Check that the key supplied actually exists in the tree
    reputationRootHash = getImpliedRootNoHashKey(
      b32[B_ORIGIN_ADJACENT_REPUTATION_KEY_HASH],
      userOriginAdjacentReputationValueBytes,
      u[U_USER_ORIGIN_SKILL_REPUTATION_BRANCH_MASK],
      userOriginReputationStateSiblings
    );
    jhLeafValue = abi.encodePacked(uint256(reputationRootHash), u[U_AGREE_STATE_NNODES]);

    // Prove that state is in our JRH, in the index corresponding to the last state that the two submissions agree on
    impliedRoot = getImpliedRootNoHashKey(bytes32(lastAgreeIdx), jhLeafValue, u[U_AGREE_STATE_BRANCH_MASK], agreeStateSiblings);
    require(impliedRoot == submission.jrh, "colony-reputation-mining-origin-adjacent-proof-invalid");
  }

  function checkChildReputationInState(
    uint256[29] memory u,
    bytes32[] memory agreeStateSiblings,
    bytes memory childReputationKey,
    bytes32[] memory childReputationStateSiblings,
    bytes32 childAdjacentReputationKeyHash
    ) internal view
  {
    // We binary searched to the first disagreement, so the last agreement is the one before
    uint256 lastAgreeIdx = disputeRounds[u[U_ROUND]][u[U_IDX]].lowerBound - 1;

    bytes memory childReputationValueBytes = abi.encodePacked(u[U_CHILD_REPUTATION_VALUE], u[U_CHILD_REPUTATION_UID]);

    bytes32 reputationRootHash = getImpliedRootHashKey(
      childReputationKey,
      childReputationValueBytes,
      u[U_CHILD_REPUTATION_BRANCH_MASK],
      childReputationStateSiblings
    );

    bytes memory jhLeafValue = abi.encodePacked(uint256(reputationRootHash), u[U_AGREE_STATE_NNODES]);

    // Prove that state is in our JRH, in the index corresponding to the last state that the two submissions agree on
    bytes32 impliedRoot = getImpliedRootNoHashKey(bytes32(lastAgreeIdx), jhLeafValue, u[U_AGREE_STATE_BRANCH_MASK], agreeStateSiblings);

    Submission storage submission = reputationHashSubmissions[disputeRounds[u[U_ROUND]][u[U_IDX]].firstSubmitter];
    if (impliedRoot == submission.jrh) {
      // They successfully proved the user origin value is in the lastAgreeState, so we're done here
      return;
    }

    require(u[U_CHILD_REPUTATION_VALUE] == 0, "colony-reputation-mining-child-reputation-nonzero");

    // Otherwise, maybe the child skill doesn't exist. If that's true, they can prove it.
    // In which case, the proof they supplied should be for a reputation that proves the child reputation doesn't exist in the tree
    require(
      checkKeyHashesAdjacent(keccak256(childReputationKey), childAdjacentReputationKeyHash, u[U_CHILD_REPUTATION_BRANCH_MASK]),
      "colony-reputation-mining-adjacent-child-not-adjacent-or-already-exists"
    );
    // We assume that the proof they supplied is for the child-adjacent reputation, not the child reputation.
    // So use the key and value for the child-adjacent reputation, but uid, branchmask and siblings that were supplied.
    bytes memory childAdjacentReputationValueBytes = abi.encodePacked(u[U_CHILD_ADJACENT_REPUTATION_VALUE], u[U_CHILD_REPUTATION_UID]);

    // Check that the key supplied actually exists in the tree
    reputationRootHash = getImpliedRootNoHashKey(
      childAdjacentReputationKeyHash,
      childAdjacentReputationValueBytes,
      u[U_CHILD_REPUTATION_BRANCH_MASK],
      childReputationStateSiblings
    );
    jhLeafValue = abi.encodePacked(uint256(reputationRootHash), u[U_AGREE_STATE_NNODES]);

    // Prove that state is in our JRH, in the index corresponding to the last state that the two submissions agree on
    impliedRoot = getImpliedRootNoHashKey(bytes32(lastAgreeIdx), jhLeafValue, u[U_AGREE_STATE_BRANCH_MASK], agreeStateSiblings);
    require(impliedRoot == submission.jrh, "colony-reputation-mining-child-adjacent-proof-invalid");
  }

  function saveProvedReputation(uint256[29] memory u) internal {
    // Require that it is at least plausible
    uint256 delta = disputeRounds[u[U_ROUND]][u[U_IDX]].intermediateReputationNNodes - u[U_PREVIOUS_NEW_REPUTATION_UID];
    // Could be zero if this is an update to an existing reputation, or it could be 1 if we have just added a new
    // reputation. Anything else is inconsistent.
    // We don't care about over/underflowing, and don't want to use `sub` so that this require message is returned.
    require(delta == u[U_DISAGREE_STATE_NNODES]-u[U_AGREE_STATE_NNODES], "colony-reputation-mining-proved-uid-inconsistent");
    // Save the index for tiebreak scenarios later.
    disputeRounds[u[U_ROUND]][u[U_IDX]].provedPreviousReputationUID = u[U_PREVIOUS_NEW_REPUTATION_UID];
  }

  function buildReputationKey(bytes32 colony, bytes32 skill, bytes32 user) internal pure returns (bytes memory) {
    bytes memory reputationKey = new bytes(72);
    assembly {
        mstore(add(reputationKey, 32), shl(96, colony))
        mstore(add(reputationKey, 72), user)
        mstore(add(reputationKey, 52), skill)
    }
    return reputationKey;
  }
}
