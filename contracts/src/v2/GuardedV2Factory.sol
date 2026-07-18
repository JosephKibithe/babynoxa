// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity =0.5.16;

import "./GuardedV2Pair.sol";

/// @notice Dedicated factory for official BabyNoxa pairs.
/// @dev Only the launch factory can create a pair, and every pair requires its immutable-at-launch
///      bootstrap manager. Optional V2 protocol fees are permanently disabled.
contract GuardedV2Factory {
    address public feeTo;
    address public feeToSetter;
    address public launchFactory;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256);
    event BootstrapManagerAssigned(address indexed pair, address indexed bootstrapManager);

    constructor(address _launchFactory) public {
        require(_launchFactory != address(0), "BabyNoxaV2: ZERO_LAUNCH_FACTORY");
        launchFactory = _launchFactory;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    /// @dev Standard permissionless pair creation is intentionally unavailable.
    function createPair(address, address) external pure returns (address) {
        revert("BabyNoxaV2: MANAGER_REQUIRED");
    }

    function createPair(address tokenA, address tokenB, address bootstrapManager) external returns (address pair) {
        require(msg.sender == launchFactory, "BabyNoxaV2: NOT_LAUNCH_FACTORY");
        require(bootstrapManager != address(0), "BabyNoxaV2: ZERO_MANAGER");
        require(tokenA != tokenB, "BabyNoxaV2: IDENTICAL_ADDRESSES");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "BabyNoxaV2: ZERO_ADDRESS");
        require(getPair[token0][token1] == address(0), "BabyNoxaV2: PAIR_EXISTS");

        bytes memory bytecode = type(GuardedV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        require(pair != address(0), "BabyNoxaV2: PAIR_DEPLOYMENT_FAILED");
        GuardedV2Pair(pair).initialize(token0, token1, bootstrapManager);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
        emit BootstrapManagerAssigned(pair, bootstrapManager);
    }
}
