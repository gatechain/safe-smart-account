import { ethers } from "hardhat";
import hre from "hardhat";

/**
 * 创建 Safe 钱包实例
 * 
 * 使用方法:
 * 1. 设置环境变量（可选）:
 *    - SAFE_OWNERS: 所有者地址列表，用逗号分隔
 *    - SAFE_THRESHOLD: 需要的确认数（默认为所有者数量）
 *    - SAFE_FALLBACK_HANDLER: 回退处理器地址（可选）
 *    - SAFE_SALT_NONCE: Salt nonce（可选，用于 CREATE2 地址预测）
 * 
 * 2. 运行: npx hardhat run scripts/create-safe-instance.ts --network custom
 * 
 * 示例:
 * SAFE_OWNERS=0x123...,0x456...,0x789... SAFE_THRESHOLD=2 npx hardhat run scripts/create-safe-instance.ts --network custom
 */

async function main() {
    const { deployments } = hre;
    console.log("🚀 创建 Safe 钱包实例\n");

    // 1. 从环境变量读取配置
    const ownersEnv = process.env.SAFE_OWNERS;
    if (!ownersEnv) {
        console.log("❌ 错误: 未设置 SAFE_OWNERS 环境变量");
        console.log("\n使用方法:");
        console.log("  SAFE_OWNERS=0xOwner1,0xOwner2,0xOwner3 SAFE_THRESHOLD=2 \\");
        console.log("  npx hardhat run scripts/create-safe-instance.ts --network custom");
        process.exit(1);
    }

    // 解析所有者地址
    const owners = ownersEnv
        .split(",")
        .map((addr) => addr.trim())
        .filter((addr) => addr.length > 0);

    if (owners.length === 0) {
        console.log("❌ 错误: 未找到有效的所有者地址");
        process.exit(1);
    }

    // 验证地址格式
    for (const owner of owners) {
        if (!ethers.isAddress(owner)) {
            console.log(`❌ 错误: 无效的所有者地址: ${owner}`);
            process.exit(1);
        }
    }

    // 读取阈值
    const thresholdEnv = process.env.SAFE_THRESHOLD;
    let threshold = owners.length;
    if (thresholdEnv) {
        threshold = parseInt(thresholdEnv, 10);
        if (isNaN(threshold) || threshold < 1 || threshold > owners.length) {
            console.log(`❌ 错误: 无效的阈值 ${thresholdEnv}。必须在 1 到 ${owners.length} 之间`);
            process.exit(1);
        }
    }

    // 读取回退处理器
    const fallbackHandlerEnv = process.env.SAFE_FALLBACK_HANDLER;
    let fallbackHandler = ethers.ZeroAddress;
    if (fallbackHandlerEnv && fallbackHandlerEnv.trim() !== "") {
        if (!ethers.isAddress(fallbackHandlerEnv.trim())) {
            console.log(`❌ 错误: 无效的回退处理器地址: ${fallbackHandlerEnv}`);
            process.exit(1);
        }
        fallbackHandler = fallbackHandlerEnv.trim();
    }

    // 读取 salt nonce
    const saltNonceEnv = process.env.SAFE_SALT_NONCE;
    let saltNonce: bigint;
    if (saltNonceEnv) {
        saltNonce = BigInt(saltNonceEnv);
    } else {
        // 使用随机 salt nonce
        saltNonce = BigInt(Math.floor(Math.random() * 1000000));
    }

    console.log("📋 配置信息:");
    console.log("   所有者数量:", owners.length);
    console.log("   阈值:", threshold);
    console.log("   所有者地址:");
    owners.forEach((owner, index) => {
        console.log(`     ${index + 1}. ${owner}`);
    });
    if (fallbackHandler !== ethers.ZeroAddress) {
        console.log("   回退处理器:", fallbackHandler);
    }
    console.log("   Salt Nonce:", saltNonce.toString());
    console.log("");

    // 2. 获取已部署的合约
    console.log("📦 获取已部署的合约...");
    const safeSingleton = await deployments.get("Safe");
    const factory = await deployments.get("SafeProxyFactory");

    console.log("   Safe 单例地址:", safeSingleton.address);
    console.log("   工厂地址:", factory.address);
    console.log("");

    const factoryContract = await ethers.getContractAt("SafeProxyFactory", factory.address);
    const safeContract = await ethers.getContractAt("Safe", safeSingleton.address);

    // 3. 准备初始化数据
    console.log("📝 准备初始化数据...");
    const initializer = safeContract.interface.encodeFunctionData("setup", [
        owners,
        threshold,
        ethers.ZeroAddress, // to
        "0x", // data
        fallbackHandler,
        ethers.ZeroAddress, // paymentToken
        0, // payment
        ethers.ZeroAddress, // paymentReceiver
    ]);

    // 4. 预测地址（可选）
    try {
        console.log("📍 预测 Safe 钱包地址...");
        const predictedAddress = await factoryContract.createProxyWithNonce.staticCall(
            safeSingleton.address,
            initializer,
            saltNonce
        );
        console.log("   预测地址:", predictedAddress);
        console.log("");
    } catch (error: any) {
        console.log("   ⚠️  无法预测地址（可能已存在）");
        console.log("");
    }

    // 5. 创建 Safe 钱包
    console.log("🚀 正在创建 Safe 钱包...");
    const [deployer] = await ethers.getSigners();
    console.log("   部署者:", deployer.address);
    console.log("   余额:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH");
    console.log("");

    const tx = await factoryContract.createProxyWithNonce(
        safeSingleton.address,
        initializer,
        saltNonce
    );
    console.log("   交易哈希:", tx.hash);
    console.log("   等待确认...");

    const receipt = await tx.wait();
    if (!receipt) {
        throw new Error("交易失败：未收到收据");
    }

    // 6. 从事件中获取创建的 Safe 地址
    let safeAddress: string | null = null;
    if (receipt.logs) {
        for (const log of receipt.logs) {
            try {
                const parsedLog = factoryContract.interface.parseLog(log);
                if (parsedLog && parsedLog.name === "ProxyCreation") {
                    safeAddress = parsedLog.args.proxy;
                    break;
                }
            } catch {
                // 忽略解析错误
            }
        }
    }

    // 如果无法从事件获取，尝试查询
    if (!safeAddress) {
        const filter = factoryContract.filters.ProxyCreation();
        const events = await factoryContract.queryFilter(filter, receipt.blockNumber, receipt.blockNumber);
        if (events.length > 0) {
            safeAddress = events[events.length - 1].args.proxy;
        }
    }

    if (!safeAddress) {
        throw new Error("无法确定创建的 Safe 地址。请检查交易收据中的事件");
    }

    console.log("\n✅ Safe 钱包创建成功！");
    console.log("   Safe 地址:", safeAddress);
    console.log("   交易哈希:", receipt.hash);
    console.log("   区块:", receipt.blockNumber);
    console.log("   Gas 使用:", receipt.gasUsed.toString());

    // 7. 验证 Safe 配置
    console.log("\n🔍 验证 Safe 配置...");
    const safeInstance = await ethers.getContractAt("Safe", safeAddress);
    const safeOwners = await safeInstance.getOwners();
    const safeThreshold = await safeInstance.getThreshold();
    const safeVersion = await safeInstance.VERSION();

    console.log("   版本:", safeVersion);
    console.log("   所有者数量:", safeOwners.length);
    console.log("   阈值:", safeThreshold.toString());
    console.log("   所有者列表:");
    safeOwners.forEach((owner: string, index: number) => {
        console.log(`     ${index + 1}. ${owner}`);
    });

    // 8. 保存部署信息（可选）
    try {
        await deployments.save("MySafeInstance", {
            address: safeAddress,
            abi: safeSingleton.abi,
        });
        console.log("\n💾 部署信息已保存到 deployments/custom/MySafeInstance.json");
    } catch (error) {
        console.log("\n⚠️  无法保存部署信息（可能已存在）");
    }

    // 9. 输出使用说明
    console.log("\n📖 使用说明:");
    console.log("   1. Safe 钱包地址:", safeAddress);
    console.log("   2. 可以通过 Safe 钱包执行交易，需要", threshold, "个所有者签名");
    console.log("   3. 可以使用 Safe SDK 或前端界面来管理 Safe 钱包");
    console.log("   4. 查看 USAGE_GUIDE_CN.md 了解更多使用方法");
    console.log("");

    // 10. 输出 JSON 格式（方便脚本使用）
    console.log("📄 JSON 格式输出:");
    console.log(JSON.stringify({
        safeAddress,
        owners: safeOwners,
        threshold: safeThreshold.toString(),
        version: safeVersion,
        factory: factory.address,
        singleton: safeSingleton.address,
        transactionHash: receipt.hash,
        blockNumber: receipt.blockNumber,
    }, null, 2));
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("\n❌ 错误:", error);
        process.exit(1);
    });


