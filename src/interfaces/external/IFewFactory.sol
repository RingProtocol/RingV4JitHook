// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

/// @notice Minimal interface for FewFactory — only the read functions needed by hooks.
interface IFewFactory {
    function getWrappedToken(address originalToken) external view returns (address wrappedToken);
    function createToken(address originalToken) external returns (address wrappedToken);
}
