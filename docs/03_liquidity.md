# 集中流动性数学推导

> 本文档详细推导 Uniswap V3 中集中流动性的两个核心公式。

## 目录

1. [核心公式](#1-核心公式)
2. [起点：恒定乘积 AMM](#2-起点恒定乘积-amm)
3. [引入流动性 L](#3-引入流动性-l)
4. [推导 x 和 y 与 price 的关系](#4-推导-x-和-y-与-price-的关系)
5. [集中流动性的核心思想](#5-集中流动性的核心思想)
6. [推导两个公式](#6-推导两个公式)
7. [直觉理解](#7-直觉理解)
8. [对应到代码实现](#8-对应到代码实现)
9. [推导链条总结](#9-推导链条总结)
10. [实际计算示例](#10-实际计算示例)

---

## 1. 核心公式

Uniswap V3 集中流动性的两个核心公式：

```
Δtoken0 = L × (1/√priceLower - 1/√priceUpper)

Δtoken1 = L × (√priceUpper - √priceLower)
```

**含义：**
- 给定流动性 L 和价格范围 [priceLower, priceUpper]
- 计算需要提供的 token0 和 token1 数量
- 这两个公式是 `mint`、`burn`、`swap` 等所有操作的数学基础

---

## 2. 起点：恒定乘积 AMM

传统 AMM（如 Uniswap V2）的核心公式：

```
x × y = k

其中：
x = token0 的数量（池中 token0 的储备）
y = token1 的数量（池中 token1 的储备）
k = 常数（不变量）
```

**几何意义：** 这是一条双曲线，所有可能的 (x, y) 状态都在这条曲线上。

```
        y (token1)
        │
        │ ╲
        │  ╲  双曲线 x × y = k
        │   ╲
        │    ╲
        │     ╲
        │      ╲
        └──────────── x (token0)
```

---

## 3. 引入流动性 L

定义 `L = √k`，公式变为：

```
x × y = L²
```

**L 的含义：**
- L 代表流动性（Liquidity）
- L 决定了曲线的大小（离原点越远，L 越大）
- L 越大，相同的交易量引起的价格变化越小（滑点越低）

**为什么用 L 而不是 k？**
- L 与 x、y 的量纲一致（都是代币数量的平方根）
- L 使得后续公式更简洁
- L 可以直接加减（而 k 不行）

---

## 4. 推导 x 和 y 与 price 的关系

### 4.1 价格定义

```
price = y / x    （token1 相对于 token0 的价格）
```

### 4.2 联立方程

从 `x × y = L²` 和 `price = y/x` 联立求解：

**求解 x：**
```
y = price × x                （从 price = y/x 变形）
x × (price × x) = L²         （代入 x × y = L²）
x² × price = L²
x² = L² / price
x = L / √price               ← 关键公式 ①
```

**求解 y：**
```
x = y / price                （从 price = y/x 变形）
(y / price) × y = L²         （代入 x × y = L²）
y² / price = L²
y² = L² × price
y = L × √price               ← 关键公式 ②
```

### 4.3 验证

```
验证 x × y = L²：
x × y = (L / √price) × (L × √price) = L²  ✓

验证 price = y/x：
y / x = (L × √price) / (L / √price) = price  ✓
```

### 4.4 关键关系

| 变量 | 与 price 的关系 | 数学形式 |
|------|----------------|---------|
| x (token0) | 与 1/√price 成正比 | x = L / √price |
| y (token1) | 与 √price 成正比 | y = L × √price |

---

## 5. 集中流动性的核心思想

### 5.1 Uniswap V2 vs V3

**Uniswap V2：**
- 流动性分布在 [0, ∞] 的整个价格范围
- 大部分流动性永远不会被使用（资本效率低）

**Uniswap V3：**
- 流动性提供者可以选择特定价格范围 [priceLower, priceUpper]
- 流动性只在选定范围内有效（资本效率高）

### 5.2 虚拟储备（Virtual Reserves）

V3 的核心洞察：**一段集中流动性可以看作完整恒定乘积曲线的一部分**

```
        y (token1)
        │
        │ ╲  完整虚拟曲线 x × y = L²
        │  ╲
        │   ╲
        │    ┃  ← priceUpper（上界）
        │    ┃
        │    ┃  实际流动性范围
        │    ┃  (仅这段有真实代币)
        │    ┃
        │    ┃  ← priceLower（下界）
        │     ╲
        │      ╲
        └──────────── x (token0)
```

**关键点：**
- 实际代币只在 [priceLower, priceUpper] 范围内
- 但数学上，整条曲线仍然满足 `x × y = L²`
- 曲线外的部分是"虚拟储备"，不存在真实代币
- 这使得我们可以使用完整的恒定乘积公式

### 5.3 资本效率提升

**示例：** 假设 ETH 价格在 1800-2200 USDC 范围内波动

| 协议 | 流动性分布 | 资本效率 |
|------|-----------|---------|
| V2 | [0, ∞] | ~0.5%（仅当前价格附近被使用） |
| V3 | [1800, 2200] | ~100%（全部在有效范围内） |

V3 的资本效率可以提升 **200 倍** 以上。

---

## 6. 推导两个公式

### 6.1 公式 1：Δtoken0

**场景：** 价格从 priceLower 移动到 priceUpper，计算 token0 的变化量。

```
Δtoken0 = x(priceLower) - x(priceUpper)
```

**为什么是减法？**
- 当价格上升（token0 变得更贵）时，池中的 token0 减少
- 所以用低价时的 x 减去高价时的 x

**代入公式 ①：**
```
x = L / √price

Δtoken0 = L / √priceLower - L / √priceUpper
        = L × (1/√priceLower - 1/√priceUpper)    ✓
```

### 6.2 公式 2：Δtoken1

**场景：** 价格从 priceLower 移动到 priceUpper，计算 token1 的变化量。

```
Δtoken1 = y(priceUpper) - y(priceLower)
```

**为什么是加法？**
- 当价格上升（token1 变得更便宜）时，池中的 token1 增加
- 所以用高价时的 y 减去低价时的 y

**代入公式 ②：**
```
y = L × √price

Δtoken1 = L × √priceUpper - L × √priceLower
        = L × (√priceUpper - √priceLower)    ✓
```

### 6.3 符号约定

| 操作 | Δtoken0 | Δtoken1 | 含义 |
|------|---------|---------|------|
| mint (增加流动性) | 正数 | 正数 | 用户向池提供代币 |
| burn (减少流动性) | 负数 | 负数 | 池向用户返还代币 |
| swap (价格上涨) | 正数 | 负数 | 用户输入 token0，输出 token1 |
| swap (价格下跌) | 负数 | 正数 | 用户输入 token1，输出 token0 |

---

## 7. 直觉理解

### 7.1 公式对比

| 公式 | 含义 | 数学形式 | 几何意义 |
|------|------|---------|---------|
| Δtoken0 = L × (1/√pL - 1/√pU) | token0 与 1/√price 成正比 | 调和关系 | x 轴（横轴） |
| Δtoken1 = L × (√pU - √pL) | token1 与 √price 成正比 | 线性关系 | y 轴（纵轴） |

### 7.2 为什么不对称？

**根本原因：价格的定义**

```
price = y / x = token1 / token0
```

- token0 是分母 → x 与 1/price 成正比（反比关系）
- token1 是分子 → y 与 price 成正比（正比关系）

取平方根后，这个不对称性保留下来：
- x = L / √price（反比）
- y = L × √price（正比）

### 7.3 数值直觉

**示例：** L = 1000, priceLower = 1, priceUpper = 4

```
Δtoken0 = 1000 × (1/√1 - 1/√4)
        = 1000 × (1/1 - 1/2)
        = 1000 × 0.5
        = 500

Δtoken1 = 1000 × (√4 - √1)
        = 1000 × (2 - 1)
        = 1000 × 1
        = 1000
```

**验证：**
```
初始状态 (price = 1):
x = 1000 / √1 = 1000
y = 1000 × √1 = 1000
x × y = 1000000 = L²  ✓

结束状态 (price = 4):
x = 1000 / √4 = 500
y = 1000 × √4 = 2000
x × y = 1000000 = L²  ✓

变化量：
Δx = 1000 - 500 = 500  ✓
Δy = 2000 - 1000 = 1000  ✓
```

---

## 8. 对应到代码实现

### 8.1 SqrtPriceMath.sol 中的实现

**getAmount0Delta（对应公式 1）：**

```solidity
function getAmount0Delta(
    uint160 sqrtRatioAX96,  // √priceA × 2^96
    uint160 sqrtRatioBX96,  // √priceB × 2^96
    uint128 liquidity,      // L
    bool roundUp
) internal pure returns (uint256 amount0) {
    
    // 确保 sqrtRatioA < sqrtRatioB（即 priceA < priceB）
    if (sqrtRatioAX96 > sqrtRatioBX96) 
        (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

    // numerator1 = L × 2^96（转换为 Q96 格式）
    uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;
    
    // numerator2 = √priceB - √priceA
    uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;

    // 公式：L × (√pB - √pA) / (√pA × √pB)
    //      = L × (1/√pA - 1/√pB)  ← 通分化简
    
    return roundUp
        ? UnsafeMath.divRoundingUp(
            FullMath.mulDivRoundingUp(numerator1, numerator2, sqrtRatioBX96),
            sqrtRatioAX96
          )
        : FullMath.mulDiv(numerator1, numerator2, sqrtRatioBX96) / sqrtRatioAX96;
}
```

**getAmount1Delta（对应公式 2）：**

```solidity
function getAmount1Delta(
    uint160 sqrtRatioAX96,  // √priceA × 2^96
    uint160 sqrtRatioBX96,  // √priceB × 2^96
    uint128 liquidity,      // L
    bool roundUp
) internal pure returns (uint256 amount1) {
    
    if (sqrtRatioAX96 > sqrtRatioBX96) 
        (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

    // 公式：L × (√pB - √pA)
    // 直接计算，无需除法
    
    return roundUp
        ? FullMath.mulDivRoundingUp(
            liquidity, 
            sqrtRatioBX96 - sqrtRatioAX96, 
            FixedPoint96.Q96
          )
        : FullMath.mulDiv(
            liquidity, 
            sqrtRatioBX96 - sqrtRatioAX96, 
            FixedPoint96.Q96
          );
}
```

### 8.2 公式 1 的通分化简

```
原始公式：
Δtoken0 = L × (1/√pL - 1/√pU)

通分：
1/√pL - 1/√pU = (√pU - √pL) / (√pL × √pU)

所以：
Δtoken0 = L × (√pU - √pL) / (√pL × √pU)
```

**代码实现：**
```
numerator1 = L × 2^96
numerator2 = √pU - √pL（在 Q96 格式下）

中间结果 = numerator1 × numerator2 / √pU
最终结果 = 中间结果 / √pL
         = L × (√pU - √pL) / (√pL × √pU)
         = L × (1/√pL - 1/√pU)
```

### 8.3 为什么代码中要除以 Q96？

**定点数运算：**

```
sqrtPriceX96 = √price × 2^96

当计算 L × (√pU - √pL) 时：
= L × (sqrtPriceX96_U - sqrtPriceX96_L)
= L × (√pU × 2^96 - √pL × 2^96)
= L × 2^96 × (√pU - √pL)

要得到实际值，需要除以 2^96：
实际值 = L × (√pU - √pL)
       = [L × 2^96 × (√pU - √pL)] / 2^96
```

所以代码中使用 `FullMath.mulDiv(liquidity, diff, Q96)` 来除以 2^96。

---

## 9. 推导链条总结

```
恒定乘积: x × y = k
         ↓
定义流动性: L = √k
         ↓
x × y = L²
         ↓
价格定义: price = y/x
         ↓
联立求解: x = L/√price, y = L×√price
         ↓
集中流动性: 只在 [priceLower, priceUpper] 范围内有效
         ↓
计算差值:
  Δx = L(1/√pL - 1/√pU)
  Δy = L(√pU - √pL)
```

**这两个公式是 Uniswap V3 所有流动性计算的基石：**
- `mint()`：计算创建头寸需要的代币数量
- `burn()`：计算销毁头寸返还的代币数量
- `swap()`：计算交换过程中的代币变化量

---

## 10. 实际计算示例

### 10.1 场景 1：创建 ETH/USDC 流动性头寸

**参数：**
- 当前价格：1 ETH = 2000 USDC
- 价格范围：1800 - 2200 USDC
- 流动性 L = 10^18（约 1 单位的流动性）
- token0 = USDC, token1 = ETH

**计算：**

```
priceLower = 1/2200 ≈ 0.0004545
priceUpper = 1/1800 ≈ 0.0005556

√priceLower = √0.0004545 ≈ 0.02132
√priceUpper = √0.0005556 ≈ 0.02357

Δtoken0 (USDC):
= L × (1/√priceLower - 1/√priceUpper)
= 10^18 × (1/0.02132 - 1/0.02357)
= 10^18 × (46.91 - 42.43)
= 10^18 × 4.48
≈ 4.48 × 10^18 USDC（约 4480 USDC，考虑 6 位小数）

Δtoken1 (ETH):
= L × (√priceUpper - √priceLower)
= 10^18 × (0.02357 - 0.02132)
= 10^18 × 0.00225
≈ 2.25 × 10^15 ETH（约 0.00225 ETH）
```

### 10.2 场景 2：稳定币池

**参数：**
- 价格范围：0.999 - 1.001
- L = 10^18

**计算：**

```
√priceLower = √0.999 ≈ 0.9995
√priceUpper = √1.001 ≈ 1.0005

Δtoken0:
= 10^18 × (1/0.9995 - 1/1.0005)
= 10^18 × (1.0005 - 0.9995)
= 10^18 × 0.001
= 10^15

Δtoken1:
= 10^18 × (1.0005 - 0.9995)
= 10^18 × 0.001
= 10^15
```

**观察：** 在价格接近 1 的窄范围内，Δtoken0 ≈ Δtoken1，近似对称。

### 10.3 场景 3：极端价格范围

**参数：**
- 价格范围：1 - 10000
- L = 1000

**计算：**

```
√priceLower = √1 = 1
√priceUpper = √10000 = 100

Δtoken0:
= 1000 × (1/1 - 1/100)
= 1000 × (1 - 0.01)
= 1000 × 0.99
= 990

Δtoken1:
= 1000 × (100 - 1)
= 1000 × 99
= 99000
```

**观察：** 在大价格范围内，需要大量的 token1（高价代币），少量的 token0（低价代币）。

---

## 附录：关键常量

| 常量 | 值 | 用途 |
|------|---|------|
| Q96 | 2^96 ≈ 7.92 × 10^28 | 定点数基数 |
| MIN_TICK | -887272 | 最小 tick |
| MAX_TICK | 887272 | 最大 tick |
| MIN_SQRT_RATIO | 4295128739 | 最小 sqrtPriceX96 |
| MAX_SQRT_RATIO | 1.46 × 10^48 | 最大 sqrtPriceX96 |
