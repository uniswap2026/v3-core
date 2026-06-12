// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import './BitMath.sol';

/// @title 打包的 tick 初始化状态库
/// @notice 存储 tick 索引到其初始化状态的打包映射
/// @dev 映射使用 int16 作为键，因为 tick 用 int24 表示，每个字（256 位）有 256（2^8）个值
///
/// 核心概念：
/// - Tick 位图是一种高效的稀疏集合数据结构
/// - 用于快速查找已初始化的 tick（有流动性提供者设置过边界的 tick）
/// - 每个位（bit）代表一个 tick 是否已初始化
///
/// 位图结构：
/// - 键：int16（word 位置）= tick >> 8（tick 除以 256）
/// - 值：uint256（256 位位图），每一位代表一个 tick
/// - 位位置：uint8（bit 位置）= tick % 256
///
/// 为什么使用位图？
/// - 节省存储：每个 tick 只占 1 位
/// - 高效查找：通过位运算快速找到下一个已初始化的 tick
/// - 支持范围查询：mask 操作可以快速筛选特定范围内的 tick
library TickBitmap {
    /// @notice 计算给定 tick 在映射中的位置
    /// @param tick 要计算位置的 tick
    /// @return wordPos 映射中包含该 tick 位的键（字位置）
    /// @return bitPos 该 tick 在字中的位位置
    /// @dev wordPos = tick >> 8（即 tick / 256），bitPos = tick % 256
    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(tick % 256);
    }

    /// @notice 翻转给定 tick 的初始化状态（从 false 到 true，或从 true 到 false）
    /// @param self 包含 tick 信息的映射
    /// @param tick 要翻转的 tick
    /// @param tickSpacing 可用 tick 之间的间距
    /// @dev 使用 XOR 操作翻转位：self[wordPos] ^= (1 << bitPos)
    /// 确保 tick 必须是 tickSpacing 的倍数（已间隔化的 tick）
    function flipTick(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing
    ) internal {
        // 确保 tick 是 tickSpacing 的倍数
        require(tick % tickSpacing == 0);
        // 计算 tick 在位图中的位置（考虑 tickSpacing）
        (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing);
        // 创建位掩码：1 左移 bitPos 位
        uint256 mask = 1 << bitPos;
        // XOR 操作翻转指定位：0->1 或 1->0
        self[wordPos] ^= mask;
    }

    /// @notice 返回给定 tick 左侧或右侧的下一个已初始化 tick
    /// @dev 在同一字（或相邻字）中搜索，最多搜索 256 个 tick
    ///
    /// 搜索原理：
    /// - 使用位掩码提取感兴趣的位
    /// - 使用 BitMath.mostSignificantBit/leastSignificantBit 找到最高/最低位 1
    /// - 这样可以快速定位到已初始化的 tick，无需遍历
    ///
    /// @param self 包含已初始化 tick 的映射
    /// @param tick 起始 tick
    /// @param tickSpacing 可用 tick 之间的间距
    /// @param lte true = 搜索左侧（小于等于起始 tick），false = 搜索右侧（大于起始 tick）
    /// @return next 距离当前 tick 最多 256 个 tick 的下一个已初始化或未初始化 tick
    /// @return initialized 下一个 tick 是否已初始化
    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        // 计算压缩后的 tick 索引（考虑 tickSpacing）
        // 向下取整：如果 tick 为负且不是 tickSpacing 的倍数，需要减 1
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;

        if (lte) {
            // 搜索左侧（小于等于当前 tick）
            // 查找已初始化的 tick（位为 1 的位置）
            (int16 wordPos, uint8 bitPos) = position(compressed);
            // 创建掩码：所有在 bitPos 及其右侧的位为 1
            // (1 << bitPos) - 1 得到 bitPos 右侧的所有位
            // + (1 << bitPos) 加上 bitPos 本身
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            // 应用掩码，获取当前字中感兴趣的位
            uint256 masked = self[wordPos] & mask;

            // 如果右侧没有已初始化的 tick，返回字中最右侧的 tick（可能未初始化）
            initialized = masked != 0;
            // 溢出/下溢是可能的，但通过限制 tickSpacing 和 tick 来防止
            next = initialized
                ? (compressed - int24(bitPos - BitMath.mostSignificantBit(masked))) * tickSpacing
                : (compressed - int24(bitPos)) * tickSpacing;
        } else {
            // 搜索右侧（大于当前 tick）
            // 从下一个 tick 的字开始，因为当前 tick 的状态不重要
            (int16 wordPos, uint8 bitPos) = position(compressed + 1);
            // 创建掩码：所有在 bitPos 及其左侧的位为 1
            // ~((1 << bitPos) - 1) 得到 bitPos 及其左侧的所有位
            uint256 mask = ~((1 << bitPos) - 1);
            // 应用掩码，获取当前字中感兴趣的位
            uint256 masked = self[wordPos] & mask;

            // 如果左侧没有已初始化的 tick，返回字中最左侧的 tick（可能未初始化）
            initialized = masked != 0;
            // 溢出/下溢是可能的，但通过限制 tickSpacing 和 tick 来防止
            next = initialized
                ? (compressed + 1 + int24(BitMath.leastSignificantBit(masked) - bitPos)) * tickSpacing
                : (compressed + 1 + int24(type(uint8).max - bitPos)) * tickSpacing;
        }
    }
}
