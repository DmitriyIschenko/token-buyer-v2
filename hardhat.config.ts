import type {HardhatUserConfig} from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox-viem";
import {configDotenv} from "dotenv";

configDotenv();

const config: HardhatUserConfig = {
    solidity: {
        compilers: [
            {
                version: "0.8.28",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 200
                    }
                }
            },
            {
                version: "0.6.6",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 200
                    }
                },
            },
        ],
    },
    networks: {
        sepolia: {
            url: "https://sepolia.gateway.tenderly.co",
            accounts: [process.env.PRIVATE_KEY as string]
        }
    },
    etherscan: {
        apiKey: {
            sepolia: process.env.ETHERSCAN_API_KEY
        },
        customChains: [
            {
                network: "sepolia",
                chainId: 11155111 ,
                urls: {
                    apiURL: "https://api-sepolia.etherscan.io/api",
                    browserURL: "https://sepolia.etherscan.io/",
                },
            }
        ]
    },
    ignition:{
        requiredConfirmations: 1
    }
};

export default config;
