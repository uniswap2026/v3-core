// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

import './FullMath.sol';
import './FixedPoint128.sol';
import './LiquidityMath.sol';

/// @title 头寸管理库
/// @notice 头寸代表所有者在上下 tick 边界之间的流动性
/// @dev 头寸还存储额外的状态，用于追踪头寸累积的应得手续费
///
/// 核心概念：
/// - 头寸（Position）是流动性提供者在特定价格范围内的流动性
/// - 每个头寸由 owner、tickLower、tickUpper 唯一标识
/// - 头寸的手续费通过惰性计算方式分配，不需要每次交易都更新
///
/// 惰性计算原理：
/// - 不每次更新头寸的应得手续费
/// - 而是记录上次更新时的 feeGrowthInsideLastX128
/// - 当需要计算时：tokensOwed = (feeGrowthInside - feeGrowthInsideLast) * liquidity / Q128
/// - 这大大降低了 gas 成本（避免频繁的 SSTORE 操作）
library Position {
    /// @notice 头寸信息结构体
    /// @dev 每个用户头寸存储的信息
    struct Info {
        /// @notice 该头寸拥有的流动性数量
        /// @dev uint128 范围：0 到 2^128-1
        uint128 liquidity;
        /// @notice 上次更新时的 token0 手续费增长率（每单位流动性，Q128 格式）
        /// @dev 用于计算从上次更新到现在的累积手续费
        uint256 feeGrowthInside0LastX128;
        /// @notice 上次更新时的 token1 手续费增长率（每单位流动性，Q128 格式）
        uint256 feeGrowthInside1LastX128;
        /// @notice 该头寸累积的 token0 应得手续费
        /// @dev 通过 collect 函数提取，提取后清零
        uint128 tokensOwed0;
        /// @notice 该头寸累积的 token1 应得手续费
        /// @dev 通过 collect 函数提取，提取后清零
        uint128 tokensOwed1;
    }

    /// @notice 获取指定头寸的 Info 结构体
    /// @dev 使用 keccak256(owner, tickLower, tickUpper) 作为键
    /// @param self 包含所有用户头寸的映射
    /// @param owner 头寸所有者地址
    /// @param tickLower 头寸的下界 tick
    /// @param tickUpper 头寸的上界 tick
    /// @return position 指定头寸的 Info 结构体存储指针
    function get(
        mapping(bytes32 => Info) storage self,
        address owner,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (Position.Info storage position) {
        position = self[keccak256(abi.encodePacked(owner, tickLower, tickUpper))];
    }

    /// @notice 将累积的手续费记入头寸
    /// @dev 这是惰性手续费分配的核心函数
    ///
    /// 工作流程：
    /// 1. 读取当前头寸状态到内存
    /// 2. 根据 liquidityDelta 更新流动性（如果不为 0）
    /// 3. 计算从上次更新到现在的累积手续费：
    ///    tokensOwed = (feeGrowthInside - feeGrowthInsideLast) * liquidity / Q128
    /// 4. 更新 feeGrowthInsideLastX128 为当前值
    /// 5. 将计算的 tokensOwed 累加到 headOwed 中
    ///
    /// 为什么不直接更新 tokensOwed？
    /// - 避免每次都写入存储（节省 gas）
    /// - 只在 mint/burn 时更新（频率较低）
    /// - 读取时通过计算差值获得
    ///
    /// @param self 要更新的头寸
    /// @param liquidityDelta 头寸更新导致的流动性变化
    /// @param feeGrowthInside0X128 从头寸创建开始，tick 范围内 token0 的总手续费增长率
    /// @param feeGrowthInside1X128 从头寸创建开始，tick 范围内 token1 的总手续费增长率
    function update(
        Info storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal {
        Info memory _self = self;

        uint128 liquidityNext;
        if (liquidityDelta == 0) {
            // 流动性无变化：不允许对 0 流动性头寸进行 poke（只更新手续费）
            require(_self.liquidity > 0, 'NP');
            liquidityNext = _self.liquidity;
        } else {
            // 流动性有变化：计算新的流动性
            liquidityNext = LiquidityMath.addDelta(_self.liquidity, liquidityDelta);
        }

        // 计算累积的手续费
        // 公式：(feeGrowthInside - feeGrowthInsideLast) * liquidity / Q128
        // 这表示从上次更新到现在的期间内，该头寸应得的手续费
        uint128 tokensOwed0 =
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside0X128 - _self.feeGrowthInside0LastX128,
                    _self.liquidity,
                    FixedPoint128.Q128
                )
            );
        uint128 tokensOwed1 =
            uint128(
                FullMath.mulDiv(
                    feeGrowthInside1X128 - _self.feeGrowthInside1LastX128,
                    _self.liquidity,
                    FixedPoint128.Q128
                )
            );

        // 更新头寸
        if (liquidityDelta != 0) self.liquidity = liquidityNext;
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;
        // 如果有累积手续费，累加到 tokensOwed 中
        // 溢出是可接受的，头寸所有者必须在达到 type(uint128).max 之前提取手续费
        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            self.tokensOwed0 += tokensOwed0;
            self.tokensOwed1 += tokensOwed1;
        }
    }
}
