// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MWAToken
 * @notice Кастомный токен с произвольными именем и символом
 */
contract MWAToken is ERC20, Ownable {
    address public vaultContract;

    modifier onlyVault() {
        require(msg.sender == vaultContract, "Only vault can mint");
        _;
    }

    constructor(
        string memory name,
        string memory symbol,
        address _vault
    ) ERC20(name, symbol) Ownable(msg.sender) {
        vaultContract = _vault;
    }

    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function setVault(address _vault) external onlyOwner {
        vaultContract = _vault;
    }
}

/**
 * @title MWATokenFactory
 * @notice Фабрика для создания кастомных токенов
 */
contract MWATokenFactory {
    event TokenCreated(address indexed token, string name, string symbol, address indexed owner);

    function createToken(
        string memory name,
        string memory symbol,
        address vault
    ) external returns (address) {
        MWAToken newToken = new MWAToken(name, symbol, vault);
        emit TokenCreated(address(newToken), name, symbol, msg.sender);
        return address(newToken);
    }
}
