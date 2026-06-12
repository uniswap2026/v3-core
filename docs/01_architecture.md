# Uniswap V3 核心合约架构分析

> 本文档按功能分类，由浅入深说明 `contracts/*.sol` 四个顶层合约的主入口点、核心业务逻辑和使用场景。

## 目录

1. [合约总览](#1-合约总览)
2. [入口层：工厂合约 UniswapV3Factory](#2-入口层工厂合约-uniswapv3factory)
3. [部署层：池部署器 UniswapV3PoolDeployer](#3-部署层池部署器-uniswapv3pooldeployer)
4. [安全层：NoDelegateCall](#4-安全层nodelegatecall)
5. [核心层：UniswapV3Pool 状态布局](#5-核心层uniswapv3pool-状态布局)
6. [核心业务一：池初始化](#6-核心业务一池初始化)
7. [核心业务二：流动性管理（mint / burn / collect）](#7-核心业务二流动性管理mint--burn--collect)
8. [核心业务三：代币交换（swap）](#8-核心业务三代币交换swap)
9. [核心业务四：闪电贷（flash）](#9-核心业务四闪电贷flash)
10. [核心业务五：预言机（observe）](#10-核心业务五预言机observe)
11. [核心业务六：协议费用管理](#11-核心业务六协议费用管理)
12. [回调机制详解](#12-回调机制详解)
13. [使用场景汇总](#13-使用场景汇总)
14. [合约调用关系图](#14-合约调用关系图)

---

## 1. 合约总览

Uniswap V3 核心由 **4 个顶层合约** 构成，形成三层架构：

```
┌─────────────────────────────────────────────────┐
│              入口层 / 管理层                      │
│             UniswapV3Factory                     │
│   (创建池、管理费率档位、管理协议费用所有权)         │
└──────────────┬──────────────────────┬────────────┘
               │ 继承                  │ 继承
┌──────────────▼──────────┐  ┌────────▼────────────┐
│     部署层（mixin）       │  │   安全层（mixin）     │
│  UniswapV3PoolDeployer  │  │   NoDelegateCall    │
│  (CREATE2 确定性部署)     │  │  (防委托调用保护)     │
└──────────────┬──────────┘  └────────┬────────────┘
               │                      │
┌──────────────▼──────────────────────▼────────────┐
│              核心层 / 业务层                        │
│                  UniswapV3Pool                     │
│  (mint/burn/collect/swap/flash/observe/协议费用)   │
└──────────────────────────────────────────────────┘
```

| 合约 | 职责 | 主入口函数 |
|------|------|-----------|
| `UniswapV3Factory` | 注册表 + 池创建 + 协议管理 | `createPool()`, `enableFeeAmount()`, `setOwner()` |
| `UniswapV3PoolDeployer` | CREATE2 确定性部署 | `deploy()` (internal) |
| `NoDelegateCall` | 禁止 delegatecall | `noDelegateCall` modifier |
| `UniswapV3Pool` | 所有池核心业务 | `initialize()`, `mint()`, `burn()`, `collect()`, `swap()`, `flash()`, `observe()` |

---

## 2. 入口层：工厂合约 UniswapV3Factory

**文件**: `contracts/UniswapV3Factory.sol`

### 2.1 主入口点

| 函数 | 权限 | 说明 |
|------|------|------|
| `createPool(tokenA, tokenB, fee)` | 任何人 | 创建新的交易池 |
| `enableFeeAmount(fee, tickSpacing)` | 仅 owner | 启用新的费率档位 |
| `setOwner(_owner)` | 仅 owner | 转移工厂所有权 |

### 2.2 核心业务逻辑

**池创建流程 (`createPool`)：**

```
调用者
  │
  ├─ createPool(tokenA, tokenB, fee)
  │    │
  │    ├─ 1. 校验: tokenA ≠ tokenB
  │    ├─ 2. 排序: token0 < token1 (地址排序)
  │    ├─ 3. 校验: token0 ≠ address(0)
  │    ├─ 4. 查表: tickSpacing = feeAmountTickSpacing[fee]
  │    ├─ 5. 校验: tickSpacing ≠ 0 (费率已启用)
  │    ├─ 6. 校验: getPool[token0][token1][fee] == address(0) (池不存在)
  │    ├─ 7. 调用: deploy(factory, token0, token1, fee, tickSpacing)  ← 部署层
  │    ├─ 8. 注册: getPool[token0][token1][fee] = pool
  │    ├─ 9. 注册: getPool[token1][token0][fee] = pool (反向映射)
  │    └─ 10. emit PoolCreated(...)
  │
  └─ 返回 pool 地址
```

**费率管理逻辑：**

- 构造函数预设三档费率：
  - `500` (0.05%) → tick 间距 `10`（稳定币对，如 USDC/USDT）
  - `3000` (0.3%) → tick 间距 `60`（主流交易对，如 ETH/USDC）
  - `10000` (1%) → tick 间距 `200`（高波动性对，如 WBTC/ETH）
- `enableFeeAmount()` 允许 owner 添加自定义费率，但 tick 间距上限为 16384（防止位图溢出）
- 费率一旦启用**不可移除**

### 2.3 使用场景

- **DApp 前端**：通过 `getPool(tokenA, tokenB, fee)` 查询池地址
- **做市商**：调用 `createPool()` 为新交易对创建池
- **协议治理**：通过 `enableFeeAmount()` 添加新费率档位，通过 `setOwner()` 转移管理权

---

## 3. 部署层：池部署器 UniswapV3PoolDeployer

**文件**: `contracts/UniswapV3PoolDeployer.sol`

### 3.1 主入口点

| 函数 | 权限 | 说明 |
|------|------|------|
| `deploy(factory, token0, token1, fee, tickSpacing)` | internal（仅工厂调用） | 使用 CREATE2 部署池 |

### 3.2 核心业务逻辑

**CREATE2 临时参数模式：**

```
步骤 1: 写入临时参数
  parameters = {factory, token0, token1, fee, tickSpacing}
  (存储在合约的存储槽中)

步骤 2: CREATE2 部署
  new UniswapV3Pool{salt: keccak256(abi.encode(token0, token1, fee))}()
  │
  └─ UniswapV3Pool.constructor() 执行:
       ├─ 读取: IUniswapV3PoolDeployer(msg.sender).parameters()
       ├─ 解析: factory, token0, token1, fee, tickSpacing
       ├─ 计算: maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(tickSpacing)
       └─ 设置: immutable 变量 (factory, token0, token1, fee, tickSpacing, maxLiquidityPerTick)

步骤 3: 清除临时参数
  delete parameters
```

**为什么使用这种模式？**

| 特性 | 说明 |
|------|------|
| **确定性地址** | 池地址 = `CREATE2(factory, salt, bytecode)`，仅取决于三个参数 |
| **无构造函数参数** | 所有相同 (token0, token1, fee) 的池具有完全相同的字节码 |
| **跨链一致性** | 在不同 EVM 链上部署相同池，地址完全一致 |
| **预计算地址** | 可以在部署前通过 `getPool()` 计算地址，无需实际部署 |

### 3.3 使用场景

- 被 `UniswapV3Factory.createPool()` 内部调用
- 外部合约可以通过 `IUniswapV3PoolDeployer.parameters()` 在池构造函数中读取参数

---

## 4. 安全层：NoDelegateCall

**文件**: `contracts/NoDelegateCall.sol`

### 4.1 入口点

| 修饰器 | 应用范围 | 说明 |
|--------|---------|------|
| `noDelegateCall` | Factory.createPool, Pool 中大多数状态变更函数 | 防止委托调用 |

### 4.2 核心机制

```
构造函数:
  original = address(this)  // 存储为 immutable（内联到字节码）

运行时检查:
  noDelegateCall modifier → checkNotDelegateCall()
    │
    └─ require(address(this) == original)
         ├─ 正常调用: address(this) == original ✓
         └─ delegatecall: address(this) == 调用者地址 ≠ original ✗ REVERT
```

**为什么需要防止 delegatecall？**

Uniswap V3 使用**余额差值**（balance check）模式验证支付：
1. 记录调用前余额
2. 执行操作（如 swap）
3. 回调调用者，让调用者支付代币
4. 比较调用后余额 ≥ 调用前余额 + 应付数量

如果允许 delegatecall，攻击者可以在恶意合约的上下文中执行池代码，操纵余额检查逻辑，盗取池中资金。

### 4.3 应用范围

- `UniswapV3Factory.createPool()`
- `UniswapV3Pool`: `mint()`, `_modifyPosition()`, `swap()`, `flash()`, `increaseObservationCardinalityNext()`, `snapshotCumulativesInside()`, `observe()`, `setFeeProtocol()`, `collectProtocol()`

---

## 5. 核心层：UniswapV3Pool 状态布局

**文件**: `contracts/UniswapV3Pool.sol`

### 5.1 Immutable 状态（部署时设定，不可更改）

| 变量 | 类型 | 说明 |
|------|------|------|
| `factory` | address | 工厂合约地址 |
| `token0` | address | 代币 0（地址较小者） |
| `token1` | address | 代币 1（地址较大者） |
| `fee` | uint24 | 交易费率（1e-6 单位） |
| `tickSpacing` | int24 | tick 间距 |
| `maxLiquidityPerTick` | uint128 | 单 tick 最大流动性 |

### 5.2 Slot0（核心状态槽，打包存储节省 gas）

```solidity
struct Slot0 {
    uint160 sqrtPriceX96;        // 当前价格（Q64.96 格式的 sqrt(price)）
    int24   tick;                // 当前 tick
    uint16  observationIndex;    // 预言机最新写入索引
    uint16  observationCardinality;      // 当前预言机容量
    uint16  observationCardinalityNext;  // 目标预言机容量
    uint8   feeProtocol;         // 协议费用（低4位=token0，高4位=token1）
    bool    unlocked;            // 重入锁
}
```

### 5.3 其他存储状态

| 变量 | 类型 | 说明 |
|------|------|------|
| `feeGrowthGlobal0X128` | uint256 | token0 全局手续费累加器（Q128） |
| `feeGrowthGlobal1X128` | uint256 | token1 全局手续费累加器（Q128） |
| `protocolFees` | ProtocolFees | 累积的协议费用 |
| `liquidity` | uint128 | 当前价格范围内的可用流动性 |
| `ticks` | mapping(int24 → Tick.Info) | tick 状态映射 |
| `tickBitmap` | mapping(int16 → uint256) | tick 初始化位图 |
| `positions` | mapping(bytes32 → Position.Info) | 流动性头寸映射 |
| `observations` | Observation[65535] | 预言机环形缓冲区 |

---

## 6. 核心业务一：池初始化

### 6.1 入口点

| 函数 | 权限 | 说明 |
|------|------|------|
| `initialize(sqrtPriceX96)` | 任何人（仅一次） | 设置池的初始价格 |

### 6.2 业务流程

```
initialize(sqrtPriceX96)
  │
  ├─ 1. 校验: slot0.sqrtPriceX96 == 0（未初始化过）
  ├─ 2. 计算: tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96)
  ├─ 3. 初始化: observations.initialize(blockTimestamp)
  │    └─ 写入 observations[0]，cardinality = 1
  ├─ 4. 设置 slot0:
  │    ├─ sqrtPriceX96, tick
  │    ├─ observationIndex = 0
  │    ├─ observationCardinality = 1
  │    ├─ observationCardinalityNext = 1
  │    ├─ feeProtocol = 0
  │    └─ unlocked = true
  └─ 5. emit Initialize(sqrtPriceX96, tick)
```

### 6.3 使用场景

池通过 `createPool()` 部署后，**必须**先调用 `initialize()` 设置初始价格，否则所有后续操作（mint/swap）都会因 `unlocked == false` 而被 `lock` 修饰器拒绝。

---

## 7. 核心业务二：流动性管理（mint / burn / collect）

### 7.1 入口点

| 函数 | 权限 | 说明 |
|------|------|------|
| `mint(recipient, tickLower, tickUpper, amount, data)` | 任何人 | 创建流动性头寸 |
| `burn(tickLower, tickUpper, amount)` | 任何人（仅限自己的头寸） | 销毁流动性头寸 |
| `collect(recipient, tickLower, tickUpper, amount0Requested, amount1Requested)` | 任何人（仅限自己的头寸） | 提取累积的手续费 |

### 7.2 头寸标识

每个头寸由三元组唯一标识：

```
key = keccak256(abi.encodePacked(owner, tickLower, tickUpper))
```

一个地址可以在同一个池中持有**多个不同价格范围**的头寸。

### 7.3 mint 业务流程

```
mint(recipient, tickLower, tickUpper, amount, data)
  │
  ├─ 1. lock() 修饰器: 防止重入
  ├─ 2. 校验: amount > 0
  ├─ 3. _modifyPosition() 内部调用:
  │    ├─ checkTicks() 验证 tick 范围
  │    ├─ _updatePosition() 更新 tick 状态和位图:
  │    │    ├─ 更新下界 tick (liquidityGross, liquidityNet, feeGrowthOutside...)
  │    │    ├─ 更新上界 tick
  │    │    ├─ 如果 tick 首次初始化: flipTick() 在位图中标记
  │    │    └─ 计算 feeGrowthInside 并更新 Position.Info
  │    └─ 根据当前 tick 位置计算代币需求:
  │         ├─ tick < tickLower: 只需 token0
  │         ├─ tickLower ≤ tick < tickUpper: 需要 token0 + token1，同时写入预言机
  │         └─ tick ≥ tickUpper: 只需 token1
  │
  ├─ 4. 记录调用前余额: balance0Before, balance1Before
  ├─ 5. 回调: IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data)
  ├─ 6. 余额验证: balance0After ≥ balance0Before + amount0（token1 同理）
  └─ 7. emit Mint(...)
```

### 7.4 burn 业务流程

```
burn(tickLower, tickUpper, amount)
  │
  ├─ 1. lock() 修饰器
  ├─ 2. _modifyPosition() 减少流动性 (liquidityDelta = -amount):
  │    ├─ 更新 tick 状态
  │    ├─ 如果 tick 不再被引用: flipTick() 清除位图标记, clear() 删除 tick 数据
  │    └─ 计算可回收的代币数量
  ├─ 3. 增加 tokensOwed0/tokensOwed1（记录在 Position.Info 中）
  ├─ 4. emit Burn(...)
  │
  └─ 注意: burn 不实际转账，需额外调用 collect() 提取代币
```

### 7.5 collect 业务流程

```
collect(recipient, tickLower, tickUpper, amount0Requested, amount1Requested)
  │
  ├─ 1. lock() 修饰器
  ├─ 2. 读取 Position.Info[msg.sender][tickLower][tickUpper]
  ├─ 3. 实际提取量 = min(requested, tokensOwed)
  ├─ 4. 减少 tokensOwed0/tokensOwed1
  ├─ 5. TransferHelper.safeTransfer() 转账
  └─ 6. emit Collect(...)
```

### 7.6 使用场景

- **做市商开仓**：调用 `mint()` 在特定价格范围提供流动性
- **做市商平仓**：先 `burn()` 销毁流动性，再 `collect()` 提取本金和手续费
- **仅提取手续费**：调用 `burn(amount=0)` 触发手续费重新计算，再 `collect()`
- **被动做市策略**：通过 periphery 合约自动调整头寸范围

---

## 8. 核心业务三：代币交换（swap）

### 8.1 入口点

| 函数 | 权限 | 说明 |
|------|------|------|
| `swap(recipient, zeroForOne, amountSpecified, sqrtPriceLimitX96, data)` | 任何人 | 在两个代币之间执行交换 |

### 8.2 参数说明

| 参数 | 说明 |
|------|------|
| `recipient` | 输出代币接收者 |
| `zeroForOne` | `true` = token0→token1, `false` = token1→token0 |
| `amountSpecified` | 正数 = 精确输入（指定输入量），负数 = 精确输出（指定输出量） |
| `sqrtPriceLimitX96` | 价格保护限制 |

### 8.3 核心算法：步进循环

这是 Uniswap V3 最核心的算法，处理集中流动性下的价格发现和交易执行：

```
swap(...)
  │
  ├─ 前置检查
  │    ├─ amountSpecified ≠ 0
  │    ├─ unlocked == true (lock 检查)
  │    └─ sqrtPriceLimitX96 方向验证
  │
  ├─ 初始化状态
  │    ├─ SwapCache: liquidityStart, blockTimestamp, feeProtocol
  │    ├─ SwapState: amountSpecifiedRemaining, amountCalculated, sqrtPriceX96, tick...
  │    └─ slot0.unlocked = false
  │
  ├─ ★ 主循环: while (剩余量 ≠ 0 && 当前价格 ≠ 限制价格)
  │    │
  │    ├─ Step 1: 查找下一个初始化 tick
  │    │    └─ tickBitmap.nextInitializedTickWithinOneWord(tick, tickSpacing, direction)
  │    │         └─ 使用位运算在 256 位字中快速定位
  │    │
  │    ├─ Step 2: 计算本步交换结果
  │    │    └─ SwapMath.computeSwapStep(...)
  │    │         ├─ 确定是否能到达目标 tick
  │    │         ├─ 计算实际输入量 amountIn
  │    │         ├─ 计算实际输出量 amountOut
  │    │         └─ 计算手续费 feeAmount
  │    │
  │    ├─ Step 3: 更新 SwapState
  │    │    ├─ 精确输入: 减少剩余输入，累加输出
  │    │    └─ 精确输出: 累加已获输出，减少剩余需求
  │    │
  │    ├─ Step 4: 协议费用（如果启用）
  │    │    └─ protocolFee = feeAmount / feeProtocol
  │    │
  │    ├─ Step 5: 全局手续费累加
  │    │    └─ feeGrowthGlobal += feeAmount * Q128 / liquidity
  │    │
  │    └─ Step 6: Tick 转换（如果到达下一个 tick）
  │         ├─ 获取预言机累加值（首次跨越时缓存）
  │         ├─ Tick.cross(tickNext)
  │         │    ├─ 翻转 feeGrowthOutside
  │         │    ├─ 翻转 secondsPerLiquidityOutside
  │         │    ├─ 翻转 tickCumulativeOutside
  │         │    └─ 返回 liquidityNet
  │         ├─ 更新当前流动性: liquidity += liquidityNet
  │         └─ 更新当前 tick
  │
  ├─ 后处理
  │    ├─ 如果 tick 变化: 写入预言机 + 更新 slot0
  │    ├─ 如果 liquidity 变化: 更新全局 liquidity
  │    └─ 更新 feeGrowthGlobal 和 protocolFees
  │
  ├─ 计算最终 amount0, amount1
  │
  ├─ 支付阶段（回调模式）
  │    ├─ zeroForOne:
  │    │    ├─ 先转出 token1 给 recipient
  │    │    ├─ 回调: IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data)
  │    │    └─ 验证: balance0After ≥ balance0Before + amount0
  │    └─ oneForZero: (对称)
  │
  └─ emit Swap(...) + 解锁
```

### 8.4 价格移动方向

| 方向 | zeroForOne | 价格变化 | tick 变化 | 流动性变化 |
|------|-----------|---------|----------|-----------|
| token0 → token1 | true | 下降 | 减小 | 跨越上界 tick 时 -liquidityNet |
| token1 → token0 | false | 上升 | 增大 | 跨越下界 tick 时 +liquidityNet |

### 8.5 使用场景

- **终端用户交易**：通过 Router 合约调用 `swap()` 进行代币兑换
- **套利机器人**：利用价格偏差在多个池之间套利
- **限价单**：设置 `sqrtPriceLimitX96` 实现价格条件触发
- **清算**：借贷协议通过 `swap()` 清算抵押品

---

## 9. 核心业务四：闪电贷（flash）

### 9.1 入口点

| 函数 | 权限 | 说明 |
|------|------|------|
| `flash(recipient, amount0, amount1, data)` | 任何人 | 闪电贷借出代币 |

### 9.2 业务流程

```
flash(recipient, amount0, amount1, data)
  │
  ├─ 1. lock() + noDelegateCall
  ├─ 2. 校验: liquidity > 0
  ├─ 3. 计算手续费（向上取整保护池）:
  │    ├─ fee0 = ceil(amount0 * fee / 1e6)
  │    └─ fee1 = ceil(amount1 * fee / 1e6)
  ├─ 4. 记录借出前余额
  ├─ 5. 转出代币（如果 amount > 0）
  ├─ 6. 回调: IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data)
  ├─ 7. 验证余额: balanceAfter ≥ balanceBefore + fee
  ├─ 8. 计算实际支付金额: paid = balanceAfter - balanceBefore
  ├─ 9. 费用分配:
  │    ├─ 协议费用: paid / feeProtocol → protocolFees
  │    └─ LP 费用: (paid - protocolFee) * Q128 / liquidity → feeGrowthGlobal
  └─ 10. emit Flash(...)
```

### 9.3 特殊用途：捐赠

调用 `flash(amount0=0, amount1=0)` 并在回调中向池转入代币，可以按比例向当前范围内的所有流动性提供者捐赠代币（无需创建头寸）。

### 9.4 使用场景

- **跨池套利**：借用代币在另一池交易后归还
- **清算**：借贷协议清算时借用资金
- **捐赠**：向流动性提供者按比例分发奖励
- **杠杆交易**：借出代币作为保证金

---

## 10. 核心业务五：预言机（observe）

### 10.1 入口点

| 函数 | 权限 | 说明 |
|------|------|------|
| `observe(secondsAgos)` | 任何人（view） | 查询历史累加器值 |
| `snapshotCumulativesInside(tickLower, tickUpper)` | 任何人（view） | 获取范围内的累加器快照 |
| `increaseObservationCardinalityNext(next)` | 任何人 | 扩容预言机 |

### 10.2 TWAP 计算原理

```
时间:          t1                    t2
累加器:   tickCumulative[t1]    tickCumulative[t2]

TWAP_tick = (tickCumulative[t2] - tickCumulative[t1]) / (t2 - t1)
TWAP_price = 1.0001 ^ TWAP_tick
```

### 10.3 预言机数据结构

```
Observation[65535] (环形缓冲区)
  │
  ├─ Observation:
  │    ├─ blockTimestamp (uint32)
  │    ├─ tickCumulative (int56)
  │    ├─ secondsPerLiquidityCumulativeX128 (uint160)
  │    └─ initialized (bool)
  │
  ├─ observationIndex: 最新写入位置
  ├─ observationCardinality: 当前容量
  └─ observationCardinalityNext: 目标容量
```

**写入机制**：每个区块最多写入一次（同区块幂等），通过 `observations.write()` 在 `mint`/`burn`/`swap` 时自动触发。

**扩容机制**：任何人可调用 `increaseObservationCardinalityNext()` 预分配存储槽（降低后续 swap 的冷 SSTORE 成本）。

### 10.4 使用场景

- **TWAP 价格源**：DeFi 协议（如借贷协议）读取时间加权平均价格
- **流动性分析**：通过 `secondsPerLiquidity` 评估头寸的流动性利用率
- **MEV 防护**：使用多区块 TWAP 而非瞬时价格，抵抗闪电贷价格操纵
- **链上指数**：构建基于 TWAP 的链上价格指数

---

## 11. 核心业务六：协议费用管理

### 11.1 入口点

| 函数 | 合约 | 权限 | 说明 |
|------|------|------|------|
| `setFeeProtocol(feeProtocol0, feeProtocol1)` | Pool | 工厂 owner | 设置协议费用比例 |
| `collectProtocol(recipient, amount0Requested, amount1Requested)` | Pool | 工厂 owner | 提取累积的协议费用 |

### 11.2 协议费用机制

```
feeProtocol 编码 (uint8):
  ┌──── 高 4 位 ────┬──── 低 4 位 ────┐
  │ token1 分母      │ token0 分母     │
  │ (feeProtocol>>4) │ (feeProtocol%16)│
  └─────────────────┴─────────────────┘

分母含义:
  0 = 无协议费用
  4 = 手续费的 1/4 归协议
  10 = 手续费的 1/10 归协议
  有效范围: 0 或 4-10

协议费用分配 (以 swap 为例):
  step.feeAmount: 本步手续费
  protocolFee = step.feeAmount / feeProtocol
  step.feeAmount -= protocolFee           // LP 获得剩余部分
  protocolFees.token += protocolFee       // 协议累积
  feeGrowthGlobal += step.feeAmount * Q128 / liquidity  // LP 分配
```

### 11.3 使用场景

- **协议治理**：通过设置 `feeProtocol` 为协议金库创造收入
- **费用提取**：治理合约定期调用 `collectProtocol()` 提取累积费用

---

## 12. 回调机制详解

Uniswap V3 使用**回调模式**（callback pattern）而非 `transferFrom` 模式收取代币。这种设计允许更灵活的资金路由，但要求调用者实现对应的回调接口。

### 12.1 三种回调接口

| 回调接口 | 触发函数 | 职责 |
|---------|---------|------|
| `IUniswapV3MintCallback.uniswapV3MintCallback(amount0, amount1, data)` | `mint()` | 支付创建头寸所需的代币 |
| `IUniswapV3SwapCallback.uniswapV3SwapCallback(amount0Delta, amount1Delta, data)` | `swap()` | 支付 swap 输入代币 |
| `IUniswapV3FlashCallback.uniswapV3FlashCallback(fee0, fee1, data)` | `flash()` | 归还闪电贷本金 + 手续费 |

### 12.2 回调执行流程

```
1. 池执行操作 (mint/swap/flash)
2. 池记录当前余额
3. 池调用 msg.sender 的回调函数
4. 在回调中，调用者必须将代币转入池合约
5. 回调返回后，池验证余额是否满足要求
6. 如果不满足 → REVERT
```

### 12.3 标准实现（测试合约示例）

`TestUniswapV3Callee` 中的 swap 回调：

```
uniswapV3SwapCallback(amount0Delta, amount1Delta, data):
  ├─ 解码 data 获取 payer 地址
  ├─ 如果 amount0Delta > 0: token0.transferFrom(payer, pool, amount0Delta)
  └─ 如果 amount1Delta > 0: token1.transferFrom(payer, pool, amount1Delta)
```

---

## 13. 使用场景汇总

### 13.1 按角色分类

| 角色 | 使用的入口函数 | 典型操作 |
|------|--------------|---------|
| **终端交易者** | `swap()` (通过 Router) | 代币兑换 |
| **流动性提供者** | `mint()`, `burn()`, `collect()` | 开仓/平仓/提取收益 |
| **套利者** | `swap()`, `flash()` | 跨池套利、闪电贷套利 |
| **清算机器人** | `swap()`, `flash()` | 借贷协议清算 |
| **数据消费者** | `observe()`, `snapshotCumulativesInside()` | 读取 TWAP 价格 |
| **协议治理** | `setFeeProtocol()`, `collectProtocol()` | 管理协议收入 |
| **池创建者** | `createPool()` (Factory), `initialize()` (Pool) | 为新交易对建池 |
| **MEV 搜索者** | `swap()` | 三明治攻击、清算 |

### 13.2 按场景分类

**场景 1：新交易对上线**
```
1. Factory.createPool(tokenA, tokenB, fee) → 返回 pool 地址
2. Pool.initialize(sqrtPriceX96) → 设置初始价格
3. Pool.mint(...) → 提供初始流动性
```

**场景 2：做市商日常管理**
```
1. Pool.observe([3600, 0]) → 评估过去 1 小时的 TWAP
2. Pool.mint(...) → 在新价格范围开仓
3. Pool.burn(...) → 关闭旧头寸
4. Pool.collect(...) → 提取手续费收益
```

**场景 3：终端用户交易（通过 Router）**
```
1. Router 计算最优路径和价格限制
2. Router 调用 Pool.swap(recipient, zeroForOne, amountIn, sqrtPriceLimit, data)
3. Router 在回调中通过 transferFrom 从用户处收取输入代币
4. Router 将输出代币转给最终接收者
```

**场景 4：闪电贷套利**
```
1. 调用 Pool.flash(recipient, amount0, amount1, data)
2. 回调中:
   a. 收到借出的代币
   b. 在另一个池执行 swap 套利
   c. 归还本金 + 手续费
   d. 保留利润
```

**场景 5：DeFi 协议读取价格**
```
1. 调用 Pool.observe([3600, 0])
2. 计算: twapTick = (tickCumulatives[0] - tickCumulatives[1]) / 3600
3. 转换: twapPrice = TickMath.getSqrtRatioAtTick(twapTick)
4. 使用 twapPrice 作为清算或借贷的参考价格
```

---

## 14. 合约调用关系图

```
                    ┌─────────────────────────────┐
                    │       外部调用者              │
                    │  (用户/Router/治理/机器人)    │
                    └──────────┬──────────────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
    ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
    │ Factory      │  │ Pool         │  │ Pool         │
    │ .createPool  │  │ .initialize  │  │ .observe     │
    │ .enableFee   │  │ .mint        │  │ .snapshot    │
    │ .setOwner    │  │ .burn        │  │              │
    │              │  │ .collect     │  └──────────────┘
    │ .getPool     │  │ .swap        │         (view)
    │              │  │ .flash       │
    └──────┬───────┘  │ .setFeeProt  │
           │          │ .collectProt │
           │ deploy() │              │
           │ (int)    └──────┬───────┘
           │                 │
    ┌──────▼───────┐         │ 回调
    │ Deployer     │         │
    │ .parameters  │◄────────┤ constructor 读取
    └──────────────┘         │
                             ▼
                    ┌──────────────┐
                    │  Callback    │
                    │  实现合约     │
                    │ (Router/     │
                    │  Callee)     │
                    └──────────────┘

    ┌──────────────────────────────────────────────┐
    │              NoDelegateCall                   │
    │  被 Factory 和 Pool 继承                       │
    │  修饰器: noDelegateCall                        │
    │  保护: createPool, mint, burn, swap, flash... │
    └──────────────────────────────────────────────┘
```

### 库合约依赖关系

```
UniswapV3Pool 使用的库:
  ├── LowGasSafeMath    (uint256/int256 安全算术)
  ├── SafeCast          (类型安全转换)
  ├── TickMath          (tick ↔ sqrtPrice)
  ├── SqrtPriceMath     (价格/流动性 → 代币数量)
  ├── SwapMath          (单步 swap 计算)
  ├── Tick              (tick 状态管理)
  ├── TickBitmap        (tick 位图导航)
  ├── Position          (头寸管理 + 手续费计算)
  ├── Oracle            (TWAP 预言机)
  ├── FullMath          (512 位乘除)
  ├── FixedPoint96      (Q96 常量)
  ├── FixedPoint128     (Q128 常量)
  ├── LiquidityMath     (流动性加减)
  ├── TransferHelper    (安全代币转账)
  └── UnsafeMath        (无检查除法)
```
