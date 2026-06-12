// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title 不安全的数学运算库
/// @notice 包含不检查输入输出的数学函数
/// @dev 用于已知安全场景的数学运算，不包含溢出/下溢检查，以节省 gas
///
/// 使用场景：
/// - 在调用者已经验证输入安全的情况下使用
/// - 避免冗余的检查，降低 gas 成本
/// - 调用者需要自行确保输入参数的有效性
///
/// 警告：
/// - 不检查除以 0 的情况
/// - 不检查溢出/下溢
/// - 仅在确定安全时使用
library UnsafeMath {
    /// @notice 向上取整除法：计算 ceil(x / y)
    /// @dev 除以 0 的行为未定义，必须由调用者外部检查
    ///
    /// 算法：
    /// - 使用内联汇编实现高效的向上取整除法
    /// - z = x / y + (x % y > 0 ? 1 : 0)
    /// - 如果余数大于 0，则商加 1
    ///
    /// 示例：
    /// - divRoundingUp(10, 3) = 4  (10 / 3 = 3 余 1，向上取整为 4)
    /// - divRoundingUp(10, 5) = 2  (10 / 5 = 2 余 0，无需进位)
    /// - divRoundingUp(10, 2) = 5  (10 / 2 = 5 余 0，无需进位)
    ///
    /// @param x 被除数（dividend）
    /// @param y 除数（divisor），必须大于 0
    /// @return z 商，即 ceil(x / y)
    function divRoundingUp(uint256 x, uint256 y) internal pure returns (uint256 z) {
        assembly {
            // z = x / y + (x % y > 0)
            // gt(mod(x, y), 0) 返回 1 如果余数 > 0，否则返回 0
            // div(x, y) 计算整数除法
            // add 将两者相加，实现向上取整
            z := add(div(x, y), gt(mod(x, y), 0))
        }
    }
}
