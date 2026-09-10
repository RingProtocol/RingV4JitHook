// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFewFactory} from "../src/interfaces/external/IFewFactory.sol";
import {IFewWrappedToken} from "../src/interfaces/external/IFewWrappedToken.sol";

/// @notice Minimal FewWrappedToken mock: 1:1 wrap/unwrap against the underlying ERC20.
contract MockFewWrappedToken is IFewWrappedToken {
    address public immutable token;
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address _token) {
        token = _token;
        name = "fwTEST";
        symbol = "fwTEST";
    }

    function wrap(uint256 amount) external returns (uint256) {
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "wrap transferFrom");
        _mint(msg.sender, amount);
        return amount;
    }

    function unwrap(uint256 amount) external returns (uint256) {
        _burn(msg.sender, amount);
        require(IERC20(token).transfer(msg.sender, amount), "unwrap transfer");
        return amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Minimal FewFactory mock: lazily creates a 1:1 wrapped token per underlying.
contract MockFewFactory is IFewFactory {
    mapping(address => address) public wrapped;
    address[] public allWrapped;

    function getWrappedToken(address originalToken) public view returns (address wrappedToken) {
        return wrapped[originalToken];
    }

    function createToken(address originalToken) external returns (address wrappedToken) {
        require(wrapped[originalToken] == address(0), "exists");
        MockFewWrappedToken t = new MockFewWrappedToken(originalToken);
        wrapped[originalToken] = address(t);
        allWrapped.push(address(t));
        return address(t);
    }

    /// @dev Test helper: create the wrapped token for a token and return it.
    function create(address originalToken) external returns (MockFewWrappedToken) {
        if (wrapped[originalToken] == address(0)) {
            this.createToken(originalToken);
        }
        return MockFewWrappedToken(wrapped[originalToken]);
    }

    function setWrapped(address originalToken, address wrappedToken) external {
        wrapped[originalToken] = wrappedToken;
    }
}

/// @notice CREATE2 helper so the test can deploy the hook at an address whose low 14 bits match
///         the required permission flags.
library HookMiner {
    function mine(address deployer, bytes memory creationCode, bytes memory args, uint160 flags, uint256 maxIter)
        internal
        pure
        returns (bytes32 salt, address predicted)
    {
        bytes memory initCode = bytes.concat(creationCode, args);
        bytes32 codeHash = keccak256(initCode);
        for (uint256 i = 0; i < maxIter; i++) {
            salt = bytes32(i);
            bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), bytes20(deployer), salt, codeHash));
            predicted = address(uint160(uint256(hash)));
            if (uint160(predicted) & 0x3FFF == flags) {
                return (salt, predicted);
            }
        }
        revert("no salt found");
    }
}
