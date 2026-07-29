// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface MWAVaultInterface {
    struct Deposit {
        address assetAddress;
        uint256 assetId;
        uint256 tokenAmount;
        uint256 redemptionDeadline;
        bool isRedeemed;
        bool isClaimed;
        address priceFeed;
    }
    function getDeposit(uint256 depositId) external view returns (Deposit memory);
    function owner() external view returns (address);
}

interface MWATokenInterface {
    function burn(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

contract MWARedemption {
    address public vault;
    address public mwaToken;
    bool private _locked;

    event AssetRedeemed(uint256 indexed depositId, address indexed redeemer);
    event AssetClaimed(uint256 indexed depositId, address indexed claimer, uint256 share);

    modifier noReentrancy() {
        require(!_locked, "Reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address _vault, address _mwaToken) {
        vault = _vault;
        mwaToken = _mwaToken;
    }

    function redeem(uint256 depositId) external noReentrancy {
        MWAVaultInterface.Deposit memory deposit = MWAVaultInterface(vault).getDeposit(depositId);
        require(!deposit.isRedeemed, "Already redeemed");
        require(block.timestamp <= deposit.redemptionDeadline, "Deadline passed");
        require(msg.sender == MWAVaultInterface(vault).owner(), "Only owner can redeem");

        MWATokenInterface(mwaToken).burn(deposit.tokenAmount);

        IERC721(deposit.assetAddress).transferFrom(
            address(vault),
            msg.sender,
            deposit.assetId
        );

        emit AssetRedeemed(depositId, msg.sender);
    }

    function claimAsset(uint256 depositId) external noReentrancy {
        MWAVaultInterface.Deposit memory deposit = MWAVaultInterface(vault).getDeposit(depositId);
        require(!deposit.isRedeemed, "Already redeemed");
        require(!deposit.isClaimed, "Already claimed");
        require(block.timestamp > deposit.redemptionDeadline, "Deadline not passed");

        uint256 userBalance = MWATokenInterface(mwaToken).balanceOf(msg.sender);
        require(userBalance > 0, "No MWA tokens");

        uint256 share = (userBalance * 100) / deposit.tokenAmount;

        emit AssetClaimed(depositId, msg.sender, share);
    }
}
