# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

Uniswap V3 协议的核心智能合约 —— 一个基于以太坊的集中流动性 AMM。Solidity 0.7.6，Hardhat 构建工具链，TypeScript 测试使用 ethers.js + Waffle + Chai。

## 常用命令

### 构建与测试

```bash
yarn install            # 安装依赖
yarn compile            # 编译 Solidity（同时生成 TypeChain 类型定义）
yarn test               # 运行全部测试
```

### 运行特定测试

```bash
yarn test test/UniswapV3Pool.spec.ts              # 运行单个文件
yarn test test/UniswapV3Pool.spec.ts -g "mint"    # 按 describe/it 名称过滤
```

### 代码检查

```bash
yarn prettier --write 'contracts/**/*.sol' 'test/**/*.ts'   # 格式化（Prettier + prettier-plugin-solidity）
yarn solhint 'contracts/**/*.sol'                           # Solidity linter（配置：.solhint.json，仅强制 prettier 规则）
```

### 模糊测试（Echidna）

每个库在 `contracts/test/` 下都有对应的 `*EchidnaTest.sol` 合约。运行命令：`echidna-test . --contract <ContractName> --config echidna.config.yml`。CI 矩阵（`.github/workflows/fuzz-testing.yml`）列出了全部 11 个目标合约：`BitMathEchidnaTest`、`TickMathEchidnaTest`、`SqrtPriceMathEchidnaTest`、`SwapMathEchidnaTest`、`TickEchidnaTest`、`TickOverflowSafetyEchidnaTest`、`OracleEchidnaTest`、`LowGasSafeMathEchidnaTest`、`UnsafeMathEchidnaTest`、`FullMathEchidnaTest`、`TickBitmapEchidnaTest`。

TypeChain 类型在每次 `yarn compile` 时重新生成，输出到 `typechain/`（已 gitignore）。测试辅助工具位于 `test/shared/`：
- `fixtures.ts` —— factory/token/pool fixture（使用 `MockTimeUniswapV3Pool`）
- `utilities.ts` —— tick/price 辅助函数、`createPoolFunctions`
- `expect.ts` —— chai 配置（`ethereum-waffle` + `mocha-chai-jest-snapshot`）
- `snapshotGasCost.ts` —— gas 快照（存放于 `test/__snapshots__/`）

## 架构

### 部署模型：CREATE2 + 临时参数

`UniswapV3PoolDeployer` 是被 `UniswapV3Factory` 继承的 mixin。它使用经典的 CREATE2 初始化模式：先将 pool 参数（factory、token0、token1、fee、tickSpacing）写入临时存储槽（`parameters`），再调用 `new UniswapV3Pool{salt: keccak256(abi.encode(token0, token1, fee))}()`，pool 的构造函数通过 `IUniswapV3PoolDeployer(msg.sender).parameters()` 读回这些参数。部署完成后该存储槽被清除。因此 pool 没有构造函数参数 —— 其字节码对每个 (token0, token1, fee) 元组是确定性的。

### 合约结构

- **`UniswapV3Factory`** —— 由 owner 管理的注册表。映射 `(token0, token1, fee) -> pool`。设置允许的费率档位及其 tick 间距（默认值：500/10、3000/60、10000/200）。继承 `UniswapV3PoolDeployer`（部署）和 `NoDelegateCall`（禁止 delegatecall）。
- **`UniswapV3Pool`** —— 核心 pool 合约。实现 `mint`/`burn`/`collect`/`swap`/`flash`，以及 owner 操作（`setFeeProtocol`、`collectProtocol`）和预言机读取（`observe`、`snapshotCumulativesInside`）。
- **`NoDelegateCall`** —— 基合约，将部署地址存为 immutable，通过 `noDelegateCall` 修饰器暴露。应用于 pool 中大多数状态变更函数。

### Pool 状态布局（UniswapV3Pool）

- **`Slot0`** —— 紧凑结构体：`sqrtPriceX96`（uint160）、`tick`（int24）、`observationIndex`/`observationCardinality`/`observationCardinalityNext`（各 uint16）、`feeProtocol`（uint8）、`unlocked`（bool —— 通过 `lock` 修饰器实现的可重入保护）。
- **手续费记账** —— 全局手续费增长以 `feeGrowthGlobal{0,1}X128`（uint256，Q128 定点数）追踪。每个 position 的手续费通过 `Position.Info` 惰性计算，键为 `keccak256(owner, tickLower, tickUpper)`。
- **Ticks** —— `ticks` 映射（int24 → `Tick.Info`）存储 liquidityGross/Net、feeGrowthOutside、预言机累加器 outside。`tickBitmap`（int16 → uint256）是压缩位图，用于查找下一个已初始化的 tick —— 每个 tick 间距倍数占一位。
- **预言机（Oracle）** —— 最多 65535 个 `Observation` 的环形缓冲区（时间戳、tick 累加值、secondsPerLiquidity 累加值）。通过 `increaseObservationCardinalityNext` 按需扩容。

### Swap 算法

`swap()` 是一个步进循环：每一步通过 `tickBitmap.nextInitializedTickWithinOneWord` 找到下一个已初始化的 tick，调用 `SwapMath.computeSwapStep` 计算本步的价格变动；若本步到达下一个 tick，则调用 `Tick.cross` 翻转 `liquidityNet` 并更新预言机/手续费累加器。循环持续到 `amountSpecified` 耗尽或触及 `sqrtPriceLimitX96`。支付通过 swap 后的余额比较来验证（回调模式 —— 调用者必须在函数返回前交付代币）。

### 库合约（contracts/libraries/）

除 `Oracle` 外均为纯函数/无状态库：
- **`TickMath`** —— `getSqrtRatioAtTick` / `getTickAtSqrtRatio` —— tick 与 sqrt(price)（Q64.96 格式）之间的转换。
- **`SqrtPriceMath`** —— `getAmount0Delta`/`getAmount1Delta` —— 给定价格区间和流动性计算代币数量。
- **`SwapMath`** —— `computeSwapStep` —— 单步 swap 的核心计算。
- **`Tick`** / **`TickBitmap`** —— tick 状态转换与位图导航。
- **`Position`** / **`Oracle`** —— position 手续费记账；TWAP 预言机。
- **`FullMath`** —— 512 位乘法（MIT 许可；其他库为 BUSL-1.1，interfaces 及部分库同时提供 GPL-2.0-or-later 双重许可）。
- **`LowGasSafeMath`** —— 节省 gas 的溢出检查算术，通过 `using ... for` 使用。

### 测试架构

测试使用 `MockTimeUniswapV3Pool`（`UniswapV3Pool` 的子类，重写 `_blockTimestamp()`），以便预言机/时间相关的测试能确定性地推进时间。`TestUniswapV3Callee` / `TestUniswapV3Router` / `TestUniswapV3SwapPay` 实现了回调接口（`IUniswapV3MintCallback`、`IUniswapV3SwapCallback`、`IUniswapV3FlashCallback`），用于在测试中驱动 pool 交互。

### 编译器设置

Solidity 0.7.6，启用优化器（800 runs），`bytecodeHash: 'none'` 以确保跨机器输出确定性。Hardhat 中 `allowUnlimitedContractSize: false`。

## 许可说明

主要许可证为 BUSL-1.1。`contracts/interfaces/` 中的接口同时提供 GPL-2.0-or-later 双重许可。`contracts/libraries/FullMath.sol` 为 MIT 许可。`contracts/test/` 中的文件未声明许可。修改文件时请保留现有的 SPDX 许可头。
