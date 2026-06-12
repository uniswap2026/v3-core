// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title 安全类型转换库
/// @notice 提供安全的类型转换方法
/// @dev 所有转换在溢出/下溢时 revert，确保类型安全
///
/// 使用场景：
/// - 将大整数类型转换为小整数类型
/// - 将有符号整数转换为无符号整数（或反之）
/// - 在需要精确控制数值范围时使用
///
/// 错误处理：
/// - 如果转换后的值无法表示原值，将 revert
/// - 不返回错误码，直接回滚交易
library SafeCast {
    /// @notice 将 uint256 安全转换为 uint160
    /// @dev 如果值超出 uint160 范围（0 到 2^160-1），将 revert
    ///
    /// 检查逻辑：
    /// - 转换后值必须等于原值
    /// - 如果原值 > 2^160-1，转换会丢失高位，导致值改变，触发 revert
    ///
    /// @param y 要转换的 uint256 值
    /// @return z 转换后的 uint160 值
    function toUint160(uint256 y) internal pure returns (uint160 z) {
        require((z = uint160(y)) == y);
    }

    /// @notice 将 int256 安全转换为 int128
    /// @dev 如果值超出 int128 范围（-2^127 到 2^127-1），将 revert
    ///
    /// 检查逻辑：
    /// - 转换后值必须等于原值
    /// - 如果原值 < -2^127 或 > 2^127-1，转换会丢失高位或符号位，触发 revert
    ///
    /// @param y 要转换的 int256 值
    /// @return z 转换后的 int128 值
    function toInt128(int256 y) internal pure returns (int128 z) {
        require((z = int128(y)) == y);
    }

    /// @notice 将 uint256 安全转换为 int256
    /// @dev 如果值超出 int256 正数范围（0 到 2^255-1），将 revert
    ///
    /// 检查逻辑：
    /// - uint256 始终为非负数
    /// - int256 的正数范围为 0 到 2^255-1
    /// - 如果原值 >= 2^255，转换后会变为负数（符号位被置 1），触发 revert
    ///
    /// 注意：
    /// - 此函数不处理负数情况（uint256 本身不能为负）
    /// - 仅确保转换后不会因符号位导致值改变
    ///
    /// @param y 要转换的 uint256 值
    /// @return z 转换后的 int256 值
    function toInt256(uint256 y) internal pure returns (int256 z) {
        require(y < 2**255);
        z = int256(y);
    }
}
