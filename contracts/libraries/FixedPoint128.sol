// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.4.0;

/// @title 定点数库（128 位精度）
/// @notice 处理二进制定点数的库，参考 https://en.wikipedia.org/wiki/Q_(number_format)
/// @dev 用于手续费增长的累加计算，提供高精度的小数运算
///
/// 定点数格式说明：
/// - Q128 格式表示使用 128 位小数位
/// - 实际值 = 存储值 / 2^128
/// - 128 位精度足以处理极小的手续费分配，避免累积误差
///
/// 应用场景：
/// - feeGrowthGlobalX128：全局手续费增长累加器
/// - feeGrowthInsideX128：头寸范围内手续费增长
/// - secondsPerLiquidityX128：每单位流动性的时间累加
library FixedPoint128 {
    /// @notice Q128 格式的常量值（即 2^128）
    /// @dev 十六进制表示：0x100000000000000000000000000000000
    /// 用途：
    /// - 将整数转换为 Q128 定点数：value * Q128
    /// - 将 Q128 定点数转换为整数：value / Q128
    /// - 定点数乘法：(a * b) / Q128
    ///
    /// 示例：
    /// - 手续费分配：feeGrowth * liquidity / Q128 = 实际手续费
    /// - 时间累加：secondsPerLiquidity * Q128 / liquidity = 实际时间
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
}
