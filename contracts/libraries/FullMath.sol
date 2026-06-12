// SPDX-License-Identifier: MIT
pragma solidity >=0.4.0 <0.8.0;

/// @title 512 位数学运算库
/// @notice 支持中间值溢出 256 位的高精度乘除运算，不会丢失精度
/// @dev 处理"幽灵溢出"（phantom overflow）—— 允许中间值超过 256 位的乘法和除法
///
/// 核心功能：
/// - mulDiv：计算 floor(a * b / denominator)，支持 a * b 超过 2^256
/// - mulDivRoundingUp：计算 ceil(a * b / denominator)
///
/// 为什么需要 512 位运算？
/// - Uniswap V3 中，价格使用 Q64.96 格式（160 位）
/// - 手续费使用 Q128 格式（256 位）
/// - 在计算 (a * b) / denominator 时，中间结果 a * b 可能超过 2^256
/// - 本库通过内联汇编实现 512 位中间运算，避免溢出
///
/// 算法来源：
/// - 感谢 Remco Bloemen 在 https://xn--2-umb.com/21/muldiv 的 MIT 许可实现
library FullMath {
    /// @notice 计算 floor(a * b / denominator)，精度完整
    /// @dev 如果结果溢出 uint256 或 denominator == 0 将 revert
    ///
    /// 算法概述：
    /// 1. 512 位乘法：[prod1 prod0] = a * b（prod1 为高 256 位，prod0 为低 256 位）
    /// 2. 如果 prod1 == 0，说明没有溢出，直接做 256 位除法
    /// 3. 否则，使用 512/256 除法：
    ///    a. 计算余数并减去，使除法精确
    ///    b. 提取分母的 2 的幂次因子，简化除法
    ///    c. 使用牛顿-拉夫逊迭代法计算分母的模逆元
    ///    d. 通过乘法得到最终结果
    ///
    /// 牛顿-拉夫逊迭代：
    /// - 从 4 位精度的种子开始
    /// - 每次迭代将精度翻倍：4 -> 8 -> 16 -> 32 -> 64 -> 128 -> 256 位
    /// - 利用 Hensel 提升引理，在模算术中同样有效
    ///
    /// @param a 被乘数（multiplicand）
    /// @param b 乘数（multiplier）
    /// @param denominator 除数（divisor）
    /// @return result 256 位结果
    function mulDiv(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        // 512 位乘法 [prod1 prod0] = a * b
        // 计算 product mod 2^256 和 mod 2^256 - 1
        // 然后使用中国剩余定理重构 512 位结果
        // 结果存储在两个 256 位变量中：product = prod1 * 2^256 + prod0
        uint256 prod0; // 乘积的低 256 位
        uint256 prod1; // 乘积的高 256 位
        assembly {
            // mulmod 计算 (a * b) mod m，not(0) 表示 2^256 - 1
            // 这给出了 a * b 模 2^256 - 1 的结果
            let mm := mulmod(a, b, not(0))
            // mul 计算 a * b 模 2^256 的结果（低 256 位）
            prod0 := mul(a, b)
            // prod1 = (mm - prod0) - (mm < prod0)
            // 这计算了高 256 位
            prod1 := sub(sub(mm, prod0), lt(mm, prod0))
        }

        // 处理无溢出情况：256 位除法
        if (prod1 == 0) {
            require(denominator > 0);
            assembly {
                result := div(prod0, denominator)
            }
            return result;
        }

        // 确保结果小于 2^256
        // 同时也防止 denominator == 0（因为 prod1 > 0）
        require(denominator > prod1);

        ///////////////////////////////////////////////
        // 512 位除以 256 位除法
        ///////////////////////////////////////////////

        // 通过减去余数使除法精确
        // 使用 mulmod 计算余数
        uint256 remainder;
        assembly {
            remainder := mulmod(a, b, denominator)
        }
        // 从 [prod1 prod0] 中减去 256 位余数
        assembly {
            prod1 := sub(prod1, gt(remainder, prod0))
            prod0 := sub(prod0, remainder)
        }

        // 提取分母中 2 的幂次因子
        // 计算分母的最大 2 的幂次除数
        // 始终 >= 1
        // 算法：-denominator & denominator 提取最低位的 1
        uint256 twos = -denominator & denominator;
        // 将分母除以 2 的幂次
        assembly {
            denominator := div(denominator, twos)
        }

        // 将 [prod1 prod0] 也除以 2 的幂次
        assembly {
            prod0 := div(prod0, twos)
        }
        // 将 prod1 的位移入 prod0
        // 需要翻转 twos，使其等于 2^256 / twos
        // 如果 twos 为 0，则变为 1
        assembly {
            twos := add(div(sub(0, twos), twos), 1)
        }
        prod0 |= prod1 * twos;

        // 计算分母模 2^256 的逆元
        // 现在分母是奇数，所以存在模逆元
        // 满足：denominator * inv = 1 mod 2^256
        // 从 4 位精度的种子开始计算
        // 即：denominator * inv = 1 mod 2^4
        uint256 inv = (3 * denominator) ^ 2;
        // 使用牛顿-拉夫逊迭代提高精度
        // 感谢 Hensel 提升引理，在模算术中同样有效
        // 每次迭代将正确位数翻倍
        inv *= 2 - denominator * inv; // 逆元模 2^8
        inv *= 2 - denominator * inv; // 逆元模 2^16
        inv *= 2 - denominator * inv; // 逆元模 2^32
        inv *= 2 - denominator * inv; // 逆元模 2^64
        inv *= 2 - denominator * inv; // 逆元模 2^128
        inv *= 2 - denominator * inv; // 逆元模 2^256

        // 现在除法变为精确的，通过乘以模逆元得到结果
        // 这将给出模 2^256 的正确结果
        // 由于前提条件保证结果 < 2^256，这就是最终结果
        // 不需要计算结果的高位，prod1 也不再需要
        result = prod0 * inv;
        return result;
    }

    /// @notice 计算 ceil(a * b / denominator)，精度完整
    /// @dev 如果结果溢出 uint256 或 denominator == 0 将 revert
    ///
    /// 算法：
    /// 1. 先计算 floor(a * b / denominator)
    /// 2. 如果 a * b % denominator > 0（有余数），则结果加 1
    /// 3. 检查溢出：确保结果不会超过 type(uint256).max
    ///
    /// 向上取整的应用场景：
    /// - 手续费计算：保护流动性提供者，确保不丢失精度
    /// - flash 函数：确保借出方获得足够的手续费
    ///
    /// @param a 被乘数
    /// @param b 乘数
    /// @param denominator 除数
    /// @return result 256 位结果（向上取整）
    function mulDivRoundingUp(
        uint256 a,
        uint256 b,
        uint256 denominator
    ) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        // 如果有余数，向上取整
        if (mulmod(a, b, denominator) > 0) {
            require(result < type(uint256).max);
            result++;
        }
    }
}
