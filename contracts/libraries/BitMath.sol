// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title 位运算数学库
/// @notice 提供计算无符号整数位属性的功能
/// @dev 用于 TickBitmap 库中的位图导航操作
///
/// 应用场景：
/// - 在 tick 位图中快速查找已初始化的 tick
/// - 通过位运算避免循环遍历，节省 gas
/// - 在二叉搜索中定位最高/最低有效位
///
/// 算法原理：
/// - 使用二分查找法，逐步缩小范围
/// - 对于 256 位整数，最多需要 8 次比较（log2(256) = 8）
library BitMath {
    /// @notice 返回数字中最高有效位（MSB）的索引
    /// @dev 最低有效位索引为 0，最高有效位索引为 255
    ///
    /// 算法满足的性质：
    /// - x >= 2^mostSignificantBit(x) 且 x < 2^(mostSignificantBit(x)+1)
    /// - 即：MSB 是 x 的二进制表示中最高位 1 的位置
    ///
    /// 算法原理（二分查找）：
    /// 1. 检查高 128 位是否有 1，如果有则将 x 右移 128 位，r += 128
    /// 2. 检查剩余的高 64 位是否有 1，如果有则右移 64 位，r += 64
    /// 3. 继续检查 32、16、8、4、2、1 位
    /// 4. 最终 r 就是 MSB 的索引
    ///
    /// 示例：
    /// - mostSignificantBit(0b1000) = 3（最高位在第 3 位）
    /// - mostSignificantBit(0b1101) = 3（最高位仍在第 3 位）
    /// - mostSignificantBit(0b0010) = 1（最高位在第 1 位）
    ///
    /// @param x 要计算最高有效位的值，必须大于 0
    /// @return r 最高有效位的索引
    function mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0);

        // 检查高 128 位（位 128-255）
        if (x >= 0x100000000000000000000000000000000) {
            x >>= 128;
            r += 128;
        }
        // 检查高 64 位（位 64-127 或 192-255）
        if (x >= 0x10000000000000000) {
            x >>= 64;
            r += 64;
        }
        // 检查高 32 位
        if (x >= 0x10000) {
            x >>= 32;
            r += 32;
        }
        // 检查高 16 位
        if (x >= 0x100) {
            x >>= 16;
            r += 16;
        }
        // 检查高 8 位
        if (x >= 0x10) {
            x >>= 8;
            r += 8;
        }
        // 检查高 4 位
        if (x >= 0x4) {
            x >>= 4;
            r += 4;
        }
        // 检查高 2 位
        if (x >= 0x2) r += 1;
        // 最后检查第 1 位（如果 x >= 0x2，说明第 1 位是 1）
    }

    /// @notice 返回数字中最低有效位（LSB）的索引
    /// @dev 最低有效位索引为 0，最高有效位索引为 255
    ///
    /// 算法满足的性质：
    /// - (x & 2^leastSignificantBit(x)) != 0 且 (x & (2^(leastSignificantBit(x)) - 1)) == 0
    /// - 即：LSB 是 x 的二进制表示中最低位 1 的位置
    ///
    /// 算法原理（反向二分查找）：
    /// 1. 初始化 r = 255（假设最高位）
    /// 2. 检查低 128 位是否有 1，如果有则 r -= 128，否则右移 128 位
    /// 3. 继续检查低 64、32、16、8、4、2、1 位
    /// 4. 最终 r 就是 LSB 的索引
    ///
    /// 与 MSB 的区别：
    /// - MSB 查找最高位 1，LSB 查找最低位 1
    /// - LSB 使用 & 操作检查低位，MSB 使用 >= 检查高位
    ///
    /// 示例：
    /// - leastSignificantBit(0b1000) = 3（最低位 1 在第 3 位）
    /// - leastSignificantBit(0b1010) = 1（最低位 1 在第 1 位）
    /// - leastSignificantBit(0b0001) = 0（最低位 1 在第 0 位）
    ///
    /// @param x 要计算最低有效位的值，必须大于 0
    /// @return r 最低有效位的索引
    function leastSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0);

        r = 255;
        // 检查低 128 位（位 0-127）
        if (x & type(uint128).max > 0) {
            r -= 128;
        } else {
            // 低 128 位全为 0，右移 128 位，继续检查高 128 位
            x >>= 128;
        }
        // 检查低 64 位
        if (x & type(uint64).max > 0) {
            r -= 64;
        } else {
            x >>= 64;
        }
        // 检查低 32 位
        if (x & type(uint32).max > 0) {
            r -= 32;
        } else {
            x >>= 32;
        }
        // 检查低 16 位
        if (x & type(uint16).max > 0) {
            r -= 16;
        } else {
            x >>= 16;
        }
        // 检查低 8 位
        if (x & type(uint8).max > 0) {
            r -= 8;
        } else {
            x >>= 8;
        }
        // 检查低 4 位
        if (x & 0xf > 0) {
            r -= 4;
        } else {
            x >>= 4;
        }
        // 检查低 2 位
        if (x & 0x3 > 0) {
            r -= 2;
        } else {
            x >>= 2;
        }
        // 检查第 0 位
        if (x & 0x1 > 0) r -= 1;
    }
}
