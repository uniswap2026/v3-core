// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import './LowGasSafeMath.sol';
import './SafeCast.sol';

import './FullMath.sol';
import './UnsafeMath.sol';
import './FixedPoint96.sol';

/// @title 基于 Q64.96 sqrt 价格和流动性的数学函数库
/// @notice 包含使用 sqrt(price)（Q64.96 格式）和流动性计算 delta 的数学函数
/// @dev 用于计算在两个价格之间需要的代币数量，以及计算给定代币数量后的新价格
///
/// 核心公式：
/// - token0 数量：liquidity * (1/sqrt(lower) - 1/sqrt(upper))
///   = liquidity * (sqrt(upper) - sqrt(lower)) / (sqrt(upper) * sqrt(lower))
/// - token1 数量：liquidity * (sqrt(upper) - sqrt(lower))
///
/// 为什么使用 sqrt(price) 格式？
/// - 在集中流动性 AMM 中，流动性只在特定价格范围内有效
/// - 使用 sqrt(price) 可以线性化流动性计算
/// - Q64.96 格式：64 位整数 + 96 位小数，足够精确
library SqrtPriceMath {
    using LowGasSafeMath for uint256;
    using SafeCast for uint256;

    /// @notice 根据 token0 的变化量计算下一个 sqrt 价格
    /// @dev 始终向上取整（rounding up）
    ///
    /// 向上取整的原因：
    /// - 精确输出场景（价格上升）：需要移动足够的价格以获得期望的输出
    /// - 精确输入场景（价格下降）：需要移动较少的价格以避免输出过多
    ///
    /// 公式：
    /// - liquidity * sqrtPX96 / (liquidity ± amount * sqrtPX96)
    /// - 如果因溢出无法使用上述公式，则计算：liquidity / (liquidity / sqrtPX96 ± amount)
    ///
    /// @param sqrtPX96 起始价格（未考虑 token0 变化前）
    /// @param liquidity 可用流动性
    /// @param amount 要添加或移除的 token0 数量
    /// @param add true = 添加 token0（价格下降），false = 移除 token0（价格上升）
    /// @return 添加或移除 amount 后的新价格
    function getNextSqrtPriceFromAmount0RoundingUp(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amount,
        bool add
    ) internal pure returns (uint160) {
        // amount 为 0 时直接返回，否则结果无法保证等于输入价格
        if (amount == 0) return sqrtPX96;

        // 分子 = liquidity * 2^96（转换为 Q96 格式）
        uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;

        if (add) {
            // 添加 token0 的情况
            uint256 product;
            // 检查 product = amount * sqrtPX96 是否溢出
            if ((product = amount * sqrtPX96) / amount == sqrtPX96) {
                // 未溢出：使用精确公式
                uint256 denominator = numerator1 + product;
                if (denominator >= numerator1)
                    // 结果始终适合 160 位
                    return uint160(FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator));
            }

            // 溢出情况：使用简化公式
            // liquidity / (liquidity / sqrtPX96 + amount)
            return uint160(UnsafeMath.divRoundingUp(numerator1, (numerator1 / sqrtPX96).add(amount)));
        } else {
            // 移除 token0 的情况
            uint256 product;
            // 如果乘积溢出，我们知道分母会下溢
            // 同时必须检查分母不会下溢（即 numerator1 > product）
            require((product = amount * sqrtPX96) / amount == sqrtPX96 && numerator1 > product);
            uint256 denominator = numerator1 - product;
            return FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator).toUint160();
        }
    }

    /// @notice 根据 token1 的变化量计算下一个 sqrt 价格
    /// @dev 始终向下取整（rounding down）
    ///
    /// 向下取整的原因：
    /// - 精确输出场景（价格下降）：需要移动足够的价格以获得期望的输出
    /// - 精确输入场景（价格上升）：需要移动较少的价格以避免输出过多
    ///
    /// 公式：
    /// - sqrtPX96 ± amount / liquidity
    /// - 此公式与无损版本的误差小于 1 wei
    ///
    /// @param sqrtPX96 起始价格（未考虑 token1 变化前）
    /// @param liquidity 可用流动性
    /// @param amount 要添加或移除的 token1 数量
    /// @param add true = 添加 token1（价格上升），false = 移除 token1（价格下降）
    /// @return 添加或移除 amount 后的新价格
    function getNextSqrtPriceFromAmount1RoundingDown(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amount,
        bool add
    ) internal pure returns (uint160) {
        if (add) {
            // 添加 token1 的情况（价格上升）
            // 向下取整需要对商向下取整
            // 对于大多数输入，避免 mulDiv 操作以节省 gas
            uint256 quotient =
                (
                    amount <= type(uint160).max
                        ? (amount << FixedPoint96.RESOLUTION) / liquidity
                        : FullMath.mulDiv(amount, FixedPoint96.Q96, liquidity)
                );

            return uint256(sqrtPX96).add(quotient).toUint160();
        } else {
            // 移除 token1 的情况（价格下降）
            // 向下取整需要对商向上取整（因为移除时是减法）
            uint256 quotient =
                (
                    amount <= type(uint160).max
                        ? UnsafeMath.divRoundingUp(amount << FixedPoint96.RESOLUTION, liquidity)
                        : FullMath.mulDivRoundingUp(amount, FixedPoint96.Q96, liquidity)
                );

            // 确保移除的 token1 不会使价格变为负数
            require(sqrtPX96 > quotient);
            // 始终适合 160 位
            return uint160(sqrtPX96 - quotient);
        }
    }

    /// @notice 根据输入量（token0 或 token1）计算下一个 sqrt 价格
    /// @dev 如果价格或流动性为 0，或下一个价格超出边界，将 revert
    /// @param sqrtPX96 起始价格（未考虑输入量前）
    /// @param liquidity 可用流动性
    /// @param amountIn 输入量（token0 或 token1）
    /// @param zeroForOne true = 输入 token0 输出 token1，false = 输入 token1 输出 token0
    /// @return sqrtQX96 添加输入量后的新价格
    function getNextSqrtPriceFromInput(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amountIn,
        bool zeroForOne
    ) internal pure returns (uint160 sqrtQX96) {
        require(sqrtPX96 > 0);
        require(liquidity > 0);

        // 向上取整确保不超过目标价格
        return
            zeroForOne
                ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountIn, true)
                : getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountIn, true);
    }

    /// @notice 根据输出量（token0 或 token1）计算下一个 sqrt 价格
    /// @dev 如果价格或流动性为 0，或下一个价格超出边界，将 revert
    /// @param sqrtPX96 起始价格（未考虑输出量前）
    /// @param liquidity 可用流动性
    /// @param amountOut 输出量（token0 或 token1）
    /// @param zeroForOne true = 输出 token1 输入 token0，false = 输出 token0 输入 token1
    /// @return sqrtQX96 移除输出量后的新价格
    function getNextSqrtPriceFromOutput(
        uint160 sqrtPX96,
        uint128 liquidity,
        uint256 amountOut,
        bool zeroForOne
    ) internal pure returns (uint160 sqrtQX96) {
        require(sqrtPX96 > 0);
        require(liquidity > 0);

        // 向下取整确保通过目标价格
        return
            zeroForOne
                ? getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountOut, false)
                : getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountOut, false);
    }

    /// @notice 计算两个价格之间的 token0 数量变化
    /// @dev 计算公式：liquidity / sqrt(lower) - liquidity / sqrt(upper)
    /// = liquidity * (sqrt(upper) - sqrt(lower)) / (sqrt(upper) * sqrt(lower))
    ///
    /// 这个公式的含义：
    /// - 在两个价格之间提供 token0 流动性
    /// - 需要的 token0 数量与流动性成正比，与价格的调和平均成反比
    ///
    /// @param sqrtRatioAX96 第一个 sqrt 价格
    /// @param sqrtRatioBX96 第二个 sqrt 价格
    /// @param liquidity 可用流动性
    /// @param roundUp true = 向上取整，false = 向下取整
    /// @return amount0 覆盖两个价格之间流动性为 liquidity 的头寸所需的 token0 数量
    function getAmount0Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount0) {
        // 确保 sqrtRatioAX96 < sqrtRatioBX96（即 lower < upper）
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;  // liquidity * 2^96
        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;  // sqrt(upper) - sqrt(lower)

        require(sqrtRatioAX96 > 0);  // 确保价格不为 0

        // 根据 roundUp 参数选择取整方向
        return
            roundUp
                ? UnsafeMath.divRoundingUp(
                    FullMath.mulDivRoundingUp(numerator1, numerator2, sqrtRatioBX96),
                    sqrtRatioAX96
                )
                : FullMath.mulDiv(numerator1, numerator2, sqrtRatioBX96) / sqrtRatioAX96;
    }

    /// @notice 计算两个价格之间的 token1 数量变化
    /// @dev 计算公式：liquidity * (sqrt(upper) - sqrt(lower))
    ///
    /// 这个公式的含义：
    /// - 在两个价格之间提供 token1 流动性
    /// - 需要的 token1 数量与流动性和价格差成正比
    ///
    /// 与 token0 的区别：
    /// - token1 的计算更简单（线性关系，而非调和关系）
    /// - 因为 token1 是 y 轴（纵轴），token0 是 x 轴（横轴）
    ///
    /// @param sqrtRatioAX96 第一个 sqrt 价格
    /// @param sqrtRatioBX96 第二个 sqrt 价格
    /// @param liquidity 可用流动性
    /// @param roundUp true = 向上取整，false = 向下取整
    /// @return amount1 覆盖两个价格之间流动性为 liquidity 的头寸所需的 token1 数量
    function getAmount1Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity,
        bool roundUp
    ) internal pure returns (uint256 amount1) {
        // 确保 sqrtRatioAX96 < sqrtRatioBX96（即 lower < upper）
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        return
            roundUp
                ? FullMath.mulDivRoundingUp(liquidity, sqrtRatioBX96 - sqrtRatioAX96, FixedPoint96.Q96)
                : FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, FixedPoint96.Q96);
    }

    /// @notice 获取带符号的 token0 数量变化（辅助函数）
    /// @dev 根据流动性变化的正负，返回正确符号的 amount0
    ///
    /// 符号规则：
    /// - liquidityDelta > 0（增加流动性）：返回正数（需要输入 token0）
    /// - liquidityDelta < 0（减少流动性）：返回负数（需要输出 token0）
    ///
    /// 取整规则：
    /// - 增加流动性时向上取整（保护池）
    /// - 减少流动性时向下取整（保护流动性提供者）
    ///
    /// @param sqrtRatioAX96 第一个 sqrt 价格
    /// @param sqrtRatioBX96 第二个 sqrt 价格
    /// @param liquidity 流动性变化量
    /// @return amount0 对应流动性变化的 token0 数量（带符号）
    function getAmount0Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        int128 liquidity
    ) internal pure returns (int256 amount0) {
        return
            liquidity < 0
                ? -getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(-liquidity), false).toInt256()
                : getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(liquidity), true).toInt256();
    }

    /// @notice 获取带符号的 token1 数量变化（辅助函数）
    /// @dev 根据流动性变化的正负，返回正确符号的 amount1
    /// @param sqrtRatioAX96 第一个 sqrt 价格
    /// @param sqrtRatioBX96 第二个 sqrt 价格
    /// @param liquidity 流动性变化量
    /// @return amount1 对应流动性变化的 token1 数量（带符号）
    function getAmount1Delta(
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        int128 liquidity
    ) internal pure returns (int256 amount1) {
        return
            liquidity < 0
                ? -getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(-liquidity), false).toInt256()
                : getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, uint128(liquidity), true).toInt256();
    }
}
