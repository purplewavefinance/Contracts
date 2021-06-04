import "hardhat";
import "hardhat-deploy";
import "@nomiclabs/hardhat-ethers";

import {HardhatRuntimeEnvironment} from 'hardhat/types';
import {DeployFunction} from 'hardhat-deploy/types';

import "../utils/registerSubsidy";
import { contractAddressGenerator } from "../utils/predictAddresses";

import { addressBook } from "blockchain-addressbook";
const { USDC: {address: USDC}, QUICK: { address: QUICK }, WMATIC: { address: WMATIC }, ETH: { address: ETH } } = addressBook.polygon.tokens;
const { quickswap, beefyfinance } = addressBook.polygon.platforms;

let vaultParams = {
    strategy: null as string | null,
    mooName: "Moo Quick USDC-ETH",
    mooSymbol: "mooQuickUSDC-ETH",
    delay: 21600,
}

let strategyParams = {
    want: "0x853Ee4b2A13f8a742d64C8F088bE7bA2131f670d",
    rewardPool: "0x4A73218eF2e820987c59F838906A82455F42D98b",
    vault: null as string | null,
    unirouter: quickswap.router,
    strategist: "0x530115e78F7BC2fE235666651f9113DB9cecE5A2", // some address
    keeper: beefyfinance.keeper,
    beefyFeeRecipient: beefyfinance.beefyFeeRecipient,
    outputToNativeRoute: [QUICK, WMATIC],
    outputToLp0Route: [QUICK, USDC],
    outputToLp1Route: [QUICK, ETH]
};

const contractNames = {
    vault: "BeefyVaultV6",
    strategy: "StrategyCommonRewardPoolLP"
}

const deployVault: DeployFunction = async function(hre: HardhatRuntimeEnvironment) {
    const { deploy, execute } = hre.deployments;
    const deployer = await hre.ethers.getNamedSigner('deployer');

    console.log(`Deployer: ${deployer.address}\n`);

    let contractAddress = await contractAddressGenerator(deployer);

    let vaultName = `${vaultParams.mooName} Vault`;
    let stratName = `${vaultParams.mooName} Strategy`

    let deployedVault = await hre.deployments.getOrNull(vaultName);
    let deployedStrat = await hre.deployments.getOrNull(stratName);

    strategyParams.vault = deployedVault ? deployedVault.address : (await contractAddress.next()).value as string;
    vaultParams.strategy = deployedStrat ? deployedStrat.address : (await contractAddress.next()).value as string;

    //console.log(vaultParams);
    const vaultDeployResult = await deploy(vaultName, {
        from: deployer.address,
        contract: contractNames.vault,
        args: [vaultParams.strategy, vaultParams.mooName, vaultParams.mooSymbol, vaultParams.delay],
        log: true
    });

    //console.log(strategyParams);
    const strategyDeployResult = await deploy(stratName, {
        from: deployer.address,
        contract: contractNames.strategy,
        args: [
            strategyParams.want,
            strategyParams.rewardPool,
            strategyParams.vault,
            strategyParams.unirouter,
            strategyParams.keeper,
            strategyParams.strategist,
            strategyParams.beefyFeeRecipient,
            strategyParams.outputToNativeRoute,
            strategyParams.outputToLp0Route,
            strategyParams.outputToLp1Route],
        log: true
    });

    if ('dev' in hre.network.tags) {
        if (vaultDeployResult.newlyDeployed) {
            execute(vaultName, {from: deployer.address}, 'transferOwnership', beefyfinance.cowllector);
        }
        if (strategyDeployResult.newlyDeployed) {
            execute(stratName, {from: deployer.address}, 'transferOwnership', beefyfinance.cowllector);
        }
    }
};
export default deployVault;