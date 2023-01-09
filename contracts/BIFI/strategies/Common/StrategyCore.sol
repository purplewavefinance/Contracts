// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";

import "../Common/StratFeeManager.sol";
import "../../utils/GasFeeThrottler.sol";
import "../../interfaces/beefy/IBeefyVaultV7Multi.sol";

abstract contract StrategyCore is StratFeeManager, GasFeeThrottler {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct Reward {
        address reward;
        address unirouter;
        address[] route;
    }

    // Tokens used
    address public native;
    address public output;
    address public want;

    uint256 public lastHarvest;

    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    event Withdraw(uint256 tvl);
    event ChargedFees(uint256 callFees, uint256 beefyFees, uint256 strategistFees);

    /**
     * @dev Only called by the vault to withdraw a requested amount. Losses from liquidating the
     * requested funds are recorded and reported to the vault.
     * @param amount The amount of assets to withdraw.
     * @param loss The loss that occured when liquidating the assets.
     */
    function withdraw(uint256 amount) external virtual returns (uint256 loss) {
        require(msg.sender == vault);

        uint256 amountFreed;
        (amountFreed, loss) = _liquidatePosition(amount);
        IERC20Upgradeable(want).safeTransfer(vault, amountFreed);

        emit Withdraw(balanceOf());
    }

    /**
     * @dev External function for anyone to harvest this strategy, protected by a gas throttle to
     * prevent front-running. Call fee goes to the caller of this function.
     */
    function harvest() external gasThrottle virtual {
        _harvest(tx.origin);
    }

    /**
     * @dev External function for anyone to harvest this strategy, protected by a gas throttle to
     * prevent front-running. Call fee goes to the specified recipient.
     */
    function harvest(address callFeeRecipient) external gasThrottle virtual {
        _harvest(callFeeRecipient);
    }

    /**
     * @dev External function for the manager to harvest this strategy to be used in times of high gas
     * prices. Call fee goes to the caller of this function.
     */
    function managerHarvest() external onlyManager virtual {
        _harvest(tx.origin);
    }

    /**
     * @dev Internal function to harvest the strategy. If not paused then collect rewards, charge
     * fees and convert output to the want token. Exchange funds with the vault if the strategy is
     * owed more vault allocation or if the strategy has a debt to pay back to the vault.
     * @param callFeeRecipient The address to send the call fee to.
     */
    function _harvest(address callFeeRecipient) internal virtual {
        if (!paused()) {
            _getRewards();
            if (IERC20Upgradeable(output).balanceOf(address(this)) > 0) {
                _chargeFees(callFeeRecipient);
                _convertToWant();
            }
        }

        uint256 gain = _balanceVaultFunds();
        lastHarvest = block.timestamp;
        emit StratHarvest(msg.sender, gain, balanceOf());
    }

    /**
     * @dev It fetches fees and charges the appropriate amount on the output token. Fees are sent
     * to the various stored addresses and to the specified call fee recipient.
     * @param callFeeRecipient The address to send the call fee to.
     */
    function _chargeFees(address callFeeRecipient) internal virtual {
        IFeeConfig.FeeCategory memory fees = getFees();

        _swap(unirouter, output, native, fees.total);

        uint256 nativeBal = IERC20Upgradeable(native).balanceOf(address(this));

        uint256 callFeeAmount = nativeBal * fees.call / DIVISOR;
        IERC20Upgradeable(native).safeTransfer(callFeeRecipient, callFeeAmount);

        uint256 beefyFeeAmount = nativeBal * fees.beefy / DIVISOR;
        IERC20Upgradeable(native).safeTransfer(beefyFeeRecipient, beefyFeeAmount);

        uint256 strategistFeeAmount = nativeBal * fees.strategist / DIVISOR;
        IERC20Upgradeable(native).safeTransfer(strategist, strategistFeeAmount);

        emit ChargedFees(callFeeAmount, beefyFeeAmount, strategistFeeAmount);
    }

    /**
     * @dev Internal function to exchange funds with the vault.
     * Any debt to pay to the vault is liquidated from the underlying platform and sent to the
     * vault when reporting. The strategy also can collect more funds when reporting if it is in
     * credit. Funds left on this contract are reinvested when not paused, minus the outstanding
     * debt to the vault.
     * @return gain The increase in assets from this harvest.
     */
    function _balanceVaultFunds() internal virtual returns (uint256 gain) {
        (int256 roi, uint256 repayment) = _liquidateRepayment(_getDebt());
        gain = roi > 0 ? uint256(roi) : 0;

        uint256 outstandingDebt = IBeefyVaultV7Multi(vault).report(roi, repayment);
        _adjustPosition(outstandingDebt);
    }

    /**
     * @dev It fetches the debt owed to the vault from this strategy.
     * @return debt The amount owed to the vault.
     */
    function _getDebt() internal virtual returns (uint256 debt) {
        int256 availableCapital = IBeefyVaultV7Multi(vault).availableCapital(address(this));
        if (availableCapital < 0) {
            debt = uint256(-availableCapital);
        }
    }

    /**
     * @dev It calculates the return on investment and liquidates an amount to claimed by the vault.
     * @param debt The amount owed to the vault.
     * @return roi The return on investment from last harvest report.
     * @return repayment The amount liquidated to repay the debt to the vault.
     */
    function _liquidateRepayment(uint256 debt) internal virtual returns (
        int256 roi, 
        uint256 repayment
    ) {
        uint256 allocated = IBeefyVaultV7Multi(vault).strategies(address(this)).allocated;
        uint256 totalAssets = balanceOf();
        uint256 toFree = debt;

        if (totalAssets > allocated) {
            uint256 profit = totalAssets - allocated;
            toFree += profit;
            roi = int256(profit);
        } else if (totalAssets < allocated) {
            roi = -int256(allocated - totalAssets);
        }

        (uint256 amountFreed, uint256 loss) = _liquidatePosition(toFree);
        repayment = MathUpgradeable.min(debt, amountFreed);
        roi -= int256(loss);
    }

    /**
     * @dev It liquidates the amount owed to the vault from the underlying platform to allow the
     * vault to claim the repayment amount when reporting.
     * @param amountNeeded The amount owed to the vault.
     * @return liquidatedAmount The return on investment from last harvest report.
     * @return loss The amount freed to repay the debt to the vault.
     */
    function _liquidatePosition(uint256 amountNeeded)
        internal
        virtual
        returns (uint256 liquidatedAmount, uint256 loss)
    {
        uint256 wantBal = IERC20Upgradeable(want).balanceOf(address(this));
        if (wantBal < amountNeeded) {
            if (paused()) {
                _emergencyWithdraw();
            } else {
                _withdrawUnderlying(amountNeeded - wantBal);
            }
            liquidatedAmount = IERC20Upgradeable(want).balanceOf(address(this));
        } else {
            liquidatedAmount = amountNeeded;
        }
        
        if (amountNeeded > liquidatedAmount) {
            loss = amountNeeded - liquidatedAmount;
        }
    }

    /**
     * @dev It reinvests the amount of assets on this address minus the outstanding debt so debt
     * can be claimed easily on next harvest.
     * @param debt The outstanding amount owed to the vault.
     */
    function _adjustPosition(uint256 debt) internal virtual {
        if (paused()) {
            return;
        }

        uint256 wantBalance = balanceOfWant();
        if (wantBalance > debt) {
            uint256 toReinvest = wantBalance - debt;
            _depositUnderlying(toReinvest);
        }
    }

    /**
     * @dev It calculates the total underlying balance of 'want' held by this strategy including
     * the invested amount.
     * @return totalBalance The total balance of the wanted asset.
     */
    function balanceOf() public virtual view returns (uint256) {
        return balanceOfWant() + balanceOfPool();
    }

    /**
     * @dev It calculates the balance of 'want' held directly on this address.
     * @return balanceOfWant The balance of the wanted asset on this address.
     */
    function balanceOfWant() public virtual view returns (uint256) {
        return IERC20Upgradeable(want).balanceOf(address(this));
    }

    /**
     * @dev It calculates the native reward for a caller to harvest the strategy. Fees are fetched
     * from the Beefy Fee Configurator and applied.
     * @return nativeOut The native reward amount for a harvest caller.
     */
    function callReward() public virtual view returns (uint256 nativeOut) {
        IFeeConfig.FeeCategory memory fees = getFees();
        uint256 outputBal = rewardsAvailable();
        if (outputBal > 0) {
            nativeOut = _getAmountOut(unirouter, outputBal, output, native);
        }

        return nativeOut * fees.total / DIVISOR * fees.call / DIVISOR;
    }

    /**
     * @dev It turns on or off the gas throttle to limit the gas price on harvests.
     * @param _shouldGasThrottle Change the activation of the gas throttle.
     */
    function setShouldGasThrottle(bool _shouldGasThrottle) external onlyManager virtual {
        shouldGasThrottle = _shouldGasThrottle;
    }

    /**
     * @dev It shuts down deposits, removes allowances and prepares the full withdrawal of funds
     * back to the vault on next harvest.
     */
    function pause() public onlyManager virtual {
        _pause();
        _removeAllowances();
        _revokeStrategy();
    }

    /**
     * @dev It reopens possible deposits and reinstates allowances. The debt ratio needs to be
     * updated on the vault and the next harvest will bring in funds from the vault.
     */
    function unpause() external onlyManager virtual {
        _unpause();
        _giveAllowances();
    }

    /**
     * @dev It revokes the strategy's debt ratio allocation on the vault, so that all of the funds
     * in this strategy will be sent to the vault on the next harvest.
     */
    function _revokeStrategy() internal virtual {
        IBeefyVaultV7Multi(vault).revokeStrategy();
    }

    /* ----------- INTERNAL VIRTUAL ----------- */
    // To be overridden by child contracts

    /**
     * @dev Helper function to deposit to the underlying platform.
     * @param amount The amount to deposit.
     */
    function _depositUnderlying(uint256 amount) internal virtual;

    /**
     * @dev Helper function to withdraw from the underlying platform.
     * @param amount The amount to withdraw.
     */
    function _withdrawUnderlying(uint256 amount) internal virtual;

    /**
     * @dev It calculates the invested balance of 'want' in the underlying platform.
     * @return balanceOfPool The invested balance of the wanted asset.
     */
    function balanceOfPool() public virtual view returns (uint256);

    /**
     * @dev It claims rewards from the underlying platform and converts any extra rewards back into
     * the output token.
     */
    function _getRewards() internal virtual;

    /**
     * @dev It converts the output to the want asset, in this case it swaps half for each LP token
     * and adds liquidity.
     */
    function _convertToWant() internal virtual;

    /**
     * @dev It swaps from one token to another, taking into account the route and slippage.
     * @param _unirouter The router used to make the swap.
     * @param _fromToken The token to swap from.
     * @param _toToken The token to swap to.
     * @param _percentageSwap The percentage of the fromToken to use in the swap, scaled to 1e18.
     */
    function _swap(
        address _unirouter,
        address _fromToken,
        address _toToken,
        uint256 _percentageSwap
    ) internal virtual;

    /**
     * @dev It estimated the amount received from making a swap.
     * @param _unirouter The router used to make the swap.
     * @param _amountIn The amount of fromToken to be used in the swap.
     * @param _fromToken The token to swap from.
     * @param _toToken The token to swap to.
     */
    function _getAmountOut(
        address _unirouter,
        uint256 _amountIn,
        address _fromToken,
        address _toToken
    ) internal virtual view returns (uint256 amount);

    /**
     * @dev It calculates the output reward available to the strategy by calling the pending
     * rewards function on the underlying platform.
     * @return rewardsAvailable The amount of output rewards not yet harvested.
     */
    function rewardsAvailable() public virtual view returns (uint256);

    /**
     * @dev It notifies the strategy that there is an extra token to compound back into the output.
     * The router can be different to the strategy unirouter.
     * @param rewardData The swap data for the extra reward token.
     */
    function addReward(Reward calldata rewardData) external virtual;

    /**
     * @dev It withdraws from the underlying platform without caring about rewards.
     */
    function _emergencyWithdraw() internal virtual;

    /**
     * @dev It gives allowances to the required addresses.
     */
    function _giveAllowances() internal virtual;

    /**
     * @dev It revokes allowances from the previously approved addresses.
     */
    function _removeAllowances() internal virtual;

    /**
     * @dev Helper function to view the token route for swapping between output and native.
     * @return outputToNativeRoute The token route between output to native.
     */
    function outputToNative() external virtual view returns (address[] memory);
}