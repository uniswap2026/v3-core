// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.4.0;

/// @title 定点数库（96 位精度）
/// @notice 处理二进制定点数的库，参考 https://en.wikipedia.org/wiki/Q_(number_format)
/// @dev 在 SqrtPriceMath.sol 中使用，用于价格计算的精度控制
///
/// 定点数格式说明：
/// - Q96 格式表示使用 96 位小数位
/// - 实际值 = 存储值 / 2^96
/// - 这种格式可以精确表示小数，避免浮点运算的不确定性
library FixedPoint96 {
    /// @notice 定点数的小数位数（96 位）
    /// @dev 用于位移操作，将整数转换为定点数（左移 96 位）或定点数转换为整数（右移 96 位）
    uint8 internal constant RESOLUTION = 96;

    /// @notice Q96 格式的常量值（即 2^96）
    /// @dev 十六进制表示：0x1000000000000000000000000
    /// 用途：
    /// - 将整数转换为 Q96 定点数：value * Q96
    /// - 将 Q96 定点数转换为整数：value / Q96
    /// - 定点数乘法：(a * b) / Q96
    uint256 internal constant Q96 = 0x1000000000000000000000000;
}
