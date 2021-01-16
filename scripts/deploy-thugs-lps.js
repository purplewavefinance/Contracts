const hardhat = require("hardhat");

const { predictAddresses } = require("../utils/predictAddresses");
const getNetworkRpc = require("../utils/getNetworkRpc");
const registerSubsidy = require("../utils/registerSubsidy");

const ethers = hardhat.ethers;

const pools = [
  {
    want: "0xF271F9Cc3E3626394978A9C0C9582931fa3caDD1",
    unirouter: "0x3bc677674df90A9e5D741f28f6CA303357D0E4Ec",
    mooName: "Moo Street BTRI-CRED",
    mooSymbol: "mooStreetBTRI-CRED",
    poolId: 31,
    strategist: "0xd529b1894491a0a26B18939274ae8ede93E81dbA",
  },
];

async function main() {
  await hardhat.run("compile");

  const Vault = await ethers.getContractFactory("BeefyVaultV3");
  const Strategy = await ethers.getContractFactory("StrategyThugsLP");

  for (pool of pools) {
    console.log("Deploying:", pool.mooName);

    const [deployer] = await ethers.getSigners();
    const rpc = getNetworkRpc(hardhat.network.name);

    const predictedAddresses = await predictAddresses({ creator: deployer.address, rpc });

    const vault = await Vault.deploy(pool.want, predictedAddresses.strategy, pool.mooName, pool.mooSymbol, 86400);
    await vault.deployed();

    const strategy = await Strategy.deploy(
      pool.want,
      pool.poolId,
      predictedAddresses.vault,
      pool.unirouter,
      pool.strategist
    );
    await strategy.deployed();

    console.log("Vault deployed to:", vault.address);
    console.log("Strategy deployed to:", strategy.address);

    await registerSubsidy(vault.address, strategy.address, deployer);

    console.log("---");
  }
}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
