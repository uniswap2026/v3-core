// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import './LowGasSafeMath.sol';
import './SafeCast.sol';

import './TickMath.sol';
import './LiquidityMath.sol';

/// @title Tick 管理库
/// @notice 包含管理 tick 相关流程和相关计算的函数
/// @dev 用于管理 tick 的流动性、手续费累加器、预言机累加器等状态
///
/// Tick 的作用：
/// - Tick 是价格的离散化表示，每个 tick 代表一个特定的价格点
/// - 流动性提供者通过设置 tickLower 和 tickUpper 来定义流动性范围
/// - Tick 状态用于追踪流动性变化和手续费分配
///
/// 核心概念：
/// - liquidityGross：该 tick 上引用的总流动性（不考虑方向）
/// - liquidityNet：当价格穿越该 tick 时，流动性变化的净额
///   - 从左到右穿越：流动性增加 liquidityNet
///   - 从右到左穿越：流动性减少 liquidityNet
/// - feeGrowthOutside：相对于当前 tick，另一侧的手续费增长率
library Tick {
    using LowGasSafeMath for int256;
    using SafeCast for int256;

    /// @notice 每个已初始化 tick 的信息结构体
    /// @dev 存储 tick 的所有状态信息
    struct Info {
        /// @notice 引用该 tick 的总流动性（所有以该 tick 为边界的头寸的流动性之和）
        /// @dev 用于追踪该 tick 是否有流动性提供者设置过边界
        uint128 liquidityGross;
        /// @notice 当 tick 从左到右穿越时增加（或从右到左时减少）的流动性净额
        /// @dev 符号规则：
        /// - 上界 tick：liquidityNet 为负（穿越时流动性减少）
        /// - 下界 tick：liquidityNet 为正（穿越时流动性增加）
        int128 liquidityNet;
        /// @notice 该 tick 另一侧（相对于当前 tick）的 token0 手续费增长率（每单位流动性，Q128）
        /// @dev 只有相对意义，没有绝对意义 —— 值取决于 tick 何时初始化
        uint256 feeGrowthOutside0X128;
        /// @notice 该 tick 另一侧（相对于当前 tick）的 token1 手续费增长率（每单位流动性，Q128）
        uint256 feeGrowthOutside1X128;
        /// @notice 该 tick 另一侧的 tick 累加值
        /// @dev 用于预言机 TWAP 计算
        int56 tickCumulativeOutside;
        /// @notice 该 tick 另一侧的 secondsPerLiquidity 累加值（Q128）
        /// @dev 用于预言机流动性加权时间计算
        uint160 secondsPerLiquidityOutsideX128;
        /// @notice 该 tick 另一侧经过的秒数
        /// @dev 只有相对意义，值取决于 tick 何时初始化
        uint32 secondsOutside;
        /// @notice 该 tick 是否已初始化（即有流动性提供者设置过边界）
        /// @dev 等价于 liquidityGross != 0
        /// 使用 8 位存储是为了防止新初始化的 tick 被穿越时发生额外的 SSTORE
        bool initialized;
    }

    /// @notice 根据 tick 间距计算每个 tick 的最大流动性
    /// @dev 在池构造函数中执行
    ///
    /// 为什么需要限制每个 tick 的最大流动性？
    /// - 防止单个 tick 的流动性溢出
    /// - 确保 cross 函数中的 liquidityNet 计算不会溢出 int128
    /// - tick 间距越大，允许的 tick 数量越少，每个 tick 可以容纳的流动性越多
    ///
    /// 计算公式：
    /// - numTicks = (maxTick - minTick) / tickSpacing + 1
    /// - maxLiquidityPerTick = type(uint128).max / numTicks
    ///
    /// @param tickSpacing 所需的 tick 间距，以 tickSpacing 的倍数表示
    ///     例如，tickSpacing 为 3 表示 tick 必须每 3 个 tick 初始化一次，即 ..., -6, -3, 0, 3, 6, ...
    /// @return 每个 tick 的最大流动性
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128) {
        // 计算最小和最大有效 tick（对齐到 tickSpacing 的倍数）
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
        // 计算可用的 tick 数量
        uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
        // 将 uint128 的最大值平均分配给每个 tick
        return type(uint128).max / numTicks;
    }

    /// @notice 获取手续费增长数据
    /// @dev 计算头寸范围内的手续费增长率，用于惰性手续费分配
    ///
    /// 计算原理：
    /// - 全局手续费增长 = 范围内手续费增长 + 范围下手续费增长 + 范围上手续费增长
    /// - 因此：范围内手续费增长 = 全局 - 范围下 - 范围上
    /// - 范围下/上 的手续费增长通过 feeGrowthOutside 计算
    ///
    /// @param self 包含所有已初始化 tick 信息的映射
    /// @param tickLower 头寸的下界 tick
    /// @param tickUpper 头寸的上界 tick
    /// @param tickCurrent 当前 tick
    /// @param feeGrowthGlobal0X128 从开始到现在的 token0 全局手续费增长率（每单位流动性，Q128）
    /// @param feeGrowthGlobal1X128 从开始到现在的 token1 全局手续费增长率（每单位流动性，Q128）
    /// @return feeGrowthInside0X128 从头寸创建开始，tick 范围内 token0 的总手续费增长率
    /// @return feeGrowthInside1X128 从头寸创建开始，tick 范围内 token1 的总手续费增长率
    function getFeeGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        Info storage lower = self[tickLower];
        Info storage upper = self[tickUpper];

        // 计算下界 tick 以下的手续费增长
        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        if (tickCurrent >= tickLower) {
            // 当前 tick 在下界之上：下界 outside = 下界以下的手续费增长
            feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
        } else {
            // 当前 tick 在下界之下：下界以下 = 全局 - 下界 outside
            feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
        }

        // 计算上界 tick 以上的手续费增长
        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        if (tickCurrent < tickUpper) {
            // 当前 tick 在上界之下：上界 outside = 上界以上的手续费增长
            feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
        } else {
            // 当前 tick 在上界之上：上界以上 = 全局 - 上界 outside
            feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
        }

        // 范围内手续费增长 = 全局 - 范围下 - 范围上
        feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
        feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
    }

    /// @notice 更新 tick 信息，如果 tick 从未初始化变为已初始化（或反之）返回 true
    /// @dev 这是 tick 状态更新的核心函数，在 mint/burn 时调用
    ///
    /// 更新逻辑：
    /// 1. 更新 liquidityGross（总流动性）
    /// 2. 如果 liquidityGross 从 0 变为非 0，标记为已初始化，并记录当前的累加器值
    /// 3. 更新 liquidityNet（流动性净额）
    ///    - 上界 tick：liquidityNet -= liquidityDelta
    ///    - 下界 tick：liquidityNet += liquidityDelta
    ///
    /// 为什么上界/下界的 liquidityNet 更新不同？
    /// - 下界 tick：价格从左到右穿越时，流动性增加，liquidityNet 为正
    /// - 上界 tick：价格从左到右穿越时，流动性减少，liquidityNet 为负
    /// - 因此：下界 += delta，上界 -= delta
    ///
    /// @param self 包含所有 tick 信息的映射
    /// @param tick 要更新的 tick
    /// @param tickCurrent 当前 tick
    /// @param liquidityDelta 从左到右穿越时增加（或从右到左时减少）的流动性
    /// @param feeGrowthGlobal0X128 token0 的全局手续费增长率（每单位流动性，Q128）
    /// @param feeGrowthGlobal1X128 token1 的全局手续费增长率（每单位流动性，Q128）
    /// @param secondsPerLiquidityCumulativeX128 从头到现在每单位流动性的时间累加
    /// @param tickCumulative 从头到现在 tick * 时间的累加
    /// @param time 当前区块时间戳（uint32）
    /// @param upper true = 更新头寸的上界 tick，false = 更新头寸的下界 tick
    /// @param maxLiquidity 单个 tick 的最大流动性分配
    /// @return flipped tick 是否从已初始化变为未初始化，或从未初始化变为已初始化
    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time,
        bool upper,
        uint128 maxLiquidity
    ) internal returns (bool flipped) {
        Tick.Info storage info = self[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        // 计算新的总流动性
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);

        // 确保不超过该 tick 的最大流动性限制
        require(liquidityGrossAfter <= maxLiquidity, 'LO');

        // 检查是否发生翻转（从 0 到非 0，或从非 0 到 0）
        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // 该 tick 首次初始化
            // 根据惯例，假设 tick 初始化之前的所有增长都发生在 tick 下方
            // 如果 tick 小于等于当前 tick，记录当前的累加器值
            if (tick <= tickCurrent) {
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
                info.secondsPerLiquidityOutsideX128 = secondsPerLiquidityCumulativeX128;
                info.tickCumulativeOutside = tickCumulative;
                info.secondsOutside = time;
            }
            info.initialized = true;
        }

        // 更新总流动性
        info.liquidityGross = liquidityGrossAfter;

        // 当 tick 从左到右穿越时：
        // - 下界 tick：流动性增加（liquidityNet += delta）
        // - 上界 tick：流动性减少（liquidityNet -= delta）
        info.liquidityNet = upper
            ? int256(info.liquidityNet).sub(liquidityDelta).toInt128()
            : int256(info.liquidityNet).add(liquidityDelta).toInt128();
    }

    /// @notice 清除 tick 数据
    /// @param self 包含所有已初始化 tick 信息的映射
    /// @param tick 要清除的 tick
    /// @dev 使用 delete 操作符将 tick 状态重置为默认值
    /// 仅在 tick 不再有流动性引用时调用（即 burn 导致 liquidityGross 变为 0）
    function clear(mapping(int24 => Tick.Info) storage self, int24 tick) internal {
        delete self[tick];
    }

    /// @notice 根据需要转换到下一个 tick
    /// @dev 在 swap 过程中穿越 tick 时调用
    ///
    /// 穿越逻辑：
    /// 1. 更新 feeGrowthOutside：feeGrowthOutside = feeGrowthGlobal - feeGrowthOutside
    ///    - 这是因为穿越 tick 后，"另一侧"变为"这一侧"，需要翻转
    ///    - 翻转公式：newOutside = global - oldOutside
    /// 2. 类似地更新 secondsPerLiquidityOutside、tickCumulativeOutside、secondsOutside
    /// 3. 返回 liquidityNet（用于更新当前流动性）
    ///
    /// @param self 包含所有已初始化 tick 信息的映射
    /// @param tick 穿越的目标 tick
    /// @param feeGrowthGlobal0X128 token0 的全局手续费增长率（每单位流动性，Q128）
    /// @param feeGrowthGlobal1X128 token1 的全局手续费增长率（每单位流动性，Q128）
    /// @param secondsPerLiquidityCumulativeX128 当前每单位流动性的时间累加
    /// @param tickCumulative 从头到现在 tick * 时间的累加
    /// @param time 当前区块时间戳
    /// @return liquidityNet 从左到右穿越时增加（从右到左时减少）的流动性
    function cross(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time
    ) internal returns (int128 liquidityNet) {
        Tick.Info storage info = self[tick];

        // 翻转手续费增长率（从"另一侧"变为"这一侧"）
        info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
        info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
        // 翻转预言机累加器
        info.secondsPerLiquidityOutsideX128 =
            secondsPerLiquidityCumulativeX128 - info.secondsPerLiquidityOutsideX128;
        info.tickCumulativeOutside = tickCumulative - info.tickCumulativeOutside;
        info.secondsOutside = time - info.secondsOutside;

        // 返回流动性净额（用于更新当前流动性）
        liquidityNet = info.liquidityNet;
    }
}
