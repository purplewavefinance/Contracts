// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import "../interfaces/beefy/IMultiStrategy.sol";

/**
 * @dev Implementation of a vault to deposit funds for yield optimizing.
 * This is the contract that receives funds and that users interface with.
 * The yield optimizing strategy itself is implemented in a separate 'Strategy.sol' contract.
 */
contract VaultManager is Initializable, ERC4626Upgradeable, OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct StrategyParams {
        uint256 activation; // Timestamp of strategy activation.
        uint256 debtRatio; // Allocation in BPS of vault's total assets.
        uint256 allocated; // Amount of capital allocated to this strategy.
        uint256 gains; // Total returns that strategy has realized.
        uint256 losses; // Total losses that strategy has realized.
        uint256 lastReport; // Timestamp of the last time the strategy reported in.
    }

    // Mapping strategies to their strategy parameters.
    mapping(address => StrategyParams) public strategies;
    // Ordering that `withdraw` uses to determine which strategies to pull funds from.
    address[] public withdrawalQueue;
    // The unit for calculating profit degradation.
    uint256 public constant DEGRADATION_COEFFICIENT = 1e18;
    // Basis point unit, for calculating slippage and strategy allocations.
    uint256 public constant PERCENT_DIVISOR = 10_000;
    // The maximum amount of assets the vault can hold while still allowing deposits.
    uint256 public tvlCap;
    // Sum of debtRatio across all strategies (in BPS, <= 10k).
    uint256 public totalDebtRatio;
    // Amount of tokens that have been allocated to all strategies.
    uint256 public totalAllocated;
    // Timestamp of last report from any strategy.
    uint256 public lastReport;
    // Emergency shutdown - when true funds are pulled out of strategies to the vault.
    bool public emergencyShutdown;
    // Max slippage(loss) allowed when withdrawing, in BPS (0.01%).
    uint256 public withdrawMaxLoss = 1;
    // Rate per second of degradation. DEGRADATION_COEFFICIENT is 100% per second.
    uint256 public lockedProfitDegradation = DEGRADATION_COEFFICIENT / 6 hours;
    // How much profit is locked and cant be withdrawn.
    uint256 public lockedProfit;
    // Admin controller for less critical functions.
    address public keeper;

    event AddStrategy(address indexed strategy, uint256 debtRatio);
    event SetStrategyDebtRatio(address indexed strategy, uint256 debtRatio);
    event SetWithdrawalQueue(address[] withdrawalQueue);
    event SetWithdrawMaxLoss(uint256 withdrawMaxLoss);
    event SetLockedProfitDegradation(uint256 degradation);
    event SetTvlCap(uint256 newTvlCap);
    event SetKeeper(address keeper);
    event EmergencyShutdown(bool active);
    event InCaseTokensGetStuck(address token, uint256 amount);

    /**
     * @dev Sets the value of {token} to the token that the vault will
     * hold as underlying value. It initializes the vault's own 'moo' token.
     * This token is minted when someone does a deposit. It is burned in order
     * to withdraw the corresponding portion of the underlying assets.
     * @param _tvlCap Initial deposit cap for scaling TVL safely.
     */
    function __Manager_init_(
        uint256 _tvlCap,
        address _keeper
    ) public onlyInitializing {
        tvlCap = _tvlCap;
        keeper = _keeper;
        lastReport = block.timestamp;
    }

    /**
     * @dev It checks that the caller is either the owner or keeper.
     */
    modifier onlyManager() {
        require(msg.sender == owner() || msg.sender == keeper, "!manager");
        _;
    }

    /**
     * @dev It checks that the caller is an active strategy.
     */
    modifier onlyStrategy() {
        require(strategies[msg.sender].activation != 0, "!activeStrategy");
        _;
    }

    /**
     * @dev Adds a new strategy to the vault with a given allocation amount in basis points.
     * @param strategy The strategy to add.
     * @param debtRatio The strategy allocation in basis points.
     */
    function addStrategy(address strategy, uint256 debtRatio) external onlyOwner {
        require(!emergencyShutdown, "emergencyShutdown");
        require(strategy != address(0), "zeroAddress");
        require(strategies[strategy].activation == 0, "activeStrategy");
        require(address(this) == IMultiStrategy(strategy).vault(), "!vault");
        require(asset() == address(IMultiStrategy(strategy).want()), "!want");
        require(debtRatio + totalDebtRatio <= PERCENT_DIVISOR, ">maxAlloc");

        strategies[strategy] = StrategyParams({
            activation: block.timestamp,
            debtRatio: debtRatio,
            allocated: 0,
            gains: 0,
            losses: 0,
            lastReport: block.timestamp
        });

        totalDebtRatio += debtRatio;
        withdrawalQueue.push(strategy);
        emit AddStrategy(strategy, debtRatio);
    }

    /**
     * @dev Sets the allocation points for a given strategy.
     * @param strategy The strategy to set.
     * @param debtRatio The strategy allocation in basis points.
     */
    function setStrategyDebtRatio(address strategy, uint256 debtRatio) external onlyManager {
        require(strategies[strategy].activation != 0, "!activeStrategy");
        totalDebtRatio -= strategies[strategy].debtRatio;
        strategies[strategy].debtRatio = debtRatio;
        totalDebtRatio += debtRatio;
        require(totalDebtRatio <= PERCENT_DIVISOR, ">maxAlloc");
        emit SetStrategyDebtRatio(strategy, debtRatio);
    }

    /**
     * @dev Sets the withdrawalQueue to match the addresses and order specified.
     * @param _withdrawalQueue The new withdrawalQueue to set to.
     */
    function setWithdrawalQueue(address[] calldata _withdrawalQueue) external onlyManager {
        uint256 queueLength = _withdrawalQueue.length;
        require(queueLength != 0, "emptyQueue");

        delete withdrawalQueue;
        for (uint256 i; i < queueLength;) {
            address strategy = _withdrawalQueue[i];
            StrategyParams storage params = strategies[strategy];
            require(params.activation != 0, "!activeStrategy");
            withdrawalQueue.push(strategy);
            unchecked { ++i; }
        }
        emit SetWithdrawalQueue(withdrawalQueue);
    }

    /**
     * @dev Sets the withdrawMaxLoss which is the maximum allowed slippage.
     * @param newWithdrawMaxLoss The new loss maximum, in basis points, when withdrawing.
     */
    function setWithdrawMaxLoss(uint256 newWithdrawMaxLoss) external onlyManager {
        require(newWithdrawMaxLoss <= PERCENT_DIVISOR, ">maxLoss");
        withdrawMaxLoss = newWithdrawMaxLoss;
        emit SetWithdrawMaxLoss(withdrawMaxLoss);
    }

    /**
     * @dev Changes the locked profit degradation.
     * @param degradation The rate of degradation in percent per second scaled to 1e18.
     */
    function setLockedProfitDegradation(uint256 degradation) external onlyManager {
        require(degradation <= DEGRADATION_COEFFICIENT, ">maxDegradation");
        lockedProfitDegradation = degradation;
        emit SetLockedProfitDegradation(degradation);
    }

    /**
     * @dev Sets the vault tvl cap (the max amount of assets held by the vault).
     * @param newTvlCap The new tvl cap.
     */
    function setTvlCap(uint256 newTvlCap) public onlyManager {
        tvlCap = newTvlCap;
        emit SetTvlCap(tvlCap);
    }

     /**
     * @dev Helper function to remove TVL cap.
     */
    function removeTvlCap() external onlyManager {
        setTvlCap(type(uint256).max);
    }

    /**
     * @dev Sets the keeper address to perform admin tasks.
     * @param newKeeper The new keeper address.
     */
    function setKeeper(address newKeeper) external onlyManager {
        keeper = newKeeper;
        emit SetKeeper(keeper);
    }

    /**
     * @dev Activates or deactivates Vault mode where all Strategies go into full
     * withdrawal.
     * During Emergency Shutdown:
     * 1. No Users may deposit into the Vault (but may withdraw as usual).
     * 2. New Strategies may not be added.
     * 3. Each Strategy must pay back their debt as quickly as reasonable to
     * minimally affect their position.
     *
     * If true, the Vault goes into Emergency Shutdown. If false, the Vault
     * goes back into Normal Operation.
     * @param active If emergencyShutdown is active or not.
     */
    function setEmergencyShutdown(bool active) external onlyManager {
        emergencyShutdown = active;
        emit EmergencyShutdown(emergencyShutdown);
    }

    function revokeStrategy() external onlyStrategy {
        address stratAddr = msg.sender;
        totalDebtRatio -= strategies[stratAddr].debtRatio;
        strategies[stratAddr].debtRatio = 0;
        emit SetStrategyDebtRatio(stratAddr, 0);
    }

    /**
     * @dev Rescues random funds stuck that the strat can't handle.
     * @param token Address of the asset to rescue.
     */
    function inCaseTokensGetStuck(address token) external onlyManager {
        require(token != asset(), "!asset");

        uint256 amount = IERC20Upgradeable(token).balanceOf(address(this));
        IERC20Upgradeable(token).safeTransfer(msg.sender, amount);
        emit InCaseTokensGetStuck(token, amount);
    }
}