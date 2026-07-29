// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MWAVault is Ownable {
    struct Deposit {
        address assetAddress;
        uint256 assetId;
        uint256 tokenAmount;
        uint256 redemptionDeadline;
        bool isRedeemed;
        bool isClaimed;
        address priceFeed;
    }

    mapping(uint256 => Deposit) public deposits;
    uint256 public depositCounter;
    bool private _locked;

    address public mwaToken;
    address public priceOracle;

    event AssetDeposited(uint256 indexed depositId, address indexed owner, uint256 amount);
    event AssetRedeemed(uint256 indexed depositId, address indexed redeemer);
    event AssetClaimed(uint256 indexed depositId, address indexed claimer);

    modifier noReentrancy() {
        require(!_locked, "Reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address _mwaToken, address _priceOracle) {
        mwaToken = _mwaToken;
        priceOracle = _priceOracle;
    }

    function depositRWA(
        address assetAddress,
        uint256 assetId,
        uint256 tokenAmount,
        uint256 lockDurationMonths
    ) external noReentrancy returns (uint256 depositId) {
        IERC721(assetAddress).transferFrom(msg.sender, address(this), assetId);

        depositId = ++depositCounter;
        deposits[depositId] = Deposit({
            assetAddress: assetAddress,
            assetId: assetId,
            tokenAmount: tokenAmount,
            redemptionDeadline: block.timestamp + (lockDurationMonths * 30 days),
            isRedeemed: false,
            isClaimed: false,
            priceFeed: priceOracle
        });

        emit AssetDeposited(depositId, msg.sender, tokenAmount);
    }

    function getDeposit(uint256 depositId) external view returns (Deposit memory) {
        return deposits[depositId];
    }
}
