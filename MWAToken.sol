// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MWAToken
 * @notice Токен проекта MWA, обеспеченный RWA активом.
 *         Vault может минтить токены при выкупе, а также сжигать их при buyback.
 */
contract MWAToken is ERC20, Ownable {
    address public vaultContract;
    address public redemptionContract;

    event VaultUpdated(address indexed vault);
    event RedemptionUpdated(address indexed redemption);

    modifier onlyVault() {
        require(msg.sender == vaultContract, "MWAToken: only vault");
        _;
    }

    modifier onlyRedemption() {
        require(msg.sender == redemptionContract, "MWAToken: only redemption");
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address _vault
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        vaultContract = _vault;
    }

    /// @notice Минтинг только через Vault (при покупке или выкупе)
    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    /// @notice Сжигание от самого держателя (обычный burn)
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Сжигание от имени Redemption контракта (для buybackAndBurn)
    /// @dev Используется, когда автор выкупает токены у держателей и сжигает их
    function burnFrom(address account, uint256 amount) external onlyRedemption {
        _burn(account, amount);
    }

    /// @notice Сжигание собственных токенов контракта (для выкупленных токенов)
    function burnHeld(uint256 amount) external onlyRedemption {
        _burn(address(this), amount);
    }

    function setVault(address _vault) external onlyOwner {
        vaultContract = _vault;
        emit VaultUpdated(_vault);
    }

    function setRedemption(address _redemption) external onlyOwner {
        redemptionContract = _redemption;
        emit RedemptionUpdated(_redemption);
    }
}
