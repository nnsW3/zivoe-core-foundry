// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.16;

import "./libraries/FloorMath.sol";

import "./lockers/Utility/ZivoeSwapper.sol";

import "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import "../lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface YDL_IZivoeRewards {
    /// @notice Deposits a reward to this contract for distribution.
    /// @param  _rewardsToken The asset that's being distributed.
    /// @param  reward The amount of the _rewardsToken to deposit.
    function depositReward(address _rewardsToken, uint256 reward) external;
}

interface YDL_IZivoeGlobals {
    /// @notice Returns the address of the Timelock contract.
    function TLC() external view returns (address);

    /// @notice Returns the address of the ZivoeITO contract.
    function ITO() external view returns (address);

    /// @notice Returns the address of the ZivoeDAO contract.
    function DAO() external view returns (address);

    /// @notice Returns the address of the ZivoeTrancheToken ($zSTT) contract.
    function zSTT() external view returns (address);

    /// @notice Returns the address of the ZivoeTrancheToken ($zJTT) contract.
    function zJTT() external view returns (address);

    /// @notice Returns true if an address is whitelisted as a keeper.
    /// @return keeper Equals "true" if address is a keeper, "false" if not.
    function isKeeper(address) external view returns (bool keeper);

    /// @notice Handles WEI standardization of a given asset amount (i.e. 6 decimal precision => 18 decimal precision).
    /// @param  amount The amount of a given "asset".
    /// @param  asset The asset (ERC-20) from which to standardize the amount to WEI.
    /// @return standardizedAmount The above amount standardized to 18 decimals.
    function standardize(uint256 amount, address asset) external view returns (uint256 standardizedAmount);

    /// @notice Returns total circulating supply of zSTT and zJTT, accounting for defaults via markdowns.
    /// @return zSTTSupply zSTT.totalSupply() adjusted for defaults.
    /// @return zJTTSupply zJTT.totalSupply() adjusted for defaults.
    function adjustedSupplies() external view returns (uint256 zSTTSupply, uint256 zJTTSupply);

    /// @notice This function will verify if a given stablecoin has been whitelisted for use throughout system (ZVE, YDL).
    /// @param  stablecoin address of the stablecoin to verify acceptance for.
    /// @return whitelisted Will equal "true" if stabeloin is acceptable, and "false" if not.
    function stablecoinWhitelist(address stablecoin) external view returns (bool whitelisted);
    
    /// @notice Returns the address of the ZivoeRewards ($zSTT) contract.
    function stSTT() external view returns (address);

    /// @notice Returns the address of the ZivoeRewards ($zJTT) contract.
    function stJTT() external view returns (address);

    /// @notice Returns the address of the ZivoeRewards ($ZVE) contract.
    function stZVE() external view returns (address);

    /// @notice Returns the address of the ZivoeRewardsVesting ($ZVE) vesting contract.
    function vestZVE() external view returns (address);
}

/// @notice  This contract manages the accounting for distributing yield across multiple contracts.
///          This contract has the following responsibilities:
///            - Escrows yield in between distribution periods.
///            - Manages accounting for yield distribution.
///            - Supports modification of certain state variables for governance purposes.
///            - Tracks historical values using EMA (exponential moving average) on 30-day basis.
///            - Facilitates arbitrary swaps from non-distributeAsset tokens to distributedAsset tokens.
contract ZivoeYDL is Ownable, ReentrancyGuard, ZivoeSwapper {

    using SafeERC20 for IERC20;
    using FloorMath for uint256;

    // ---------------------
    //    State Variables
    // ---------------------

    struct Recipients {
        address[] recipients;
        uint256[] proportion;
    }

    Recipients protocolRecipients;          /// @dev Tracks the distributions for protocol earnings.
    Recipients residualRecipients;          /// @dev Tracks the distributions for residual earnings.

    address public immutable GBL;           /// @dev The ZivoeGlobals contract.

    address public distributedAsset;        /// @dev The "stablecoin" that will be distributed via YDL.
    
    bool public unlocked;                   /// @dev Prevents contract from supporting functionality until unlocked.

    // Weighted moving averages.
    uint256 public emaSTT;                  /// @dev Weighted moving average for senior tranche size, a.k.a. zSTT.totalSupply().
    uint256 public emaJTT;                  /// @dev Weighted moving average for junior tranche size, a.k.a. zJTT.totalSupply().
    uint256 public emaYield;                /// @dev Weighted moving average for yield distributions.

    // Indexing.
    uint256 public numDistributions;        /// @dev # of calls to distributeYield() starts at 0, computed on current index for moving averages.
    uint256 public lastDistribution;        /// @dev Used for timelock constraint to call distributeYield().

    // Accounting vars (governable).
    uint256 public targetAPYBIPS = 800;                 /// @dev The target annualized yield for senior tranche.
    uint256 public targetRatioBIPS = 16250;             /// @dev The target ratio of junior to senior tranche.
    uint256 public protocolEarningsRateBIPS = 2000;     /// @dev The protocol earnings rate.

    // Accounting vars (constant).
    uint256 public constant daysBetweenDistributions = 30;   /// @dev Number of days between yield distributions.
    uint256 public constant retrospectiveDistributions = 6;  /// @dev The # of distributions to track historical (weighted) performance.

    uint256 private constant BIPS = 10000;
    uint256 private constant WAD = 10 ** 18;
    uint256 private constant RAY = 10 ** 27;



    // -----------------
    //    Constructor
    // -----------------

    /// @notice Initialize the ZivoeYDL contract.
    /// @param  _GBL The ZivoeGlobals contract.
    /// @param  _distributedAsset The "stablecoin" that will be distributed via YDL.
    constructor(address _GBL, address _distributedAsset) {
        GBL = _GBL;
        distributedAsset = _distributedAsset;
    }



    // ------------
    //    Events
    // ------------

    /// @notice Emitted during recoverAsset().
    /// @param  asset The asset recovered from this contract (migrated to DAO).
    /// @param  amount The amount recovered.
    event AssetRecovered(address indexed asset, uint256 amount);

    /// @notice Emitted during convert().
    /// @param  fromAsset The asset converted from.
    /// @param  amountConverted The amount of "fromAsset" specified for conversion. 
    /// @param  amountReceived The amount of "distributedAsset" received while converting.
    event AssetConverted(address indexed fromAsset, uint256 amountConverted, uint256 amountReceived);

    /// @notice Emitted during setTargetAPYBIPS().
    /// @param  oldValue The old value of targetAPYBIPS.
    /// @param  newValue The new value of targetAPYBIPS.
    event UpdatedTargetAPYBIPS(uint256 oldValue, uint256 newValue);

    /// @notice Emitted during setTargetRatioBIPS().
    /// @param  oldValue The old value of targetRatioBIPS.
    /// @param  newValue The new value of targetRatioBIPS.
    event UpdatedTargetRatioBIPS(uint256 oldValue, uint256 newValue);

    /// @notice Emitted during setProtocolEarningsRateBIPS().
    /// @param  oldValue The old value of protocolEarningsRateBIPS.
    /// @param  newValue The new value of protocolEarningsRateBIPS.
    event UpdatedProtocolEarningsRateBIPS(uint256 oldValue, uint256 newValue);

    /// @notice Emitted during setDistributedAsset().
    /// @param  oldAsset The old asset of distributedAsset.
    /// @param  newAsset The new asset of distributedAsset.
    event UpdatedDistributedAsset(address indexed oldAsset, address indexed newAsset);

    /// @notice Emitted during updateProtocolRecipients().
    /// @param  recipients The new recipients to receive protocol earnings.
    /// @param  proportion The proportion distributed across recipients.
    event UpdatedProtocolRecipients(address[] recipients, uint256[] proportion);

    /// @notice Emitted during updateResidualRecipients().
    /// @param  recipients The new recipients to receive residual earnings.
    /// @param  proportion The proportion distributed across recipients.
    event UpdatedResidualRecipients(address[] recipients, uint256[] proportion);

    /// @notice Emitted during distributeYield().
    /// @param  protocol The amount of earnings distributed to protocol earnings recipients.
    /// @param  senior The amount of earnings distributed to the senior tranche.
    /// @param  junior The amount of earnings distributed to the junior tranche.
    /// @param  residual The amount of earnings distributed to residual earnings recipients.
    event YieldDistributed(uint256[] protocol, uint256 senior, uint256 junior, uint256[] residual);

    /// @notice Emitted during distributeYield().
    /// @param  asset The "asset" being distributed.
    /// @param  recipient The recipient of the distribution.
    /// @param  amount The amount distributed.
    event YieldDistributedSingle(address indexed asset, address indexed recipient, uint256 amount);

    /// @notice Emitted during supplementYield().
    /// @param  senior The amount of yield supplemented to the senior tranche.
    /// @param  junior The amount of yield supplemented to the junior tranche.
    event YieldSupplemented(uint256 senior, uint256 junior);



    // ---------------
    //    Functions
    // ---------------

    /// @notice Updates the state variable "targetAPYBIPS".
    /// @param  _targetAPYBIPS The new value for targetAPYBIPS.
    function setTargetAPYBIPS(uint256 _targetAPYBIPS) external {
        require(_msgSender() == YDL_IZivoeGlobals(GBL).TLC(), "ZivoeYDL::setTargetAPYBIPS() _msgSender() != TLC()");
        emit UpdatedTargetAPYBIPS(targetAPYBIPS, _targetAPYBIPS);
        targetAPYBIPS = _targetAPYBIPS;
    }

    /// @notice Updates the state variable "targetRatioBIPS".
    /// @param  _targetRatioBIPS The new value for targetRatioBIPS.
    function setTargetRatioBIPS(uint256 _targetRatioBIPS) external {
        require(_msgSender() == YDL_IZivoeGlobals(GBL).TLC(), "ZivoeYDL::setTargetRatioBIPS() _msgSender() != TLC()");
        emit UpdatedTargetRatioBIPS(targetRatioBIPS, _targetRatioBIPS);
        targetRatioBIPS = _targetRatioBIPS;
    }

    /// @notice Updates the state variable "protocolEarningsRateBIPS".
    /// @param  _protocolEarningsRateBIPS The new value for protocolEarningsRateBIPS.
    function setProtocolEarningsRateBIPS(uint256 _protocolEarningsRateBIPS) external {
        require(_msgSender() == YDL_IZivoeGlobals(GBL).TLC(), "ZivoeYDL::setProtocolEarningsRateBIPS() _msgSender() != TLC()");
        require(_protocolEarningsRateBIPS <= 3000, "ZivoeYDL::setProtocolEarningsRateBIPS() _protocolEarningsRateBIPS > 3000");
        emit UpdatedProtocolEarningsRateBIPS(protocolEarningsRateBIPS, _protocolEarningsRateBIPS);
        protocolEarningsRateBIPS = _protocolEarningsRateBIPS;
    }

    /// @notice Updates the distributed asset for this particular contract.
    /// @param  _distributedAsset The new value for distributedAsset.
    function setDistributedAsset(address _distributedAsset) external nonReentrant {
        require(_distributedAsset != distributedAsset, "ZivoeYDL::setDistributedAsset() _distributedAsset == distributedAsset");
        require(_msgSender() == YDL_IZivoeGlobals(GBL).TLC(), "ZivoeYDL::setDistributedAsset() _msgSender() != TLC()");
        require(
            YDL_IZivoeGlobals(GBL).stablecoinWhitelist(_distributedAsset),
            "ZivoeYDL::setDistributedAsset() !YDL_IZivoeGlobals(GBL).stablecoinWhitelist(_distributedAsset)"
        );
        emit UpdatedDistributedAsset(distributedAsset, _distributedAsset);
        distributedAsset = _distributedAsset;
    }

    /// @notice Recovers any extraneous ERC-20 asset held within this contract.
    /// @param  asset The ERC20 asset to recoever.
    function recoverAsset(address asset) external {
        require(unlocked, "ZivoeYDL::recoverAsset() !unlocked");
        require(asset != distributedAsset, "ZivoeYDL::recoverAsset() asset == distributedAsset");
        require(YDL_IZivoeGlobals(GBL).isKeeper(_msgSender()), "ZivoeYDL::recoverAsset() !YDL_IZivoeGlobals(GBL).isKeeper(_msgSender())");
        emit AssetRecovered(asset, IERC20(asset).balanceOf(address(this)));
        IERC20(asset).safeTransfer(YDL_IZivoeGlobals(GBL).DAO(), IERC20(asset).balanceOf(address(this)));
    }

    /// @notice Unlocks this contract for distributions, initializes values.
    function unlock() external {
        require(_msgSender() == YDL_IZivoeGlobals(GBL).ITO(), "ZivoeYDL::unlock() _msgSender() != YDL_IZivoeGlobals(GBL).ITO()");

        unlocked = true;
        lastDistribution = block.timestamp;

        emaSTT = IERC20(YDL_IZivoeGlobals(GBL).zSTT()).totalSupply();
        emaJTT = IERC20(YDL_IZivoeGlobals(GBL).zJTT()).totalSupply();

        address[] memory protocolRecipientAcc = new address[](2);
        uint256[] memory protocolRecipientAmt = new uint256[](2);

        protocolRecipientAcc[0] = address(YDL_IZivoeGlobals(GBL).stZVE());
        protocolRecipientAmt[0] = 7500;
        protocolRecipientAcc[1] = address(YDL_IZivoeGlobals(GBL).DAO());
        protocolRecipientAmt[1] = 2500;

        protocolRecipients = Recipients(protocolRecipientAcc, protocolRecipientAmt);

        address[] memory residualRecipientAcc = new address[](4);
        uint256[] memory residualRecipientAmt = new uint256[](4);

        residualRecipientAcc[0] = address(YDL_IZivoeGlobals(GBL).stJTT());
        residualRecipientAmt[0] = 2500;
        residualRecipientAcc[1] = address(YDL_IZivoeGlobals(GBL).stSTT());
        residualRecipientAmt[1] = 500;
        residualRecipientAcc[2] = address(YDL_IZivoeGlobals(GBL).stZVE());
        residualRecipientAmt[2] = 4500;
        residualRecipientAcc[3] = address(YDL_IZivoeGlobals(GBL).DAO());
        residualRecipientAmt[3] = 2500;

        residualRecipients = Recipients(residualRecipientAcc, residualRecipientAmt);
    }

    /// @notice Updates the protocolRecipients state variable which tracks the distributions for protocol earnings.
    /// @param  recipients An array of addresses to which protocol earnings will be distributed.
    /// @param  proportions An array of ratios relative to the recipients - in BIPS. Sum should equal to 10000.
    function updateProtocolRecipients(address[] memory recipients, uint256[] memory proportions) external {
        require(_msgSender() == YDL_IZivoeGlobals(GBL).TLC(), "ZivoeYDL::updateProtocolRecipients() _msgSender() != TLC()");
        require(
            recipients.length == proportions.length && recipients.length > 0, 
            "ZivoeYDL::updateProtocolRecipients() recipients.length != proportions.length || recipients.length == 0"
        );
        require(unlocked, "ZivoeYDL::updateProtocolRecipients() !unlocked");

        uint256 proportionTotal;
        for (uint256 i = 0; i < recipients.length; i++) {
            proportionTotal += proportions[i];
            require(proportions[i] > 0, "ZivoeYDL::updateProtocolRecipients() proportions[i] == 0");
        }

        require(proportionTotal == BIPS, "ZivoeYDL::updateProtocolRecipients() proportionTotal != BIPS (10,000)");

        emit UpdatedProtocolRecipients(recipients, proportions);
        protocolRecipients = Recipients(recipients, proportions);
    }

    /// @notice Updates the residualRecipients state variable which tracks the distribution for residual earnings.
    /// @param  recipients An array of addresses to which residual earnings will be distributed.
    /// @param  proportions An array of ratios relative to the recipients - in BIPS. Sum should equal to 10000.
    function updateResidualRecipients(address[] memory recipients, uint256[] memory proportions) external {
        require(_msgSender() == YDL_IZivoeGlobals(GBL).TLC(), "ZivoeYDL::updateResidualRecipients() _msgSender() != TLC()");
        require(
            recipients.length == proportions.length && recipients.length > 0, 
            "ZivoeYDL::updateResidualRecipients() recipients.length != proportions.length || recipients.length == 0"
        );
        require(unlocked, "ZivoeYDL::updateResidualRecipients() !unlocked");

        uint256 proportionTotal;
        for (uint256 i = 0; i < recipients.length; i++) {
            proportionTotal += proportions[i];
            require(proportions[i] > 0, "ZivoeYDL::updateResidualRecipients() proportions[i] == 0");
        }

        require(proportionTotal == BIPS, "ZivoeYDL::updateResidualRecipients() proportionTotal != BIPS (10,000)");

        emit UpdatedResidualRecipients(recipients, proportions);
        residualRecipients = Recipients(recipients, proportions);
    }

    /// @notice Distributes available yield within this contract to appropriate entities.
    function distributeYield() external nonReentrant {
        require(unlocked, "ZivoeYDL::distributeYield() !unlocked"); 
        require(
            block.timestamp >= lastDistribution + daysBetweenDistributions * 86400, 
            "ZivoeYDL::distributeYield() block.timestamp < lastDistribution + daysBetweenDistributions * 86400"
        );

        // Calculate protocol earnings.
        uint256 earnings = IERC20(distributedAsset).balanceOf(address(this));
        uint256 protocolEarnings = protocolEarningsRateBIPS * earnings / BIPS;
        uint256 postFeeYield = earnings.zSub(protocolEarnings);

        // Update timeline.
        numDistributions += 1;
        lastDistribution = block.timestamp;
        
        // Update emaYield.
        if (numDistributions == 1) { emaYield = postFeeYield; }
        else {
            emaYield = ema(
                emaYield, YDL_IZivoeGlobals(GBL).standardize(postFeeYield, distributedAsset),
                retrospectiveDistributions.min(numDistributions)
            );
        }

        // Calculate yield distribution (trancheuse = "slicer" in French).
        (
            uint256[] memory _protocol, uint256 _seniorTranche, uint256 _juniorTranche, uint256[] memory _residual
        ) = earningsTrancheuse(protocolEarnings, postFeeYield); 

        emit YieldDistributed(_protocol, _seniorTranche, _juniorTranche, _residual);
        
        // Update ema-based supply values.
        (uint256 asSTT, uint256 asJTT) = YDL_IZivoeGlobals(GBL).adjustedSupplies();
        emaJTT = ema(emaJTT, asSTT, retrospectiveDistributions.min(numDistributions));
        emaSTT = ema(emaSTT, asJTT, retrospectiveDistributions.min(numDistributions));

        // Distribute protocol earnings.
        for (uint256 i = 0; i < protocolRecipients.recipients.length; i++) {
            address _recipient = protocolRecipients.recipients[i];
            if (_recipient == YDL_IZivoeGlobals(GBL).stSTT() ||_recipient == YDL_IZivoeGlobals(GBL).stJTT()) {
                IERC20(distributedAsset).safeApprove(_recipient, _protocol[i]);
                YDL_IZivoeRewards(_recipient).depositReward(distributedAsset, _protocol[i]);
                emit YieldDistributedSingle(distributedAsset, _recipient, _protocol[i]);
            }
            else if (_recipient == YDL_IZivoeGlobals(GBL).stZVE()) {
                uint256 splitBIPS = (
                    IERC20(YDL_IZivoeGlobals(GBL).stZVE()).totalSupply() * BIPS
                ) / (IERC20(YDL_IZivoeGlobals(GBL).stZVE()).totalSupply() + IERC20(YDL_IZivoeGlobals(GBL).vestZVE()).totalSupply());
                IERC20(distributedAsset).safeApprove(YDL_IZivoeGlobals(GBL).stZVE(), _protocol[i] * splitBIPS / BIPS);
                IERC20(distributedAsset).safeApprove(YDL_IZivoeGlobals(GBL).vestZVE(), _protocol[i] * (BIPS - splitBIPS) / BIPS);
                YDL_IZivoeRewards(YDL_IZivoeGlobals(GBL).stZVE()).depositReward(distributedAsset, _protocol[i] * splitBIPS / BIPS);
                YDL_IZivoeRewards(YDL_IZivoeGlobals(GBL).vestZVE()).depositReward(distributedAsset, _protocol[i] * (BIPS - splitBIPS) / BIPS);
                emit YieldDistributedSingle(distributedAsset, YDL_IZivoeGlobals(GBL).stZVE(), _protocol[i] * splitBIPS / BIPS);
                emit YieldDistributedSingle(distributedAsset, YDL_IZivoeGlobals(GBL).vestZVE(), _protocol[i] * (BIPS - splitBIPS) / BIPS);
            }
            else {
                IERC20(distributedAsset).safeTransfer(_recipient, _protocol[i]);
                emit YieldDistributedSingle(distributedAsset, _recipient, _protocol[i]);
            }
        }

        // Distribute senior and junior tranche earnings.
        IERC20(distributedAsset).safeApprove(YDL_IZivoeGlobals(GBL).stSTT(), _seniorTranche);
        IERC20(distributedAsset).safeApprove(YDL_IZivoeGlobals(GBL).stJTT(), _juniorTranche);
        YDL_IZivoeRewards(YDL_IZivoeGlobals(GBL).stSTT()).depositReward(distributedAsset, _seniorTranche);
        YDL_IZivoeRewards(YDL_IZivoeGlobals(GBL).stJTT()).depositReward(distributedAsset, _juniorTranche);
        emit YieldDistributedSingle(distributedAsset, YDL_IZivoeGlobals(GBL).stSTT(), _seniorTranche);
        emit YieldDistributedSingle(distributedAsset, YDL_IZivoeGlobals(GBL).stJTT(), _juniorTranche);

        // Distribute residual earnings.
        for (uint256 i = 0; i < residualRecipients.recipients.length; i++) {
            if (_residual[i] > 0) {
                address _recipient = residualRecipients.recipients[i];
                if (_recipient == YDL_IZivoeGlobals(GBL).stSTT() ||_recipient == YDL_IZivoeGlobals(GBL).stJTT()) {
                    IERC20(distributedAsset).safeApprove(_recipient, _residual[i]);
                    YDL_IZivoeRewards(_recipient).depositReward(distributedAsset, _residual[i]);
                    emit YieldDistributedSingle(distributedAsset, _recipient, _protocol[i]);
                }
                else if (_recipient == YDL_IZivoeGlobals(GBL).stZVE()) {
                    uint256 splitBIPS = (
                        IERC20(YDL_IZivoeGlobals(GBL).stZVE()).totalSupply() * BIPS
                    ) / (IERC20(YDL_IZivoeGlobals(GBL).stZVE()).totalSupply() + IERC20(YDL_IZivoeGlobals(GBL).vestZVE()).totalSupply());
                    IERC20(distributedAsset).safeApprove(YDL_IZivoeGlobals(GBL).stZVE(), _residual[i] * splitBIPS / BIPS);
                    IERC20(distributedAsset).safeApprove(YDL_IZivoeGlobals(GBL).vestZVE(), _residual[i] * (BIPS - splitBIPS) / BIPS);
                    YDL_IZivoeRewards(YDL_IZivoeGlobals(GBL).stZVE()).depositReward(distributedAsset, _residual[i] * splitBIPS / BIPS);
                    YDL_IZivoeRewards(YDL_IZivoeGlobals(GBL).vestZVE()).depositReward(distributedAsset, _residual[i] * (BIPS - splitBIPS) / BIPS);
                    emit YieldDistributedSingle(distributedAsset, YDL_IZivoeGlobals(GBL).stZVE(), _residual[i] * splitBIPS / BIPS);
                    emit YieldDistributedSingle(distributedAsset, YDL_IZivoeGlobals(GBL).vestZVE(), _residual[i] * (BIPS - splitBIPS) / BIPS);
                }
                else {
                    IERC20(distributedAsset).safeTransfer(_recipient, _residual[i]);
                    emit YieldDistributedSingle(distributedAsset, _recipient, _residual[i]);
                }
            }
        }

    }

    /// @notice Supplies yield directly to each tranche, distributed based on seniorProportionBase().
    /// @param  amount Amount of distributedAsset() to supply.
    function supplementYield(uint256 amount) external {
        require(unlocked, "ZivoeYDL::supplementYield() !unlocked");

        uint256 seniorRate = seniorProportionBase(amount, emaSTT, targetAPYBIPS, daysBetweenDistributions);
        uint256 toSenior = (amount * seniorRate) / RAY;
        uint256 toJunior = amount.zSub(toSenior);

        emit YieldSupplemented(toSenior, toJunior);

        IERC20(distributedAsset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(distributedAsset).safeApprove(YDL_IZivoeGlobals(GBL).stSTT(), toSenior);
        IERC20(distributedAsset).safeApprove(YDL_IZivoeGlobals(GBL).stJTT(), toJunior);
        YDL_IZivoeRewards(YDL_IZivoeGlobals(GBL).stSTT()).depositReward(distributedAsset, toSenior);
        YDL_IZivoeRewards(YDL_IZivoeGlobals(GBL).stJTT()).depositReward(distributedAsset, toJunior);
    }

    /// @notice View distribution information for protocol and residual earnings recipients.
    /// @return protocolEarningsRecipients The destinations for protocol earnings distributions.
    /// @return protocolEarningsProportion The proportions for protocol earnings distributions.
    /// @return residualEarningsRecipients The destinations for residual earnings distributions.
    /// @return residualEarningsProportion The proportions for residual earnings distributions.
    function viewDistributions() external view returns (
        address[] memory protocolEarningsRecipients, uint256[] memory protocolEarningsProportion, 
        address[] memory residualEarningsRecipients, uint256[] memory residualEarningsProportion
    ) {
        return (protocolRecipients.recipients, protocolRecipients.proportion, residualRecipients.recipients, residualRecipients.proportion);
    }


    /// @notice This function converts any arbitrary asset to YDL.distributeAsset().
    /// @param  assetToConvert The asset to convert to distributedAsset.
    /// @param  amount The data retrieved from 1inch API in order to execute the swap.
    /// @param  data The data retrieved from 1inch API in order to execute the swap.
    function convert(address assetToConvert, uint256 amount, bytes calldata data) external nonReentrant {
        require(YDL_IZivoeGlobals(GBL).isKeeper(_msgSender()), "ZivoeYDL::convert() !YDL_IZivoeGlobals(GBL).isKeeper(_msgSender())");
        require(assetToConvert != distributedAsset, "ZivoeYDL::convert() assetToConvert == distributedAsset");
        uint256 preBalance = IERC20(distributedAsset).balanceOf(address(this));

        // Swap specified amount of "convert" to YDL.distributedAsset().
        convertAsset(assetToConvert, distributedAsset, amount, data);

        emit AssetConverted(assetToConvert, amount, IERC20(distributedAsset).balanceOf(address(this)) - preBalance);
    }



    // ----------
    //    Math
    // ----------

    /// @notice Will return the split of ongoing protocol earnings for a given senior and junior tranche size.
    /// @return protocol Protocol earnings.
    /// @return senior Senior tranche earnings.
    /// @return junior Junior tranche earnings.
    /// @return residual Residual earnings.
    function earningsTrancheuse(uint256 protocolEarnings, uint256 postFeeYield) public view returns (
        uint256[] memory protocol, uint256 senior, uint256 junior, uint256[] memory residual
    ) {
        // Handle accounting for protocol earnings.
        protocol = new uint256[](protocolRecipients.recipients.length);
        for (uint256 i = 0; i < protocolRecipients.recipients.length; i++) {
            protocol[i] = protocolRecipients.proportion[i] * protocolEarnings / BIPS;
        }

        // Handle accounting for senior and junior earnings.
        uint256 _seniorProportion = seniorProportion(
            YDL_IZivoeGlobals(GBL).standardize(postFeeYield, distributedAsset),
            yieldTarget(emaSTT, emaJTT, targetAPYBIPS, targetRatioBIPS, daysBetweenDistributions), emaYield,
            emaSTT, emaJTT, targetAPYBIPS, targetRatioBIPS, daysBetweenDistributions, retrospectiveDistributions
        );
        uint256 _juniorProportion = juniorProportion(emaSTT, emaJTT, _seniorProportion, targetRatioBIPS);

        senior = (postFeeYield * _seniorProportion) / RAY;
        junior = (postFeeYield * _juniorProportion) / RAY;
        
        // Handle accounting for residual earnings.
        residual = new uint256[](residualRecipients.recipients.length);
        uint256 residualEarnings = postFeeYield.zSub(senior + junior);
        for (uint256 i = 0; i < residualRecipients.recipients.length; i++) {
            residual[i] = residualRecipients.proportion[i] * residualEarnings / BIPS;
        }
    }

    /**
        @notice     Calculates the current EMA (exponential moving average).
        @dev        M * cV + (1 - M) * bV, where our smoothing factor M = 2 / (N + 1)
        @param      bV  = The base value (typically an EMA from prior calculations).
        @param      cV  = The current value, which is factored into bV.
        @param      N   = Number of steps to average over.
        @return     eV  = EMA-based value given prior and current conditions.
    */
    function ema(uint256 bV, uint256 cV, uint256 N) public pure returns (uint256 eV) {
        uint256 M = (WAD * 2).zDiv(N + 1);
        eV = ((M * cV) + (WAD - M) * bV).zDiv(WAD);
    }

    /**
        @notice     Calculates proportion of yield attributable to junior tranche.
        @dev        (Q * eJTT * sP / BIPS).zDiv(eSTT).min(RAY - sP)
        @param      eSTT = ema-based supply of zSTT                     (units = WEI)
        @param      eJTT = ema-based supply of zJTT                     (units = WEI)
        @param      sP   = Proportion of yield attributable to seniors  (units = RAY)
        @param      Q    = senior to junior tranche target ratio        (units = BIPS)
        @return     jP   = Yield attributable to junior tranche in RAY.
        @dev        Precision of return value, jP, is in RAY (10**27).
        @dev        The return value for this equation MUST never exceed RAY (10**27).
    */
    function juniorProportion(uint256 eSTT, uint256 eJTT, uint256 sP, uint256 Q) public pure returns (uint256 jP) {
        if (sP <= RAY) { jP = (Q * eJTT * sP / BIPS).zDiv(eSTT).min(RAY - sP); }
    }

    /**
        @notice     Calculates proportion of yield distributble which is attributable to the senior tranche.
        @param      yD   = yield distributable                      (units = WEI)
        @param      yT   = ema-based yield target                   (units = WEI)
        @param      yA   = ema-based average yield distribution     (units = WEI)
        @param      eSTT = ema-based supply of zSTT                 (units = WEI)
        @param      eJTT = ema-based supply of zJTT                 (units = WEI)
        @param      Y    = target annual yield for senior tranche   (units = BIPS)
        @param      Q    = multiple of Y                            (units = BIPS)
        @param      T    = # of days between distributions          (units = integer)
        @param      R    = # of distributions for retrospection     (units = integer)
        @return     sP   = Proportion of yD attributable to senior tranche.
        @dev        Precision of return value, sP, is in RAY (10**27).
    */
    function seniorProportion(
        uint256 yD, uint256 yT, uint256 yA, uint256 eSTT, uint256 eJTT, uint256 Y, uint256 Q, uint256 T, uint256 R
    ) public pure returns (uint256 sP) {
        // Shortfall of yield.
        if (yD < yT) { sP = seniorProportionShortfall(eSTT, eJTT, Q); }
        // Excess yield and historical under-performance.
        else if (yT >= yA && yA != 0) { sP = seniorProportionCatchup(yD, yT, yA, eSTT, eJTT, R, Q); }
        // Excess yield and historical out-performance.
        else { sP = seniorProportionBase(yD, eSTT, Y, T); }
    }

    /**
        @notice     Calculates proportion of yield attributed to senior tranche (no extenuating circumstances).
        @dev          Y  * eSTT * T
                    ----------------- *  RAY
                        (365) * yD
        @param      yD   = yield distributable                      (units = WEI)
        @param      eSTT = ema-based supply of zSTT                 (units = WEI)
        @param      Y    = target annual yield for senior tranche   (units = BIPS)
        @param      T    = # of days between distributions          (units = integer)
        @return     sPB  = Proportion of yield attributed to senior tranche in RAY.
        @dev        Precision of return value, sRB, is in RAY (10**27).
    */
    function seniorProportionBase(uint256 yD, uint256 eSTT, uint256 Y, uint256 T) public pure returns (uint256 sPB) {
        // TODO: Investigate consequences of yD == 0 in this context.
        sPB = ((RAY * Y * (eSTT) * T / BIPS) / 365).zDiv(yD).min(RAY);
    }

    /**
        @notice     Calculates proportion of yield attributable to senior tranche during historical under-performance.
        TODO        @dev EQUATION HERE
        @param      yD   = yield distributable                      (units = WEI)
        @param      yT   = yieldTarget() return parameter           (units = WEI)
        @param      yA   = emaYield                                 (units = WEI)
        @param      eSTT = ema-based supply of zSTT                 (units = WEI)
        @param      eJTT = ema-based supply of zJTT                 (units = WEI)
        @param      R    = # of distributions for retrospection     (units = integer)
        @param      Q    = multiple of Y                            (units = BIPS)
        @return     sPC  = Proportion of yD attributable to senior tranche in RAY.
        @dev        Precision of return value, sPC, is in RAY (10**27).
    */
    function seniorProportionCatchup(
        uint256 yD, uint256 yT, uint256 yA, uint256 eSTT, uint256 eJTT, uint256 R, uint256 Q
    ) public pure returns (uint256 sPC) {
        sPC = ((R + 1) * yT * RAY * WAD).zSub(R * yA * RAY * WAD).zDiv(yD * (WAD + (Q * eJTT * WAD / BIPS).zDiv(eSTT))).min(RAY);
    }

    /**
        @notice     Calculates proportion of yield attributed to senior tranche (shortfall occurence).
        @dev                     WAD
                   --------------------------------  *  RAY
                             Q * eJTT * WAD / BIPS      
                    WAD  +   ---------------------
                                     eSTT
        @param      eSTT = ema-based supply of zSTT                 (units = WEI)
        @param      eJTT = ema-based supply of zJTT                 (units = WEI)
        @param      Q    = senior to junior tranche target ratio    (units = integer)
        @return     sPS  = Proportion of yield attributed to senior tranche in RAY.
        @dev        Precision of return value, sPS, is in RAY (10**27).
    */
    function seniorProportionShortfall(uint256 eSTT, uint256 eJTT, uint256 Q) public pure returns (uint256 sPS) {
        sPS = (WAD * RAY).zDiv(WAD + (Q * eJTT * WAD / BIPS).zDiv(eSTT)).min(RAY);
    }

    /**
        @notice     Calculates amount of annual yield required to meet target rate for both tranches.
        @dev        (Y * T * (eSTT + eJTT * Q / BIPS) / BIPS) / 365
        @param      eSTT = ema-based supply of zSTT                  (units = WEI)
        @param      eJTT = ema-based supply of zJTT                  (units = WEI)
        @param      Y    = target annual yield for senior tranche   (units = BIPS)
        @param      Q    = multiple of Y                            (units = BIPS)
        @param      T    = # of days between distributions          (units = integer)
        @return     yT   = yield target for the senior and junior tranche combined.
        @dev        Precision of the return value, yT, is in WEI (10**18).
    */
    function yieldTarget(uint256 eSTT, uint256 eJTT, uint256 Y, uint256 Q, uint256 T) public pure returns (uint256 yT) {
        yT = (Y * T * (eSTT + eJTT * Q / BIPS) / BIPS) / 365;
    }

}
