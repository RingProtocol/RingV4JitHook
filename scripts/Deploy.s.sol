// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {RingV4JitHook} from "../src/hooks/RingV4JitHook.sol";
import {RingLPRouter} from "../src/routers/RingLPRouter.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";

/// @notice Deploy `RingV4JitHook` and `RingLPRouter` to a live network.
/// @dev    The hook address must carry the permission flags `0x2AC0` in its low
///         14 bits, so the script mines a CREATE2 salt against the broadcaster
///         address before deploying with `new{salt:}`.
///
/// Env: POOL_MANAGER_ADDR, FEW_FACTORY_ADDR
///      OWNER (default: broadcaster)
///      SALT / SALT_START (optional, for resuming a salt search)
///      MAX_MINING_ITER (default 5_000_000)
///
/// Usage (Ethereum mainnet):
///   forge script scripts/Deploy.s.sol:Deploy \
///     --rpc-url $MAINNET_RPC_URL --private-key $PRIVATE_KEY --broadcast -vv
contract Deploy is Script {
    /// @notice Required permission flags in the hook address low 14 bits.
    uint160 internal constant REQUIRED_FLAGS = 0x2AC0;
    uint160 internal constant FLAG_MASK = 0x3FFF;

    function run() public returns (address hook, address router) {
        IPoolManager manager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDR"));
        IFewFactory few = IFewFactory(vm.envAddress("FEW_FACTORY_ADDR"));
        address owner = vm.envOr("OWNER", msg.sender);
        uint256 maxIter = vm.envOr("MAX_MINING_ITER", uint256(5_000_000));

        require(address(manager).code.length > 0, "POOL_MANAGER_ADDR has no code");
        require(address(few).code.length > 0, "FEW_FACTORY_ADDR has no code");

        // ------------------------------------------------------------------
        // 1. Mine a CREATE2 salt so the hook address carries the flags 0x2AC0.
        // ------------------------------------------------------------------
        bytes memory creationCode = type(RingV4JitHook).creationCode;
        bytes memory constructorArgs = abi.encode(manager, few, owner);
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));
        address predicted = _computeAddress(msg.sender, salt, initCodeHash);

        if (uint160(predicted) & FLAG_MASK != REQUIRED_FLAGS) {
            uint256 start = vm.envOr("SALT_START", uint256(0));
            (salt, predicted) = _mineSalt(msg.sender, initCodeHash, start, maxIter);
        }
        require(uint160(predicted) & FLAG_MASK == REQUIRED_FLAGS, "mined address flags mismatch");

        console2.log("Deployer (broadcaster):", msg.sender);
        console2.log("Owner:", owner);
        console2.log("PoolManager:", address(manager));
        console2.log("FewFactory:", address(few));
        console2.log("Mined salt:");
        console2.logBytes32(salt);
        console2.log("Predicted hook address:", predicted);

        // ------------------------------------------------------------------
        // 2. Broadcast: deploy hook (CREATE2) and router (CREATE).
        // ------------------------------------------------------------------
        vm.startBroadcast();
        hook = address(new RingV4JitHook{salt: salt}(manager, few, owner));
        router = address(new RingLPRouter(manager));
        vm.stopBroadcast();

        require(hook == predicted, "deployed hook address mismatch");
        require(RingV4JitHook(hook).getHookPermissions().beforeSwap, "hook permissions not set");

        // ------------------------------------------------------------------
        // 3. Log deployed addresses for downstream scripts / verification.
        // ------------------------------------------------------------------
        console2.log("=== Deployed addresses ===");
        console2.log("RING_V4_JIT_HOOK_ADDR=", hook);
        console2.log("RING_LP_ROUTER_ADDR=", router);
        console2.log("OWNER=", owner);
        console2.log("SALT=", uint256(salt));
    }

    /// @dev Compute the CREATE2 address for `(deployer, salt, initCodeHash)`.
    function _computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), bytes20(deployer), salt, initCodeHash));
        return address(uint160(uint256(hash)));
    }

    /// @dev Mine a salt starting from `start` until the predicted address matches
    ///      the required flags, or revert after `maxIter` attempts.
    function _mineSalt(address deployer, bytes32 initCodeHash, uint256 start, uint256 maxIter)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i = 0; i < maxIter; ++i) {
            salt = bytes32(start + i);
            predicted = _computeAddress(deployer, salt, initCodeHash);
            if (uint160(predicted) & FLAG_MASK == REQUIRED_FLAGS) {
                return (salt, predicted);
            }
        }
        revert("Deploy: no salt found within MAX_MINING_ITER");
    }
}
