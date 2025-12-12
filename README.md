# 部署合约
创建env文件
```
touch .env
```
在其中写入信息
```
NODE_URL=
PK=0x
```
然后执行
```
npm run build
npm run deploy custom
```
会将合约实例，工厂等合约部署

# 创建一个自己的多签合约
```
SAFE_OWNERS=0x,0x,0x SAFE_THRESHOLD= RPC_URL= PRIVATE_KEY=0x  ./create-safe-with-cast.sh
```
