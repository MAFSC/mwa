// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./MWAToken.sol";

/**
 * @title MWATokenFactory
 * @notice Фабрика для создания кастомных MEME-токенов под залог RWA.
 *         Каждый токен создаётся с собственным именем/символом и привязывается к Vault.
 */
contract MWATokenFactory {
    event TokenCreated(
        address indexed token,
        string name,
        string symbol,
        address indexed creator,
        address vault
    );

    function createToken(
        string memory name,
        string memory symbol,
        address vault
    ) external returns (address) {
        MWAToken newToken = new MWAToken(name, symbol, vault);
        emit TokenCreated(address(newToken), name, symbol, msg.sender, vault);
        return address(newToken);
    }
}
