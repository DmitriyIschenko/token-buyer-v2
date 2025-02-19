// This setup uses Hardhat Ignition to manage smart contract deployments.
// Learn more about it at https://hardhat.org/ignition

import {buildModule} from "@nomicfoundation/hardhat-ignition/modules";

const TokenBuyerModule = buildModule("TokenBuyerModule", (m) => {

    const implementation = m.contract("TokenBuyer");
    const functionData = m.encodeFunctionCall(implementation, "initialize", ["0xF62c03E08ada871A0bEb309762E260a7a6a880E6"]);
    const args = [implementation, m.getAccount(0), functionData];
    const proxy = m.contract("TransparentUpgradeableProxy", args);

    return {proxy};
});

export default TokenBuyerModule;
