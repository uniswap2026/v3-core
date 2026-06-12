// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.7.0;

/// @title 优化的溢出/下溢安全数学运算库
/// @notice 包含在溢出或下溢时回滚的数学运算方法，以最低的 gas 成本
/// @dev 使用紧凑的 require 语句实现安全检查，比 OpenZeppelin 的 SafeMath 更节省 gas
///
/// 设计哲学：
/// - 使用内联的 require 检查，避免函数调用开销
/// - 利用 Solidity 0.8+ 之前的版本，手动实现溢出检查
/// - 每个函数都保证在溢出/下溢时 revert
///
/// 与 UnsafeMath 的区别：
/// - LowGasSafeMath：包含溢出/下溢检查，安全但略费 gas
/// - UnsafeMath：无检查，仅在已知安全时使用
library LowGasSafeMath {
    /// @notice 返回 x + y，如果和溢出 uint256 则 revert
    /// @dev 检查逻辑：如果 sum < x，说明发生了溢出
    /// @param x 被加数（augend）
    /// @param y 加数（addend）
    /// @return z x 和 y 的和
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }

    /// @notice 返回 x - y，如果下溢则 revert
    /// @dev 检查逻辑：如果差 > x，说明发生了下溢（y > x）
    /// @param x 被减数（minuend）
    /// @param y 减数（subtrahend）
    /// @return z x 和 y 的差
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }

    /// @notice 返回 x * y，如果溢出则 revert
    /// @dev 检查逻辑：如果 x != 0 且 (x * y) / x != y，说明发生了溢出
    /// 特殊情况：x == 0 时，乘积一定为 0，无需检查
    /// @param x 被乘数（multiplicand）
    /// @param y 乘数（multiplier）
    /// @return z x 和 y 的乘积
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(x == 0 || (z = x * y) / x == y);
    }

    /// @notice 返回 x + y，如果溢出或下溢则 revert
    /// @dev 检查逻辑：和的符号变化必须与加数的符号一致
    /// - 如果 y >= 0，则和必须 >= x（不溢出）
    /// - 如果 y < 0，则和必须 < x（不下溢）
    /// @param x 被加数
    /// @param y 加数
    /// @return z x 和 y 的和
    function add(int256 x, int256 y) internal pure returns (int256 z) {
        require((z = x + y) >= x == (y >= 0));
    }

    /// @notice 返回 x - y，如果溢出或下溢则 revert
    /// @dev 检查逻辑：差的符号变化必须与减数的符号一致
    /// - 如果 y >= 0，则差必须 <= x（不下溢）
    /// - 如果 y < 0，则差必须 > x（不溢出，因为减去负数等于加正数）
    /// @param x 被减数
    /// @param y 减数
    /// @return z x 和 y 的差
    function sub(int256 x, int256 y) internal pure returns (int256 z) {
        require((z = x - y) <= x == (y >= 0));
    }
}
