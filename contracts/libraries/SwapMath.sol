// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import './FullMath.sol';
import './SqrtPriceMath.sol';

/// @title 计算单个 tick 范围内的 swap 结果
/// @notice 包含计算单个 tick 价格范围内 swap 结果的方法，即单个 tick 内的计算
/// @dev 用于 swap() 函数的每一步，计算该步能交换的代币数量和手续费
///
/// 工作原理：
/// 1. 根据剩余数量和价格目标，确定是否能到达下一个 tick
/// 2. 如果能到达：价格移动到目标 tick，计算所需输入和获得输出
/// 3. 如果不能到达：价格移动到中间点，计算对应的输入输出
/// 4. 计算本步的手续费（基于实际输入量）
///
/// 关键设计：
/// - 区分精确输入（exact input）和精确输出（exact output）模式
/// - 根据方向选择 token0 或 token1 的计算公式
/// - 向上取整保护池，向下取整保护用户
library SwapMath {
    /// @notice 计算给定 swap 参数的结果
    /// @dev 如果 swap 的 `amountRemaining` 为正数，手续费加上输入量不会超过剩余量
    ///
    /// 算法流程：
    /// 1. 确定 swap 方向（zeroForOne）和模式（exactIn/exactOut）
    /// 2. 根据模式计算：
    ///    a. exactIn：计算到达目标价格需要的输入量
    ///       - 如果输入充足，价格到达目标 tick
    ///       - 如果输入不足，价格移动到中间点
    ///    b. exactOut：计算获得指定输出需要的输入量
    ///       - 如果需要输入不超过剩余量，价格到达目标 tick
    ///       - 否则价格移动到中间点
    /// 3. 根据实际到达的价格，计算实际的输入输出量
    /// 4. 计算手续费：如果达到目标价格，按实际输入计算；否则取剩余量
    ///
    /// @param sqrtRatioCurrentX96 池当前的 sqrt 价格
    /// @param sqrtRatioTargetX96 不能超过的价格（用于确定 swap 方向）
    /// @param liquidity 可用流动性
    /// @param amountRemaining 剩余需要交换的输入/输出量（正数 = 精确输入，负数 = 精确输出）
    /// @param feePips 从输入量中收取的手续费，以基点的百分之一为单位（1e-6）
    /// @return sqrtRatioNextX96 交换后的价格（不超过目标价格）
    /// @return amountIn 需要交换的输入量（token0 或 token1）
    /// @return amountOut 将获得的输出量（token0 或 token1）
    /// @return feeAmount 将作为手续费收取的输入量
    function computeSwapStep(
        uint160 sqrtRatioCurrentX96,
        uint160 sqrtRatioTargetX96,
        uint128 liquidity,
        int256 amountRemaining,
        uint24 feePips
    )
        internal
        pure
        returns (
            uint160 sqrtRatioNextX96,
            uint256 amountIn,
            uint256 amountOut,
            uint256 feeAmount
        )
    {
        // 确定方向：当前价格 >= 目标价格 = zeroForOne（token0 换 token1）
        bool zeroForOne = sqrtRatioCurrentX96 >= sqrtRatioTargetX96;
        // 确定模式：剩余量 >= 0 = 精确输入模式
        bool exactIn = amountRemaining >= 0;

        if (exactIn) {
            // 精确输入模式：amountRemaining 是要交换的输入量
            // 扣除手续费后的实际输入量
            // 1e6 - feePips 是扣除手续费后的比例（例如 feePips=3000，实际输入 = amountRemaining * 0.997）
            uint256 amountRemainingLessFee = FullMath.mulDiv(uint256(amountRemaining), 1e6 - feePips, 1e6);

            // 计算到达目标价格需要的输入量
            amountIn = zeroForOne
                ? SqrtPriceMath.getAmount0Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, true)
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, true);

            // 如果输入充足，价格可以到达目标 tick
            if (amountRemainingLessFee >= amountIn) sqrtRatioNextX96 = sqrtRatioTargetX96;
            else
                // 输入不足，价格移动到中间点
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    amountRemainingLessFee,
                    zeroForOne
                );
        } else {
            // 精确输出模式：-amountRemaining 是要获得的输出量
            // 计算获得指定输出需要的输入量
            amountOut = zeroForOne
                ? SqrtPriceMath.getAmount1Delta(sqrtRatioTargetX96, sqrtRatioCurrentX96, liquidity, false)
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioTargetX96, liquidity, false);

            // 如果需要的输入不超过剩余量，价格可以到达目标 tick
            if (uint256(-amountRemaining) >= amountOut) sqrtRatioNextX96 = sqrtRatioTargetX96;
            else
                // 需要的输入超过剩余量，价格移动到中间点
                sqrtRatioNextX96 = SqrtPriceMath.getNextSqrtPriceFromOutput(
                    sqrtRatioCurrentX96,
                    liquidity,
                    uint256(-amountRemaining),
                    zeroForOne
                );
        }

        // 是否到达了目标价格
        bool max = sqrtRatioTargetX96 == sqrtRatioNextX96;

        // 计算实际的输入/输出量
        if (zeroForOne) {
            // zeroForOne：token0 换 token1
            // amountIn：token0 的输入量
            amountIn = max && exactIn
                ? amountIn  // 如果到达目标且是精确输入，使用预先计算的值
                : SqrtPriceMath.getAmount0Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, true);
            // amountOut：token1 的输出量
            amountOut = max && !exactIn
                ? amountOut  // 如果到达目标且是精确输出，使用预先计算的值
                : SqrtPriceMath.getAmount1Delta(sqrtRatioNextX96, sqrtRatioCurrentX96, liquidity, false);
        } else {
            // oneForZero：token1 换 token0
            // amountIn：token1 的输入量
            amountIn = max && exactIn
                ? amountIn
                : SqrtPriceMath.getAmount1Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, true);
            // amountOut：token0 的输出量
            amountOut = max && !exactIn
                ? amountOut
                : SqrtPriceMath.getAmount0Delta(sqrtRatioCurrentX96, sqrtRatioNextX96, liquidity, false);
        }

        // 对于精确输出模式，限制输出量不超过剩余需求
        if (!exactIn && amountOut > uint256(-amountRemaining)) {
            amountOut = uint256(-amountRemaining);
        }

        // 计算手续费
        if (exactIn && sqrtRatioNextX96 != sqrtRatioTargetX96) {
            // 未到达目标价格：手续费 = 剩余输入量 - 实际输入量
            // 这是因为未使用的输入量作为手续费
            feeAmount = uint256(amountRemaining) - amountIn;
        } else {
            // 到达目标价格：手续费 = amountIn * feePips / (1e6 - feePips)
            // 注意：这里使用 1e6 - feePips 作为分母，因为 feePips 是基于扣除手续费后的输入
            feeAmount = FullMath.mulDivRoundingUp(amountIn, feePips, 1e6 - feePips);
        }
    }
}
