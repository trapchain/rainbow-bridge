pragma solidity ^0.5.0;
pragma experimental ABIEncoderV2; // solium-disable-line no-experimental

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "./NearDecoder.sol";
import "./ED25519.sol";


contract NearBridge is Ownable {
    using SafeMath for uint256;
    using Borsh for Borsh.Data;
    using NearDecoder for Borsh.Data;

    struct State {
        uint256 height;
        bytes32 epochId;
        bytes32 nextEpochId;
        address submitter;
        uint256 validAfter;
        bytes32 hash;
    }

    uint256 constant public LOCK_ETH_AMOUNT = 1 ether;
    uint256 constant public LOCK_DURATION = 1 hours;

    State public last;
    State public prev;
    mapping(uint256 => bytes32) public blockHashes;
    mapping(address => uint256) public balanceOf;

    event BlockHashAdded(
        uint256 indexed height,
        bytes32 blockHash
    );

    constructor(bytes32 firstEpochId, bytes32 firstNextEpochId) public {
        last.epochId = firstEpochId;
        last.nextEpochId = firstNextEpochId;
    }

    function deposit() public payable {
        require(msg.value == LOCK_ETH_AMOUNT && balanceOf[msg.sender] == 0);
        balanceOf[msg.sender] = balanceOf[msg.sender].add(msg.value);
    }

    function withdraw() public {
        balanceOf[msg.sender] = balanceOf[msg.sender].sub(LOCK_ETH_AMOUNT);
        msg.sender.transfer(LOCK_ETH_AMOUNT);
    }

    function validate(address user, address payable receiver, bytes memory data) public {
        require(last.hash == keccak256(data), "Data did not match");
        require(block.timestamp < last.validAfter, "Lock period already passed");

        Borsh.Data memory borsh = Borsh.from(data);
        NearDecoder.LightClientBlock memory nearBlock = borsh.decodeLightClientBlock();
        bytes32 nearBlockHash = hash(nearBlock);
        bytes32 nearBlockNextHash = nextHash(nearBlock, nearBlockHash);

        // 4. approvals_next and approvals_after_next contain signatures that check out against the block producers for the epoch of the block
        // 5. The signatures present in both approvals_next and approvals_after_next correspond to more than 2/3 of the total stake
        uint256 totalStake = 0;
        for (uint i = 0; i < nearBlock.next_bps.validatorStakes.length; i++) {
            totalStake = totalStake.add(
                nearBlock.next_bps.validatorStakes[i].stake
            );
        }
        require(
            _checkValidatorSignatures(
                totalStake,
                nearBlockHash,
                nearBlock.approvals_next,
                nearBlock.next_bps.validatorStakes
            ),
            "NearBridge: Less than 2/3 voted by the next block"
        );
        require(
            _checkValidatorSignatures(
                totalStake,
                nearBlockNextHash,
                nearBlock.approvals_after_next,
                nearBlock.next_bps.validatorStakes
            ),
            "NearBridge: Less than 2/3 voted by the block after next"
        );

        // Pay reward
        balanceOf[user] = balanceOf[user].sub(LOCK_ETH_AMOUNT);
        receiver.transfer(LOCK_ETH_AMOUNT);

        // Erase last state
        delete blockHashes[last.height];
        last = prev;
    }

    function addLightClientBlock(bytes memory data) public payable {
        require(balanceOf[msg.sender] >= LOCK_ETH_AMOUNT, "Balance is not enough");
        require(block.timestamp >= last.validAfter, "Wait until last block become valid");

        Borsh.Data memory borsh = Borsh.from(data);
        NearDecoder.LightClientBlock memory nearBlock = borsh.decodeLightClientBlock();
        require(borsh.finished(), "NearBridge: only light client block should be passed");
        bytes32 nearBlockHash = hash(nearBlock);

        // 1. The height of the block is higher than the height of the current head
        require(
            nearBlock.inner_lite.height > last.height,
            "NearBridge: Height of the block is not valid"
        );

        // 2. The epoch of the block is equal to the epoch_id or next_epoch_id known for the current head
        require(
            nearBlock.inner_lite.epoch_id == last.epochId || nearBlock.inner_lite.epoch_id == last.nextEpochId,
            "NearBridge: Epoch id of the block is not valid"
        );

        // 3. If the epoch of the block is equal to the next_epoch_id of the head, then next_bps is not None
        if (nearBlock.inner_lite.epoch_id == last.nextEpochId) {
            require(
                !nearBlock.next_bps.none,
                "NearBridge: Next bps should no be None"
            );
        }

        // 4. approvals_next and approvals_after_next contain signatures that check out against the block producers for the epoch of the block
        // 5. The signatures present in both approvals_next and approvals_after_next correspond to more than 2/3 of the total stake
        // uint256 totalStake = 0;
        // for (uint i = 0; i < nearBlock.next_bps.validatorStakes.length; i++) {
        //     totalStake = totalStake.add(
        //         nearBlock.next_bps.validatorStakes[i].stake
        //     );
        // }
        // require(
        //     _checkValidatorSignatures(
        //         totalStake,
        //         nearBlockHash,
        //         nearBlock.approvals_next,
        //         nearBlock.next_bps.validatorStakes
        //     ),
        //     "NearBridge: Less than 2/3 voted by the next block"
        // );
        // require(
        //     _checkValidatorSignatures(
        //         totalStake,
        //         nearBlockNextHash,
        //         nearBlock.approvals_after_next,
        //         nearBlock.next_bps.validatorStakes
        //     ),
        //     "NearBridge: Less than 2/3 voted by the block after next"
        // );

        // 6. If next_bps is not none, sha256(borsh(next_bps)) corresponds to the next_bp_hash in inner_lite.
        if (!nearBlock.next_bps.none) {
            require(
                nearBlock.next_bps.hash == nearBlock.inner_lite.next_bp_hash,
                "NearBridge: Hash of block producers do not match"
            );
        }

        // Finish:
        prev = last;
        last = State({
            height: nearBlock.inner_lite.height,
            epochId: nearBlock.inner_lite.epoch_id,
            nextEpochId: nearBlock.inner_lite.next_epoch_id,
            submitter: msg.sender,
            validAfter: block.timestamp.add(LOCK_DURATION),
            hash: keccak256(data)
        });
        blockHashes[nearBlock.inner_lite.height] = nearBlockHash;
        emit BlockHashAdded(
            last.height,
            blockHashes[last.height]
        );
    }

    function _checkValidatorSignatures(
        uint256 totalStake,
        bytes32 next_block_inner_hash,
        NearDecoder.OptionalED25519Signature[] memory approvals,
        NearDecoder.ValidatorStake[] memory validatorStakes
    ) internal view returns(bool) {
        uint256 votedFor = 0;
        uint256 votedAgainst = 0;
        for (uint i = 0; i < approvals.length; i++) {
            if (approvals[i].none) {
                votedAgainst = votedAgainst.add(validatorStakes[i].stake);
            } else {
                require(
                    ED25519.verify(
                        next_block_inner_hash,
                        validatorStakes[i].public_key.xy,
                        approvals[i].signature.rs
                    ),
                    "NearBridge: Validator signature is not valid"
                );
                votedFor = votedFor.add(validatorStakes[i].stake);
            }

            if (votedFor > totalStake.mul(2).div(3)) {
                return true;
            }
            if (votedAgainst >= totalStake.mul(1).div(3)) {
                return false;
            }
        }

        revert("NearBridge: Should never be reached");
    }

    function hash(NearDecoder.LightClientBlock memory nearBlock) public view returns(bytes32) {
        return keccak256(abi.encodePacked(
            nearBlock.prev_block_hash,
            keccak256(abi.encodePacked(
                nearBlock.inner_lite.hash,
                nearBlock.inner_rest_hash
            ))
        ));
    }

    function nextHash(NearDecoder.LightClientBlock memory nearBlock, bytes32 currentHash) public view returns(bytes32) {
        return keccak256(abi.encodePacked(
            currentHash,
            nearBlock.next_block_inner_hash
        ));
    }
}
