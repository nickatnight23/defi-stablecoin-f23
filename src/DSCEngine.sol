// SPDX-License-Identifier:MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Latricia Nickelberry
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algoritmically Stable
 *
 * It is similar to DAI if DAI has no governance, no fees, and was only backed by WETH and WBTC
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the DSC
 *
 * @notice This contract is the core of the DSC system. It handles all of the logic for minting and redeeming DSC, as well as depositing & withdrawing collateral
 * @notice This contract is VERY loosely based on the MakerDao DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    ////////////
    // Errors///
    ////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    /////////////////
    // State variables//
    /////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means a 10% bonus


    mapping(address collateralToken => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;
    /////////////////
    // Events////////
    /////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom,address indexed redeemedTo, address indexed token, uint256 amount);

    ////////////
    // Modifiers
    ////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }
    ////////////
    // Functions
    ////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // For example ETH/USD, BTC/USD, MKR/USD, etc...
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            // looping through token addresses array
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i]; // token of i is going to = the priceFeed of i // if they have a pricefeed they are allowed
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////
    // External Functions//
    ////////////////////

    /*
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @notice follows CEI(Checks, Effects, interactions)
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amout of the collateral to deposit
     *
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
       bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
       if(!success) {
        revert DSCEngine__TransferFailed();
       }
    }
        /*
         * @param tokenCollateralAddress The collateral address to redeem
         * @param amountCollateral The amount of collateral to redeem
         * @param amountDscToBurn The amount of DSC to burn
         * This function burns DSC and redeems underlying collateral in on transaction
         */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks health factor
    }

    // in order to redeem collateral:
    // 1. health factor must be over 1 AFTER collateral pulled

    // CEI: Check, Effects, Interactions
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHeathFactorIsBroken(msg.sender);
    }
    
    /*
     * @notice follows CEI
     * @param amountDscToMint The amount of decentalized stablecoin to mint
     * @notice they must have more collaeral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant{
        s_DSCMinted[msg.sender] += amountDscToMint;
        // If they minted too much ($150 DSC, $100 ETH)
        _revertIfHeathFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // Threshold to let's say 150%
    // $100 ETH -> $0
    // $0 DSC
    // UNDERCOLLATERALIZED!!!

    // I'll pay back the $50 DSC -> Get all of your collateral!
    // $74 ETH
    // -$50 DSC
    // $24

    function burnDsc(uint256 amount) public moreThanZero(amount){
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHeathFactorIsBroken(msg.sender); // I don't think this would ever hit...
    }

    // If we do start nearing undercollateralization, we need someone to liquidate positions
    // If someone is almost undercollaterzlized, we will pay you to liquidate them!

    /*
     * @param collateral the erc20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor. Their _healthFactor should be below the MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     * @notice you can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds.
     * @notice This function working assumes the protocol will be roughly 200% overcollaterzlized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
                // need to check health factor of the user
                uint256 startingUserHealthFactor = _healthFactor(user);
              if(startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
                revert DSCEngine__HealthFactorOk();
              }
              // We want to burn their DSC "debt"
              // And take their collateral
              // Bad User: $140 ETH, $100 DSC
              // debtToCover = $100
              // $100 of DSC == ??? ETH?
              // 0.05 ETH
              uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
              // And give them a 10% bonus
              // So we are giving the liquidator $110 of WETH for 100 DSC
              // We should implement a feature to liquidate in the event the protocol is insolvent
              // And sweep extra amounts into treasury

              // 0.05 * 0.1 = 0.005. Getting 0.055
              uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
              uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
              _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
              // We need to burn the DSC
              _burnDsc(debtToCover, user, msg.sender);

              uint256 endingUserHealthFactor = _healthFactor(user);
              if(endingUserHealthFactor <= startingUserHealthFactor) {
                revert DSCEngine__HealthFactorNotImproved();
              }
               _revertIfHeathFactorIsBroken(msg.sender);
    }
        

    function getHealthFactor() external view {}

     ///////////////////////////////////
    //Private & Internal View Functions//
    ////////////////////////////////////

    /*
     * @dev Low-level internal function, do not call unless the function calling it is
     * checking for health factors being broken
     */    
    function _burnDsc(uint256 amountDscToBurn, address onBehalOf, address dscFrom) private {
          s_DSCMinted[onBehalOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address from,address to, address tokenCollateralAddress, uint256 amountCollateral) private {
         s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from,to,tokenCollateralAddress,amountCollateral);
        //_calculateHealthFactorAfter()
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
            totalDscMinted = s_DSCMinted[user];
            collateralValueInUsd = getAccountCollateralValue(user);
    }
    /**
     * Returns how close to liquidation a user is
     * If a users goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
         uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
         return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;

        // 1000 ETH * 50 = 50,000/ 100  = 500
        //$150 ETH / 100 DSC = 1.5(decimals do not work in solidity so this would be 1)
        //150 * 50 = 7500 / 100 = (75 / 100) < 1

        // $1000 ETH / 100 DSC
        // 1000 * 50 = 5000 / 100 = (500/100) > 1
    }

    function _revertIfHeathFactorIsBroken(address user) internal view {
        // 1. Check health factor (do they have enough collateral?)
        // 2. Revert if they don't
       uint256 userHealthFactor = _healthFactor(user);
       if(userHealthFactor < MIN_HEALTH_FACTOR) {
         revert DSCEngine__BreaksHealthFactor(userHealthFactor);
       }
    }

    ///////////////////////////////////
    //Public & External View Functions//
    ////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256) {
        // price of ETH(token)
        // $/ETH ETH ??
        // $2000 / ETH. $1000 = 0.5 ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited, and map
        // the price, to get the USD value
        for(uint256 i = 0; i< s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $1000
        // The returned value from CL be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; //(1000 * 1e8 * (1e10)) * 1000 * 1e18;
    }


    function getAccountInformation(address user) external view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }
}
