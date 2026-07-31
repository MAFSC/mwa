// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MWAToken is ERC20, Ownable {
    address public vaultContract;

    modifier onlyVault() {
        require(msg.sender == vaultContract, "Only vault can mint");
        _;
    }

    constructor(address _vault) ERC20("Meme World Assets", "MWA") {
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
