// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0 <0.8.0;

/// @title Tick 数学库
/// @notice 计算 tick 对应的 sqrt 价格（sqrt(1.0001^tick)）以及反向计算
/// @dev 以 Q64.96 格式的定点数表示，支持 2^-128 到 2^128 之间的价格
///
/// 核心概念：
/// - Tick 是价格的离散化表示，每个 tick 代表 sqrt(1.0001) 的倍数
/// - sqrt(price) = sqrt(1.0001^tick) = 1.0001^(tick/2)
/// - 使用 Q64.96 格式存储：实际值 = 存储值 / 2^96
///
/// 为什么使用 sqrt(price) 而非 price？
/// - 在 AMM 计算中，使用 sqrt(price) 可以简化数学运算
/// - 流动性计算：amount = liquidity * (sqrt(upper) - sqrt(lower))
///
/// 价格范围：
/// - 最小 tick：-887272（对应价格 2^-128 ≈ 10^-39）
/// - 最大 tick：887272（对应价格 2^128 ≈ 10^38）
/// - 覆盖所有合理的代币价格范围
library TickMath {
    /// @notice 最小 tick 值
    /// @dev 由 log base 1.0001 of 2^-128 计算得出
    /// 这是 #getSqrtRatioAtTick 可以接受的最小输入
    int24 internal constant MIN_TICK = -887272;

    /// @notice 最大 tick 值
    /// @dev 由 log base 1.0001 of 2^128 计算得出
    /// 等于 -MIN_TICK
    int24 internal constant MAX_TICK = -MIN_TICK;

    /// @notice #getSqrtRatioAtTick 可以返回的最小值
    /// @dev 等于 getSqrtRatioAtTick(MIN_TICK)
    /// 十六进制：0x00000000000000000100010000
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;

    /// @notice #getSqrtRatioAtTick 可以返回的最大值
    /// @dev 等于 getSqrtRatioAtTick(MAX_TICK)
    /// 十六进制：0xffff000000000000000000000000
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// @notice 计算 sqrt(1.0001^tick) * 2^96
    /// @dev 如果 |tick| > max tick 将 revert
    ///
    /// 算法概述：
    /// 1. 使用二分查找思想，将 tick 的二进制表示分解为多个位的和
    /// 2. 对于每个位，预先计算 sqrt(1.0001^(2^i)) 的值
    /// 3. 根据 tick 的二进制位，将对应的预计算值相乘
    /// 4. 如果 tick 为负数，取倒数
    /// 5. 从 Q128.128 转换到 Q64.96（右移 32 位）
    ///
    /// 预计算常量说明：
    /// - 0xfffcb933bd6fad37aa2d162d1a594001 ≈ sqrt(1.0001^1) * 2^128
    /// - 0xfff97272373d413259a46990580e213a ≈ sqrt(1.0001^2) * 2^128
    /// - ... 依此类推，每个常量代表 2^i 的 sqrt ratio
    ///
    /// 为什么使用 Q128.128 中间格式？
    /// - 乘法需要足够的精度来避免舍入误差
    /// - 最终转换到 Q64.96 时，右移 32 位并向上取整
    ///
    /// @param tick 输入 tick（-887272 到 887272）
    /// @return sqrtPriceX96 Q64.96 格式的 sqrt 价格
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        // 计算 tick 的绝对值
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(MAX_TICK), 'T');

        // 根据 tick 的最低位选择初始值
        // 如果 tick 是奇数，使用 sqrt(1.0001^1)；否则使用 1.0
        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;

        // 根据 tick 的每个二进制位，累乘对应的预计算值
        // 每个位对应一个预计算的 sqrt(1.0001^(2^i)) 常量
        // 使用 >> 128 是因为中间结果使用 Q128.128 格式
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        // 如果 tick 为正数，需要取倒数
        // 使用 type(uint256).max / ratio 近似倒数
        if (tick > 0) ratio = type(uint256).max / ratio;

        // 从 Q128.128 转换到 Q128.96
        // 除以 1<<32（右移 32 位），向上取整
        // 由于 tick 输入限制，结果始终适应 160 位
        // 向上取整确保 getTickAtSqrtRatio 的一致性
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    /// @notice 计算满足 getSqrtRatioAtTick(tick) <= ratio 的最大 tick
    /// @dev 如果 sqrtPriceX96 < MIN_SQRT_RATIO 将 revert
    /// 因为 MIN_SQRT_RATIO 是 #getSqrtRatioAtTick 可以返回的最小值
    ///
    /// 算法概述：
    /// 1. 计算 ratio 的整数对数（以 2 为底）
    ///    - 使用二分查找法找到最高有效位（MSB）
    ///    - 通过内联汇编优化，每个比较使用不同的位移
    /// 2. 将 ratio 归一化到 [2^127, 2^128) 范围
    /// 3. 计算 log2(ratio) 的小数部分（64 位精度）
    ///    - 使用平方根迭代法：r = r^2 / 2^127
    ///    - 每次迭代获得 1 位小数
    /// 4. 将 log2(ratio) 转换为 log_{1.0001}(ratio)
    /// 5. 通过查找表确定最终 tick（处理舍入误差）
    ///
    /// 对数计算原理：
    /// - log2(sqrt(1.0001^tick)) = tick/2 * log2(1.0001)
    /// - tick = 2 * log2(ratio) / log2(1.0001)
    /// - log2(1.0001) ≈ 0.00014426950408889634
    /// - 1 / (2 * log2(1.0001)) ≈ 3453103856372597772579024 (128.128 格式)
    ///
    /// @param sqrtPriceX96 Q64.96 格式的 sqrt 价格
    /// @return tick 满足 ratio >= getSqrtRatioAtTick(tick) 的最大 tick
    function getTickAtSqrtRatio(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        // 第二个不等式必须是 < 因为价格永远无法达到最大 tick 处的价格
        require(sqrtPriceX96 >= MIN_SQRT_RATIO && sqrtPriceX96 < MAX_SQRT_RATIO, 'R');

        // 将 Q64.96 转换到 Q128.32 格式（左移 32 位）
        uint256 ratio = uint256(sqrtPriceX96) << 32;

        // 计算 ratio 的最高有效位（MSB）
        uint256 r = ratio;
        uint256 msb = 0;

        // 二分查找法计算 MSB
        // 从 128 位开始，逐步缩小到 1 位
        // 每次迭代将范围减半，最终得到 MSB 的位置
        assembly {
            let f := shl(7, gt(r, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(6, gt(r, 0xFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(5, gt(r, 0xFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(4, gt(r, 0xFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(3, gt(r, 0xFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(2, gt(r, 0xF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(1, gt(r, 0x3))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := gt(r, 0x1)
            msb := or(msb, f)
        }

        // 将 r 归一化到 [2^127, 2^128) 范围
        if (msb >= 128) r = ratio >> (msb - 127);
        else r = ratio << (127 - msb);

        // 计算 log2(ratio) 的整数部分（64.64 格式）
        int256 log_2 = (int256(msb) - 128) << 64;

        // 计算 log2(ratio) 的小数部分（64 位精度）
        // 使用平方根迭代法：
        // - r = r^2 / 2^127
        // - 如果 r >= 2^128，说明小数位为 1
        // - 每次迭代获得 1 位小数
        // 从 63 位到 50 位，共 14 位迭代
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(63, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(62, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(61, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(60, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(59, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(58, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(57, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(56, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(55, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(54, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(53, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(52, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(51, f))
            r := shr(f, r)
        }
        assembly {
            r := shr(127, mul(r, r))
            let f := shr(128, r)
            log_2 := or(log_2, shl(50, f))
        }

        // 将 log2(ratio) 转换为 log_{1.0001}(ratio)
        // 常量 255738958999603826347141 ≈ 1 / (2 * log2(sqrt(1.0001))) （128.128 格式）
        int256 log_sqrt10001 = log_2 * 255738958999603826347141;

        // 计算 tick 的上下界
        // 常量用于修正计算中的偏移
        int24 tickLow = int24(
            (log_sqrt10001 - 3402992956809132418596140100660247210) >> 128
        );
        int24 tickHi = int24(
            (log_sqrt10001 + 291339464771989622907027621153398088495) >> 128
        );

        // 通过比较确定最终 tick
        // 如果上下界相同，直接返回
        // 否则检查 tickHi 对应的价格，如果小于等于输入价格，返回 tickHi
        // 否则返回 tickLow
        tick = tickLow == tickHi ? tickLow : getSqrtRatioAtTick(tickHi) <= sqrtPriceX96 ? tickHi : tickLow;
    }
}
