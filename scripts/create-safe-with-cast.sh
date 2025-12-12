#!/bin/bash

# 使用 cast 创建 Safe 钱包实例
# 需要先安装 Foundry: https://book.getfoundry.sh/getting-started/installation

set -e

echo "🚀 使用 cast 创建 Safe 钱包实例"
echo "=================================="
echo ""

# 检查 cast 是否安装
if ! command -v cast &> /dev/null; then
    echo "❌ 错误: 未找到 cast 命令"
    echo "   请安装 Foundry: https://book.getfoundry.sh/getting-started/installation"
    echo "   安装命令: curl -L https://foundry.paradigm.xyz | bash && foundryup"
    exit 1
fi

# 从环境变量读取配置
if [ -z "$SAFE_OWNERS" ]; then
    echo "❌ 错误: 未设置 SAFE_OWNERS 环境变量"
    echo ""
    echo "使用方法:"
    echo "  SAFE_OWNERS=0xOwner1,0xOwner2,0xOwner3 \\"
    echo "  SAFE_THRESHOLD=2 \\"
    echo "  RPC_URL=http://localhost:8545 \\"
    echo "  PRIVATE_KEY=your_private_key \\"
    echo "  ./scripts/create-safe-with-cast.sh"
    exit 1
fi

# 读取配置
OWNERS_STR="$SAFE_OWNERS"
THRESHOLD=${SAFE_THRESHOLD:-$(echo "$OWNERS_STR" | tr ',' '\n' | wc -l)}
RPC_URL=${RPC_URL:-"http://localhost:8545"}
PRIVATE_KEY=${PRIVATE_KEY:-""}

if [ -z "$PRIVATE_KEY" ]; then
    echo "❌ 错误: 未设置 PRIVATE_KEY 环境变量"
    exit 1
fi

# 解析所有者地址
OWNERS_ARRAY=($(echo "$OWNERS_STR" | tr ',' ' '))
OWNERS_COUNT=${#OWNERS_ARRAY[@]}

echo "📋 配置信息:"
echo "   所有者数量: $OWNERS_COUNT"
echo "   阈值: $THRESHOLD"
echo "   所有者地址:"
for i in "${!OWNERS_ARRAY[@]}"; do
    echo "     $((i+1)). ${OWNERS_ARRAY[$i]}"
done
echo "   RPC URL: $RPC_URL"
echo ""

# 读取部署信息（从 deployments 目录）
DEPLOYMENTS_DIR="deployments/custom"
if [ ! -d "$DEPLOYMENTS_DIR" ]; then
    echo "❌ 错误: 未找到部署信息目录 $DEPLOYMENTS_DIR"
    echo "   请先运行: npm run deploy custom"
    exit 1
fi

# 获取合约地址
SAFE_SINGLETON=$(jq -r .address "$DEPLOYMENTS_DIR/Safe.json" 2>/dev/null || echo "")
FACTORY=$(jq -r .address "$DEPLOYMENTS_DIR/SafeProxyFactory.json" 2>/dev/null || echo "")

if [ -z "$SAFE_SINGLETON" ] || [ "$SAFE_SINGLETON" = "null" ]; then
    echo "❌ 错误: 未找到 Safe 单例合约地址"
    echo "   请先运行: npm run deploy custom"
    exit 1
fi

if [ -z "$FACTORY" ] || [ "$FACTORY" = "null" ]; then
    echo "❌ 错误: 未找到 SafeProxyFactory 合约地址"
    echo "   请先运行: npm run deploy custom"
    exit 1
fi

echo "📦 已部署的合约:"
echo "   Safe 单例: $SAFE_SINGLETON"
echo "   工厂: $FACTORY"
echo ""

# 构建 setup 函数调用数据
# setup(address[] _owners, uint256 _threshold, address to, bytes data, address fallbackHandler, address paymentToken, uint256 payment, address paymentReceiver)
echo "📝 构建初始化数据..."

# 构建参数
ZERO_ADDRESS="0x0000000000000000000000000000000000000000"

# 如果未指定 saltNonce，使用随机值避免 CREATE2 地址冲突
if [ -z "$SAFE_SALT_NONCE" ]; then
    # 使用时间戳 + 进程ID + 随机数，确保唯一性
    SALT_NONCE=$(($(date +%s) + $$ + RANDOM))
    echo "   使用随机 saltNonce: $SALT_NONCE (避免地址冲突)"
else
    SALT_NONCE=$SAFE_SALT_NONCE
    echo "   使用指定的 saltNonce: $SALT_NONCE"
fi

# 将所有者地址转换为数组格式 [addr1,addr2,addr3]
# 将逗号分隔的字符串转换为数组格式
OWNERS_ARRAY="["
FIRST=true
for owner in $(echo "$OWNERS_STR" | tr ',' ' '); do
    if [ "$FIRST" = true ]; then
        OWNERS_ARRAY="${OWNERS_ARRAY}${owner}"
        FIRST=false
    else
        OWNERS_ARRAY="${OWNERS_ARRAY},${owner}"
    fi
done
OWNERS_ARRAY="${OWNERS_ARRAY}]"

echo "   所有者数组格式: $OWNERS_ARRAY"

# 构建完整的 setup 调用数据
# setup(address[],uint256,address,bytes,address,address,uint256,address)
SETUP_DATA=$(cast calldata "setup(address[],uint256,address,bytes,address,address,uint256,address)" \
    "$OWNERS_ARRAY" \
    "$THRESHOLD" \
    "$ZERO_ADDRESS" \
    "0x" \
    "$ZERO_ADDRESS" \
    "$ZERO_ADDRESS" \
    "0" \
    "$ZERO_ADDRESS" 2>&1)

# 检查是否有错误
if echo "$SETUP_DATA" | grep -q "Error"; then
    echo "❌ 错误: 构建初始化数据失败"
    echo "$SETUP_DATA"
    exit 1
fi

echo "   初始化数据: ${SETUP_DATA:0:100}..."
echo ""

# 调用工厂合约创建代理
echo "🚀 创建 Safe 钱包..."
echo "   交易发送中..."

# 使用 cast send 发送交易
# createProxyWithNonce(address _singleton, bytes memory initializer, uint256 saltNonce)
echo "   使用 saltNonce: $SALT_NONCE"
TX_RESULT=$(cast send \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    "$FACTORY" \
    "createProxyWithNonce(address,bytes,uint256)" \
    "$SAFE_SINGLETON" \
    "$SETUP_DATA" \
    "$SALT_NONCE" \
    --gas-limit 5000000 \
    --gas-price 10gwei \
    --legacy \
    --json 2>&1)

TX_HASH=$(echo "$TX_RESULT" | jq -r '.transactionHash' 2>/dev/null || echo "")

# 检查是否有错误
if echo "$TX_RESULT" | grep -qi "error\|revert\|failed"; then
    echo "   ❌ 交易发送失败:"
    echo "$TX_RESULT" | grep -i "error\|revert\|failed" | head -5
    echo ""
    echo "   可能的原因:"
    echo "   1. CREATE2 地址冲突（使用不同的 saltNonce）"
    echo "   2. Gas 不足"
    echo "   3. 初始化数据错误"
    echo ""
    echo "   尝试使用不同的 saltNonce:"
    echo "   SAFE_SALT_NONCE=$(($(date +%s) % 1000000)) ./scripts/create-safe-with-cast.sh"
    exit 1
fi

if [ -z "$TX_HASH" ] || [ "$TX_HASH" = "null" ]; then
    echo "❌ 错误: 无法获取交易哈希"
    echo "   交易结果:"
    echo "$TX_RESULT"
    echo ""
    echo "   请检查:"
    echo "   1. RPC_URL 是否正确"
    echo "   2. PRIVATE_KEY 是否正确"
    echo "   3. 账户是否有足够的 ETH"
    echo "   4. 如果看到 'Create2 call failed'，尝试使用不同的 saltNonce"
    exit 1
fi

echo "   交易哈希: $TX_HASH"
echo "   等待确认..."

# 等待交易确认
echo "   等待交易确认..."
sleep 5

# 获取交易收据
RECEIPT=$(cast receipt "$TX_HASH" --rpc-url "$RPC_URL" --json 2>/dev/null || echo "")

if [ -z "$RECEIPT" ]; then
    echo "⚠️  无法获取交易收据，请手动检查交易: $TX_HASH"
    exit 1
fi

# 检查交易状态
TX_STATUS=$(echo "$RECEIPT" | jq -r '.status' 2>/dev/null || echo "")
if [ "$TX_STATUS" = "0x0" ] || [ "$TX_STATUS" = "0" ]; then
    echo "❌ 错误: 交易失败"
    echo "   交易哈希: $TX_HASH"
    echo ""
    echo "   可能的原因:"
    echo "   1. CREATE2 地址冲突 - 使用相同的 saltNonce 和 initializer 已创建过代理"
    echo "   2. 初始化失败 - setup() 函数执行失败"
    echo "   3. Gas 不足"
    echo ""
    echo "   解决方案:"
    echo "   1. 使用不同的 saltNonce:"
    echo "      SAFE_SALT_NONCE=$(($(date +%s) % 1000000)) ./scripts/create-safe-with-cast.sh"
    echo "   2. 检查交易详情:"
    echo "      cast run $TX_HASH --rpc-url $RPC_URL"
    echo "   3. 查看回退原因:"
    echo "      cast receipt $TX_HASH --rpc-url $RPC_URL --json | jq"
    exit 1
fi

# 从日志中提取 Safe 地址
# ProxyCreation 事件的签名: keccak256("ProxyCreation(address,address)")
# 事件格式: ProxyCreation(SafeProxy indexed proxy, address singleton)
# proxy 地址在 topics[1]（因为它是 indexed 参数）

# 计算事件签名哈希
EVENT_SIG="ProxyCreation(address,address)"
EVENT_TOPIC=$(cast keccak "ProxyCreation(address,address)")

echo "   查找事件签名: $EVENT_TOPIC"

# 调试：显示所有日志
echo "   调试: 检查交易日志..."
ALL_LOGS=$(echo "$RECEIPT" | jq -r '.logs[] | "\(.topics[0]) \(.address)"' 2>/dev/null || echo "")
if [ -n "$ALL_LOGS" ]; then
    echo "   找到 $(echo "$ALL_LOGS" | wc -l) 个日志"
fi

# 从日志中提取 Safe 地址（proxy 在 topics[1]）
# topics[1] 是 32 字节，但地址只有 20 字节，需要提取后 20 字节
SAFE_ADDRESS_RAW=$(echo "$RECEIPT" | jq -r ".logs[] | select(.topics[0] == \"$EVENT_TOPIC\") | .topics[1]" 2>/dev/null | head -1 || echo "")

# 如果找到了，提取地址部分（去掉前导零，取后40个字符）
if [ -n "$SAFE_ADDRESS_RAW" ] && [ "$SAFE_ADDRESS_RAW" != "null" ] && [ "$SAFE_ADDRESS_RAW" != "" ]; then
    # topics 中的地址是 32 字节格式（64个十六进制字符），地址在最后 20 字节（40个字符）
    # 去掉 0x 前缀
    SAFE_ADDRESS_HEX=$(echo "$SAFE_ADDRESS_RAW" | sed 's/^0x//')
    # 确保是 64 个字符（32 字节），如果不够则前面补0
    while [ ${#SAFE_ADDRESS_HEX} -lt 64 ]; do
        SAFE_ADDRESS_HEX="0$SAFE_ADDRESS_HEX"
    done
    # 取最后 40 个字符（20 字节 = 地址）
    SAFE_ADDRESS_HEX=$(echo "$SAFE_ADDRESS_HEX" | tail -c 41)
    SAFE_ADDRESS="0x$SAFE_ADDRESS_HEX"
    echo "   从 topics[1] 提取的地址: $SAFE_ADDRESS"
else
    SAFE_ADDRESS=""
fi

# 如果 topics[1] 为空，尝试从 data 字段提取（某些情况下）
if [ -z "$SAFE_ADDRESS" ] || [ "$SAFE_ADDRESS" = "null" ] || [ "$SAFE_ADDRESS" = "" ]; then
    echo "   ⚠️  从 topics[1] 中未找到，尝试其他方法..."
    
    # 方法1: 从 topics 数组中查找（可能 topics[1] 是地址）
    SAFE_ADDRESS=$(echo "$RECEIPT" | jq -r ".logs[] | select(.topics[0] == \"$EVENT_TOPIC\") | .topics[1:] | .[] | select(. != null and . != \"\")" 2>/dev/null | head -1 || echo "")
    
    # 方法2: 从所有日志的地址中查找（新创建的合约地址）
    if [ -z "$SAFE_ADDRESS" ] || [ "$SAFE_ADDRESS" = "null" ]; then
        echo "   尝试从日志地址中查找新创建的合约..."
        # 获取所有日志中的地址，排除工厂和单例
        LOG_ADDRESSES=$(echo "$RECEIPT" | jq -r '.logs[].address' 2>/dev/null | sort -u | grep -v "$FACTORY" | grep -v "$SAFE_SINGLETON" || echo "")
        if [ -n "$LOG_ADDRESSES" ]; then
            # 检查每个地址是否有代码
            for addr in $LOG_ADDRESSES; do
                CODE=$(cast code "$addr" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
                if [ -n "$CODE" ] && [ "$CODE" != "0x" ]; then
                    SAFE_ADDRESS="$addr"
                    echo "   找到有代码的地址: $SAFE_ADDRESS"
                    break
                fi
            done
        fi
    fi
    
    # 方法3: 如果还是找不到，尝试从交易收据的文本输出中提取
    if [ -z "$SAFE_ADDRESS" ] || [ "$SAFE_ADDRESS" = "null" ]; then
        echo "   尝试从交易收据文本中提取..."
        RECEIPT_TEXT=$(cast receipt "$TX_HASH" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
        if [ -n "$RECEIPT_TEXT" ]; then
            SAFE_ADDRESS=$(echo "$RECEIPT_TEXT" | grep -oE "0x[a-fA-F0-9]{40}" | grep -v "$FACTORY" | grep -v "$SAFE_SINGLETON" | head -1 || echo "")
        fi
    fi
fi

if [ -z "$SAFE_ADDRESS" ] || [ "$SAFE_ADDRESS" = "null" ] || [ "$SAFE_ADDRESS" = "" ]; then
    echo "⚠️  无法从交易中提取 Safe 地址"
    echo "   请手动检查交易收据: $TX_HASH"
    echo ""
    echo "   可以使用以下命令查看交易:"
    echo "   cast receipt $TX_HASH --rpc-url $RPC_URL"
    echo ""
    echo "   或者查看所有日志:"
    echo "   cast receipt $TX_HASH --rpc-url $RPC_URL --json | jq .logs"
    exit 1
fi

# 移除 0x 前缀（如果有）并添加回来以确保格式正确
SAFE_ADDRESS="0x${SAFE_ADDRESS#0x}"

# 验证地址格式和代码
if ! cast --to-checksum-address "$SAFE_ADDRESS" &>/dev/null; then
    echo "⚠️  Safe 地址格式可能不正确: $SAFE_ADDRESS"
    exit 1
fi

# 最终验证地址格式
SAFE_ADDRESS=$(cast --to-checksum-address "$SAFE_ADDRESS" 2>/dev/null || echo "$SAFE_ADDRESS")

# 验证地址是否有代码
echo "   验证 Safe 地址是否有代码..."
SAFE_CODE=$(cast code "$SAFE_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
if [ -z "$SAFE_CODE" ] || [ "$SAFE_CODE" = "0x" ]; then
    echo "   ⚠️  警告: Safe 地址没有代码，可能地址不正确"
    echo "   尝试从交易收据中重新查找..."
    
    # 重新获取收据并查找所有有代码的地址
    RECEIPT_JSON=$(cast receipt "$TX_HASH" --rpc-url "$RPC_URL" --json 2>/dev/null || echo "")
    if [ -n "$RECEIPT_JSON" ]; then
        # 获取所有日志地址
        ALL_ADDRESSES=$(echo "$RECEIPT_JSON" | jq -r '.logs[].address' 2>/dev/null | sort -u || echo "")
        for addr in $ALL_ADDRESSES; do
            if [ "$addr" != "$FACTORY" ] && [ "$addr" != "$SAFE_SINGLETON" ]; then
                CODE_CHECK=$(cast code "$addr" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
                if [ -n "$CODE_CHECK" ] && [ "$CODE_CHECK" != "0x" ]; then
                    SAFE_ADDRESS="$addr"
                    echo "   找到有代码的地址: $SAFE_ADDRESS"
                    break
                fi
            fi
        done
    fi
    
    # 如果还是找不到，显示调试信息
    SAFE_CODE_FINAL=$(cast code "$SAFE_ADDRESS" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
    if [ -z "$SAFE_CODE_FINAL" ] || [ "$SAFE_CODE_FINAL" = "0x" ]; then
        echo "   ❌ 错误: 无法找到有效的 Safe 地址"
        echo "   请手动检查交易: $TX_HASH"
        echo "   查看所有日志: cast receipt $TX_HASH --rpc-url $RPC_URL --json | jq .logs"
        exit 1
    fi
fi

echo ""
echo "✅ Safe 钱包创建成功！"
echo "   Safe 地址: $SAFE_ADDRESS"
echo "   交易哈希: $TX_HASH"
echo ""

# 验证 Safe 配置
echo "🔍 验证 Safe 配置..."

# 检查阈值
THRESHOLD_RESULT=$(cast call "$SAFE_ADDRESS" "getThreshold()" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
if [ -n "$THRESHOLD_RESULT" ] && [ "$THRESHOLD_RESULT" != "0x" ]; then
    THRESHOLD_ONCHAIN=$(cast --to-dec "$THRESHOLD_RESULT" 2>/dev/null || echo "0")
else
    THRESHOLD_ONCHAIN="0"
    echo "   ⚠️  无法获取阈值"
fi

# 检查所有者（getOwners 返回数组，需要解析）
OWNERS_RESULT=$(cast call "$SAFE_ADDRESS" "getOwners()" --rpc-url "$RPC_URL" 2>/dev/null || echo "")
if [ -n "$OWNERS_RESULT" ] && [ "$OWNERS_RESULT" != "0x" ]; then
    # 从返回的数据中提取地址（数组格式：offset + length + data）
    # 简化处理：计算地址数量
    OWNERS_COUNT_ONCHAIN=$(echo "$OWNERS_RESULT" | grep -oE "0x[a-fA-F0-9]{40}" | wc -l || echo "0")
    if [ "$OWNERS_COUNT_ONCHAIN" = "0" ]; then
        # 尝试另一种方式：检查返回数据长度
        DATA_LEN=${#OWNERS_RESULT}
        if [ "$DATA_LEN" -gt 66 ]; then
            # 至少有一个地址（64字符 + 0x前缀）
            OWNERS_COUNT_ONCHAIN=$(($DATA_LEN / 66))
        fi
    fi
else
    OWNERS_COUNT_ONCHAIN="0"
    echo "   ⚠️  无法获取所有者列表"
fi

echo "   所有者数量: $OWNERS_COUNT_ONCHAIN"
echo "   阈值: $THRESHOLD_ONCHAIN"
echo ""

# 如果验证失败，提供调试信息
if [ "$OWNERS_COUNT_ONCHAIN" = "0" ] || [ "$THRESHOLD_ONCHAIN" = "0" ]; then
    echo "⚠️  警告: 无法验证 Safe 配置"
    echo "   这可能是因为:"
    echo "   1. Safe 地址提取不正确"
    echo "   2. RPC 节点响应问题"
    echo ""
    echo "   请手动验证 Safe 地址: $SAFE_ADDRESS"
    echo "   使用以下命令:"
    echo "   cast call $SAFE_ADDRESS \"getThreshold()\" --rpc-url $RPC_URL"
    echo "   cast call $SAFE_ADDRESS \"getOwners()\" --rpc-url $RPC_URL"
    echo ""
fi

# 保存部署信息
mkdir -p "$DEPLOYMENTS_DIR"
SAFE_INFO=$(jq -n \
    --arg address "$SAFE_ADDRESS" \
    --arg txHash "$TX_HASH" \
    --arg owners "$OWNERS_STR" \
    --arg threshold "$THRESHOLD" \
    '{
        address: $address,
        transactionHash: $txHash,
        owners: ($owners | split(",")),
        threshold: ($threshold | tonumber)
    }')

echo "$SAFE_INFO" > "$DEPLOYMENTS_DIR/MySafeInstance.json"
echo "💾 部署信息已保存到 $DEPLOYMENTS_DIR/MySafeInstance.json"
echo ""
echo "📝 Safe 钱包地址: $SAFE_ADDRESS"


