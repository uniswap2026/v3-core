# sqrtPriceX96 与 Tick 详解

> 本文档深入解释 Uniswap V3 中 `sqrtPriceX96` 和 `tick` 的数学关系、转换原理及实际应用。

## 目录

1. [sqrtPriceX96 与 price 的关系](#1-sqrtpricex96-与-price-的关系)
2. [TickMath 两个核心函数](#2-tickmath-两个核心函数)
3. [Tick 的数学定义](#3-tick-的数学定义)
4. [转换公式](#4-转换公式)
5. [Q64.96 定点数格式](#5-q6496-定点数格式)
6. [为什么使用 sqrt(price)](#6-为什么使用-sqrtprice)
7. [实际转换示例](#7-实际转换示例)
8. [实际使用场景](#8-实际使用场景)
9. [实现细节与精度](#9-实现细节与精度)
10. [速查表](#10-速查表)

---

## 1. sqrtPriceX96 与 price 的关系

### 1.1 基本定义

```
price      = token1 / token0           （token1 相对于 token0 的价格）
sqrtPrice  = √(price) = √(token1/token0)
sqrtPriceX96 = sqrtPrice × 2^96       （Q64.96 定点数格式）
```

### 1.2 关系链

```
                    人类可读          数学简化           链上存储
                    ────────          ────────           ────────
price ──sqrt──→ sqrtPrice ──×2^96──→ sqrtPriceX96
  ↑                  ↑                     ↑
token1/token0    √(token1/token0)    Q64.96 定点数

反向转换：
sqrtPriceX96 ──÷2^96──→ sqrtPrice ──平方──→ price
```

### 1.3 关键约定

| 约定 | 说明 |
|------|------|
| token0 | 地址较小的代币（按地址排序） |
| token1 | 地址较大的代币 |
| price | 始终表示 token1/token0 |
| 排序目的 | 确保同一交易对在所有地方有唯一的价格表示 |

---

## 2. TickMath 两个核心函数

`TickMath.sol` 提供了两个互逆的转换函数：

### 2.1 getSqrtRatioAtTick（tick → 价格）

```solidity
function getSqrtRatioAtTick(int24 tick) 
    internal pure returns (uint160 sqrtPriceX96)
```

**作用：** 给定 tick 索引，计算对应的 sqrtPriceX96。

```
tick ──→ sqrtPriceX96 = √(1.0001^tick) × 2^96
```

### 2.2 getTickAtSqrtRatio（价格 → tick）

```solidity
function getTickAtSqrtRatio(uint160 sqrtPriceX96) 
    internal pure returns (int24 tick)
```

**作用：** 给定 sqrtPriceX96，计算对应的最大 tick（满足 `getSqrtRatioAtTick(tick) <= sqrtPriceX96`）。

```
sqrtPriceX96 ──→ tick = ⌊2 × log₁.₀₀₀₁(sqrtPriceX96 / 2^96)⌋
```

### 2.3 互逆关系

```
getTickAtSqrtRatio(getSqrtRatioAtTick(tick)) == tick  ✓（精确）

getSqrtRatioAtTick(getTickAtSqrtRatio(sqrtPriceX96)) ≈ sqrtPriceX96
                                                          （因为 tick 是离散的）
```

---

## 3. Tick 的数学定义

### 3.1 核心公式

每个 tick 代表一个固定的价格倍数：

```
tick i 对应的价格：   price_i = 1.0001^i
tick i 对应的 sqrtPrice：  sqrtPrice_i = 1.0001^(i/2)
```

### 3.2 为什么是 1.0001？

```
1.0001 = 1 + 0.0001 = 1 + 0.01%（即 1 基点，1 bip）

含义：
- 相邻 tick 的价格相差 0.01%
- tick 10000 对应价格变化：1.0001^10000 ≈ 2.718（约 172%）
- tick 887272（最大值）对应价格：1.0001^887272 ≈ 2^128
```

### 3.3 Tick 的有效范围

| 常量 | 值 | 含义 |
|------|---|------|
| `MIN_TICK` | -887272 | 最小 tick，对应 price ≈ 2^-128 |
| `MAX_TICK` | 887272 | 最大 tick，对应 price ≈ 2^128 |
| `MIN_SQRT_RATIO` | 4295128739 | `getSqrtRatioAtTick(MIN_TICK)` 的结果 |
| `MAX_SQRT_RATIO` | 1461446703485...0342 | `getSqrtRatioAtTick(MAX_TICK)` 的结果 |

### 3.4 Tick 与 tickSpacing

实际使用中，流动性提供者只能在 `tickSpacing` 的倍数上设置头寸边界：

```
tickSpacing = 10  → 可用 tick：..., -20, -10, 0, 10, 20, ...
tickSpacing = 60  → 可用 tick：..., -120, -60, 0, 60, 120, ...
tickSpacing = 200 → 可用 tick：..., -400, -200, 0, 200, 400, ...
```

费率档位对应的默认 tickSpacing：

| fee (bip) | fee (%) | tickSpacing | 适用场景 |
|-----------|---------|-------------|---------|
| 500 | 0.05% | 10 | 稳定币对（USDC/USDT） |
| 3000 | 0.3% | 60 | 主流交易对（ETH/USDC） |
| 10000 | 1% | 200 | 高波动对（WBTC/ETH） |

---

## 4. 转换公式

### 4.1 tick → sqrtPriceX96

```
sqrtPriceX96 = √(1.0001^tick) × 2^96
             = 1.0001^(tick/2) × 2^96
```

**示例：**
```
tick = 0:
  sqrtPriceX96 = 1.0001^0 × 2^96 = 1 × 79228162514264337593543950336
               = 79228162514264337593543950336

tick = 76016（约 2000 的 price）:
  sqrtPriceX96 = 1.0001^(76016/2) × 2^96
               = 1.0001^38008 × 2^96
               ≈ 44.72 × 2^96
               ≈ 3543364280886410582194959360000
```

### 4.2 sqrtPriceX96 → tick

```
tick = ⌊2 × log₁.₀₀₀₁(sqrtPriceX96 / 2^96)⌋
```

使用换底公式：
```
log₁.₀₀₀₁(x) = log₂(x) / log₂(1.0001)

其中 log₂(1.0001) ≈ 0.00014426950408889634
```

### 4.3 价格直觉参考

| tick | price (1.0001^tick) | 直觉 |
|------|---------------------|------|
| -887272 | ≈ 2^-128 | 极端低价 |
| -230278 | ≈ 10^-10 | 极低价格 |
| -115136 | ≈ 10^-5 | 很低价 |
| -46052 | ≈ 0.01 | 低价 |
| -23026 | ≈ 0.1 | 稍低 |
| 0 | 1.0 | 1:1 价格 |
| 23026 | ≈ 10 | 稍高 |
| 46052 | ≈ 100 | 高价 |
| 76009 | ≈ 2000 | ETH ≈ 2000 USDC |
| 92103 | ≈ 10000 | 很高价 |
| 115136 | ≈ 10^5 | 极高价 |
| 230258 | ≈ 10^10 | 天文价格 |
| 887272 | ≈ 2^128 | 极端高价 |

---

## 5. Q64.96 定点数格式

### 5.1 格式说明

```
Q64.96 含义：
┌────────── 64 位整数部分 ──────────┬──────────── 96 位小数部分 ────────────┐
│         表示大小的整数              │      表示精度的小数（/2^96）          │
└───────────────────────────────────┴──────────────────────────────────────┘
                                    总计 160 位（uint160）

实际值 = 存储值 / 2^96
```

### 5.2 常量定义（FixedPoint96.sol）

```solidity
uint8   internal constant RESOLUTION = 96;
uint256 internal constant Q96 = 0x1000000000000000000000000;  // 2^96
```

### 5.3 为什么选择 Q64.96？

| 设计选择 | 原因 |
|---------|------|
| 96 位小数 | 足够精确表示极小的小数，避免舍入误差累积 |
| 64 位整数 | 足够大表示极端价格（从 10^-18 到 10^18） |
| 160 位总计 | 恰好适合 uint160，与 Ethereum 地址大小一致 |
| 2 的幂次基数 | 位移操作代替乘除法，节省 gas |

### 5.4 定点数运算

```
乘法：(a × b) / 2^96
  → (a * b) >> 96  或  FullMath.mulDiv(a, b, Q96)

除法：(a / b) × 2^96
  → (a << 96) / b  或  FullMath.mulDiv(a, Q96, b)

加法/减法：直接运算（相同的基数）
  → a + b  或  a - b
```

### 5.5 精度示例

```
price = 2000.000000000000000001

sqrtPrice ≈ 44.721359549995793928...

sqrtPriceX96 = 44.721359549995793928... × 2^96
             = 3543364280886410582194959360000...（约 39 位十进制数）

精度足够表示到小数点后约 28 位十进制数
（2^96 ≈ 7.9 × 10^28）
```

---

## 6. 为什么使用 sqrt(price)

### 6.1 核心原因：流动性计算线性化

在 Uniswap V3 的集中流动性模型中，流动性 L 定义为：

```
L = √(x × y)

其中：
- x = token0 的数量
- y = token1 的数量
```

### 6.2 使用 sqrt(price) 的公式（线性）

```
Δtoken0 = L × (1/√priceLower - 1/√priceUpper)
Δtoken1 = L × (√priceUpper - √priceLower)
```

这些公式中，token 数量与 sqrt(price) 呈**线性关系**。

### 6.3 如果直接用 price（非线性）

```
Δtoken0 = L × (1/√priceLower - 1/√priceUpper)

如果用 price 表示：
Δtoken0 = L × (√priceUpper - √priceLower) / (√priceLower × √priceUpper)
         = L × (√(priceUpper) - √(priceLower)) / √(priceLower × priceUpper)
```

公式更复杂，且涉及平方根运算。

### 6.4 几何直觉

```
         y (token1)
         │
         │    ╱  双曲线 x × y = L²
         │   ╱
         │  ╱    在 sqrt(price) 空间中，
         │ ╱     流动性区间的 token 数量
         │╱      是线性可加的
         └─────────── x (token0)
```

---

## 7. 实际转换示例

### 7.1 ETH/USDC 池（token0=USDC, token1=ETH）

```
假设：1 ETH = 2000 USDC

token0 = USDC（地址较小）
token1 = ETH（地址较大）

price = token1 / token0 = 1/2000 = 0.0005
sqrtPrice = √0.0005 ≈ 0.022360679774997896
sqrtPriceX96 = 0.022360679774997896 × 2^96
             ≈ 1771561172714253594355576581

反向验证：
price = (sqrtPriceX96 / 2^96)^2
      = (1771561172714253594355576581 / 79228162514264337593543950336)^2
      = 0.022360679...^2
      = 0.0005
```

### 7.2 USDC/ETH 池（token0=ETH, token1=USDC）

```
假设：1 ETH = 2000 USDC

token0 = ETH（假设地址较小）
token1 = USDC（假设地址较大）

price = token1 / token0 = 2000/1 = 2000
sqrtPrice = √2000 ≈ 44.721359549995793928
sqrtPriceX96 = 44.721359549995793928 × 2^96
             ≈ 3543364280886410582194959360000000

反向验证：
price = (3543364280886410582194959360000000 / 79228162514264337593543950336)^2
      = 44.721359...^2
      = 2000
```

### 7.3 稳定币池（USDC/DAI）

```
假设：1 USDC ≈ 1 DAI

price = 1.0
sqrtPrice = 1.0
sqrtPriceX96 = 1.0 × 2^96 = 79228162514264337593543950336

对应 tick = 0
```

---

## 8. 实际使用场景

### 8.1 场景 1：初始化池价格

```typescript
// 用户想设置初始价格为 2000 USDC/ETH
// 假设 token0 = USDC, token1 = ETH

const price = 0.0005;  // 1 ETH / 2000 USDC → token1/token0
const sqrtPrice = Math.sqrt(price);  // ≈ 0.02236

// 转换为 sqrtPriceX96
const Q96 = BigNumber.from(2).pow(96);
const sqrtPriceX96 = BigNumber.from(
    Math.floor(sqrtPrice * Number(Q96.toString()))
);

// 或者使用 Uniswap SDK 的 encodeSqrtRatioX96：
// sqrtPriceX96 = encodeSqrtRatioX96(1, 2000)

await pool.initialize(sqrtPriceX96);

// 池内部自动计算：
// tick = getTickAtSqrtRatio(sqrtPriceX96) ≈ -76016
```

### 8.2 场景 2：查询当前价格

```typescript
// 从 slot0 读取
const { sqrtPriceX96, tick } = await pool.slot0();

// 方法 1：通过 tick 计算（快速近似）
const price = 1.0001 ** tick;

// 方法 2：通过 sqrtPriceX96 计算（精确）
const Q96 = BigNumber.from(2).pow(96);
const sqrtPrice = sqrtPriceX96.div(Q96);  // 注意精度损失
const price = sqrtPrice.mul(sqrtPrice);

// 推荐：使用 Uniswap SDK
// const price = new Price(token0, token1, Q96, sqrtPriceX96)
```

### 8.3 场景 3：设置流动性范围

```typescript
// 做市商想在 1800-2200 USDC/ETH 范围提供流动性
// 假设 tickSpacing = 60（0.3% 费率）

const lowerPrice = 1800;
const upperPrice = 2200;

// 转换为 sqrtPriceX96
const lowerSqrt = encodeSqrtRatioX96(1, lowerPrice);
const upperSqrt = encodeSqrtRatioX96(1, upperPrice);

// 转换为 tick
let tickLower = getTickAtSqrtRatio(lowerSqrt);
let tickUpper = getTickAtSqrtRatio(upperSqrt);

// 对齐到 tickSpacing 的倍数
tickLower = Math.floor(tickLower / 60) * 60;
tickUpper = Math.ceil(tickUpper / 60) * 60;

// 创建头寸
await pool.mint(recipient, tickLower, tickUpper, liquidityAmount, data);
```

### 8.4 场景 4：swap 价格限制

```typescript
// 精确输入 swap：token0 → token1
// 设置价格保护：不接受低于 1900 的价格

const sqrtPriceLimit = encodeSqrtRatioX96(1, 1900);

await pool.swap(
    recipient,
    true,               // zeroForOne
    amountIn,           // 正数 = 精确输入
    sqrtPriceLimit,     // 价格下限保护
    callbackData
);
```

---

## 9. 实现细节与精度

### 9.1 getSqrtRatioAtTick 算法概述

```
1. 计算 |tick| 的绝对值
2. 根据 tick 的二进制位，逐位累乘预计算的 sqrt(1.0001^(2^i)) 常量
3. 如果 tick 为负数，取倒数
4. 从 Q128.128 转换到 Q64.96（右移 32 位并向上取整）
```

```solidity
// 预计算常量示例
ratio = 0xfffcb933bd6fad37aa2d162d1a594001  // sqrt(1.0001^1) × 2^128
// 后续每个常量对应 sqrt(1.0001^(2^i)) × 2^128
```

### 9.2 getTickAtSqrtRatio 算法概述

```
1. 计算 ratio 的最高有效位（MSB）→ 整数部分 log₂
2. 归一化 ratio 到 [2^127, 2^128) 范围
3. 通过平方根迭代法计算 log₂ 的小数部分（64 位精度）
4. 使用换底公式转换为 log₁.₀₀₀₁
5. 通过上下界查找处理舍入误差
```

### 9.3 精度保证

```
正向精确：
  getTickAtSqrtRatio(getSqrtRatioAtTick(tick)) == tick  ✓

反向近似（tick 是离散的，sqrtPriceX96 是连续的）：
  getSqrtRatioAtTick(getTickAtSqrtRatio(x)) ≤ x
  （返回的 sqrtPriceX96 不会超过输入值）
```

### 9.4 溢出边界

```
有效范围：
  MIN_SQRT_RATIO = 4295128739
    → tick = -887272, price ≈ 2^-128 ≈ 2.9 × 10^-39

  MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342
    → tick = 887272, price ≈ 2^128 ≈ 3.4 × 10^38
```

---

## 10. 速查表

### 10.1 转换公式汇总

| 方向 | 公式 |
|------|------|
| price → sqrtPrice | `sqrtPrice = √price` |
| sqrtPrice → price | `price = sqrtPrice²` |
| sqrtPrice → sqrtPriceX96 | `sqrtPriceX96 = sqrtPrice × 2^96` |
| sqrtPriceX96 → sqrtPrice | `sqrtPrice = sqrtPriceX96 / 2^96` |
| tick → price | `price = 1.0001^tick` |
| price → tick | `tick = log₁.₀₀₀₁(price)` |
| tick → sqrtPriceX96 | `sqrtPriceX96 = 1.0001^(tick/2) × 2^96` |
| sqrtPriceX96 → tick | `tick = 2 × log₁.₀₀₀₁(sqrtPriceX96 / 2^96)` |

### 10.2 常用常量

| 常量 | 值 | 用途 |
|------|---|------|
| `Q96` | 2^96 = 79228162514264337593543950336 | 定点数基数 |
| `RESOLUTION` | 96 | 小数位数 |
| `MIN_TICK` | -887272 | 最小 tick |
| `MAX_TICK` | 887272 | 最大 tick |
| `MIN_SQRT_RATIO` | 4295128739 | 最小 sqrtPriceX96 |
| `MAX_SQRT_RATIO` | 1461446703485...0342 | 最大 sqrtPriceX96 |

### 10.3 常见价格参考

| 价格场景 | price | sqrtPrice | sqrtPriceX96 (约) | tick (约) |
|---------|-------|-----------|-------------------|----------|
| 1:1 价格 | 1 | 1 | 7.92 × 10^28 | 0 |
| 1 ETH = 2000 USDC (t0=USDC) | 0.0005 | 0.0224 | 1.77 × 10^27 | -76016 |
| 1 ETH = 2000 USDC (t0=ETH) | 2000 | 44.72 | 3.54 × 10^33 | 76016 |
| 1 BTC = 40000 USDC (t0=USDC) | 0.000025 | 0.005 | 3.96 × 10^26 | -105966 |
| 1 BTC = 40000 USDC (t0=BTC) | 40000 | 200 | 1.58 × 10^34 | 105966 |
| 稳定币 1.0001 | 1.0001 | 1.00005 | 7.92 × 10^28 | 1 |
| 极端低价 | 2^-128 | 2^-64 | 4295128739 | -887272 |
| 极端高价 | 2^128 | 2^64 | 1.46 × 10^48 | 887272 |
