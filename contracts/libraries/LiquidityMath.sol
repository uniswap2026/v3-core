// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title 流动性数学库
/// @notice 提供流动性相关的安全数学运算
/// @dev 用于流动性增加/减少操作，包含溢出/下溢检查
library LiquidityMath {
    /// @notice 将带符号的流动性变化量添加到流动性中
    /// @dev 如果结果溢出 uint128 范围或下溢，将 revert
    ///
    /// 流动性变化规则：
    /// - y 为正数：增加流动性，检查结果是否溢出（z >= x）
    /// - y 为负数：减少流动性，检查结果是否下溢（z < x）
    ///
    /// 错误代码：
    /// - 'LS'：流动性下溢（减少过多）
    /// - 'LA'：流动性溢出（增加过多）
    ///
    /// @param x 变化前的流动性（uint128 范围：0 到 2^128-1）
    /// @param y 流动性变化量（int128 范围：-2^127 到 2^127-1）
    /// @return z 变化后的流动性
    function addDelta(uint128 x, int128 y) internal pure returns (uint128 z) {
        if (y < 0) {
            // y 为负数：减少流动性
            // 检查下溢：结果必须小于原值
            require((z = x - uint128(-y)) < x, 'LS');
        } else {
            // y 为正数或零：增加流动性
            // 检查溢出：结果必须大于等于原值
            require((z = x + uint128(y)) >= x, 'LA');
        }
    }
}
