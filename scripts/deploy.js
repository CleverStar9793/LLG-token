// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
const hre = require("hardhat");

async function main() {
  // Hardhat always runs the compile task when running scripts with its command
  // line interface.
  //
  // If this script is run directly using `node` you may want to call compile
  // manually to make sure everything is compiled
  // await hre.run('compile');

  // We get the contract to deploy
  const CFC = await hre.ethers.getContractFactory("LLG");
  const cfc = await CFC.deploy("0xD99D1c33F9fC3444f8101754aBC46c52416550D1", "0xbb06F5C7689eA93d9DeACCf4aF8546C4Fe0Bf1E5");

  await cfc.deployed();

  console.log("CFC deployed to:", cfc.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
