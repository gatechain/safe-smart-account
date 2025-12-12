import "@nomicfoundation/hardhat-toolbox";
import type { HardhatUserConfig, HttpNetworkUserConfig } from "hardhat/types";
import "hardhat-deploy";
import type { DeterministicDeploymentInfo } from "hardhat-deploy/dist/types";
import dotenv from "dotenv";
import yargs from "yargs";
import { hideBin } from "yargs/helpers";
import { getSingletonFactoryInfo } from "@safe-global/safe-singleton-factory";

import "./src/tasks/local_verify";
import "./src/tasks/deploy_contracts";
import "./src/tasks/show_codesize";

const argv = yargs(hideBin(process.argv))
    .option("network", {
        type: "string",
        default: "hardhat",
    })
    .help(false)
    .version(false)
    .parseSync();

dotenv.config({ quiet: true });
const {
    NODE_URL,
    INFURA_KEY,
    MNEMONIC,
    ETHERSCAN_API_KEY,
    PK,
    SOLIDITY_VERSION,
    SOLIDITY_SETTINGS,
    HARDHAT_CHAIN_ID,
    HARDHAT_ENABLE_GAS_REPORTER,
} = process.env;

if (["mainnet", "sepolia"].includes(argv.network) && INFURA_KEY === undefined) {
    throw new Error(`Could not find Infura key in env, unable to connect to network ${argv.network}`);
}

const DEFAULT_MNEMONIC = "candy maple cake sugar pudding cream honey rich smooth crumble sweet treat";
const DEFAULT_SOLIDITY_VERSION = "0.7.6";

const sharedNetworkConfig: HttpNetworkUserConfig = {};
if (PK) {
    sharedNetworkConfig.accounts = [PK];
} else {
    sharedNetworkConfig.accounts = {
        mnemonic: MNEMONIC ?? DEFAULT_MNEMONIC,
    };
}
const soliditySettings = SOLIDITY_SETTINGS ? JSON.parse(SOLIDITY_SETTINGS) : undefined;

const deterministicDeployment = (network: string): DeterministicDeploymentInfo | undefined => {
    // 对于 custom 网络（私网），直接使用普通部署，不要求确定性部署
    if (network === "custom") {
        return undefined;
    }
    
    // 尝试将网络名称解析为数字（chainId）
    const chainId = parseInt(network);
    if (isNaN(chainId)) {
        // 如果是预定义网络名称（如 mainnet, sepolia），尝试获取其 chainId
        const networkChainIds: Record<string, number> = {
            mainnet: 1,
            sepolia: 11155111,
            gnosis: 100,
            zksync: 324,
        };
        const actualChainId = networkChainIds[network];
        if (actualChainId) {
            const info = getSingletonFactoryInfo(actualChainId);
            if (!info) {
                throw new Error(
                    `Safe factory not found for network ${network} (Chain ID: ${actualChainId}). You can request a new deployment at https://github.com/safe-global/safe-singleton-factory.`,
                );
            }
            return {
                factory: info.address,
                deployer: info.signerAddress,
                funding: `${BigInt(info.gasLimit) * BigInt(info.gasPrice)}`,
                signedTx: info.transaction,
            };
        }
        // 未知网络名称，返回 undefined 使用普通部署
        return undefined;
    }
    
    // 网络名称是数字（chainId）
    const info = getSingletonFactoryInfo(chainId);
    if (!info) {
        // 如果找不到工厂，检查是否是已知的公网
        // 已知的公网 chainId 列表
        const knownPublicNetworks = [1, 5, 10, 56, 100, 137, 250, 42161, 43114, 11155111, 324];
        
        if (knownPublicNetworks.includes(chainId)) {
            // 已知的公网但找不到工厂，报错
            throw new Error(
                `Safe factory not found for network ${network} (Chain ID: ${chainId}). You can request a new deployment at https://github.com/safe-global/safe-singleton-factory.`,
            );
        }
        
        // 对于私网或未知网络，返回 undefined 使用普通部署
        // 这样可以避免私网部署失败
        return undefined;
    }
    return {
        factory: info.address,
        deployer: info.signerAddress,
        funding: `${BigInt(info.gasLimit) * BigInt(info.gasPrice)}`,
        signedTx: info.transaction,
    };
};

const userConfig: HardhatUserConfig = {
    paths: {
        artifacts: "build/artifacts",
        cache: "build/cache",
        deploy: "src/deploy",
        sources: "contracts",
    },
    typechain: {
        outDir: "typechain-types",
        target: "ethers-v6",
    },
    solidity: {
        compilers: [
            { version: SOLIDITY_VERSION ?? DEFAULT_SOLIDITY_VERSION, settings: soliditySettings },
            { version: DEFAULT_SOLIDITY_VERSION },
        ],
    },
    networks: {
        hardhat: {
            allowUnlimitedContractSize: true,
            blockGasLimit: 100000000,
            gas: 100000000,
            chainId: Number(HARDHAT_CHAIN_ID ?? 31337),
        },
        mainnet: {
            ...sharedNetworkConfig,
            url: `https://mainnet.infura.io/v3/${INFURA_KEY}`,
        },
        sepolia: {
            ...sharedNetworkConfig,
            url: `https://sepolia.infura.io/v3/${INFURA_KEY}`,
        },
        gnosis: {
            ...sharedNetworkConfig,
            url: `https://rpc.gnosischain.com`,
        },
        zksync: {
            ...sharedNetworkConfig,
            url: "https://mainnet.era.zksync.io",
        },
        ...(NODE_URL
            ? {
                  custom: {
                      ...sharedNetworkConfig,
                      url: NODE_URL,
                  },
              }
            : {}),
    },
    deterministicDeployment,
    namedAccounts: {
        deployer: 0,
    },
    mocha: {
        timeout: 2000000,
    },
    etherscan: {
        apiKey: ETHERSCAN_API_KEY,
    },
    gasReporter: {
        enabled: HARDHAT_ENABLE_GAS_REPORTER === "1",
    },
};

export default userConfig;

