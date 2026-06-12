// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0 <0.8.0;

/// @title 预言机库
/// @notice 提供对各种系统设计有用的价格和流动性数据
/// @dev 存储的预言机数据实例（"观察点"）收集在预言机数组中
///
/// 预言机概述：
/// - 每个池在初始化时预言机数组长度为 1
/// - 任何人都可以支付 SSTORE gas 来增加数组的最大长度
/// - 当数组已满时，新的观察点会覆盖旧的观察点（环形缓冲区）
/// - 通过传递 0 给 observe() 可以获取最新的观察点
///
/// 核心概念：
/// - tickCumulative：tick * 时间 的累加值，用于计算 TWAP（时间加权平均价格）
/// - secondsPerLiquidityCumulative：时间 / 流动性 的累加值，用于计算流动性加权时间
/// - 两者结合可以构建精确的链上价格预言机
///
/// 数据结构：
/// - 使用固定大小数组 Observation[65535] 作为环形缓冲区
/// - cardinality：当前已填充的元素数量
/// - cardinalityNext：下一次扩容的目标容量
/// - index：最近写入的观察点索引
///
/// TWAP 计算原理：
/// - TWAP = (tickCumulative[t2] - tickCumulative[t1]) / (t2 - t1)
/// - 通过累加器差值除以时间差得到平均 tick
/// - 再将平均 tick 转换为平均价格
library Oracle {
    /// @notice 观察点结构体
    /// @dev 每个观察点存储特定时间戳的累加器值
    struct Observation {
        /// @notice 观察点的区块时间戳
        /// @dev 使用 uint32 足够存储到 2106 年，且节省存储
        uint32 blockTimestamp;
        /// @notice tick 累加器，即自池初始化以来的 tick * 经过时间
        /// @dev 用于计算 TWAP：
        /// - twap = (tickCumulative2 - tickCumulative1) / deltaTime
        /// - 使用 int56 可以存储约 2^55 秒的累加值（约 10^9 年）
        int56 tickCumulative;
        /// @notice 每单位流动性的秒数累加器，即自池初始化以来的秒数 / max(1, liquidity)
        /// @dev Q128 格式，用于计算流动性加权时间：
        /// - 高流动性时累加慢，低流动性时累加快
        /// - 可用于衡量流动性提供者的贡献
        uint160 secondsPerLiquidityCumulativeX128;
        /// @notice 该观察点是否已初始化
        /// @dev 用于区分已写入和未写入的观察点槽
        bool initialized;
    }

    /// @notice 将上一个观察点转换为新观察点，给定时间流逝和当前的 tick 和流动性
    /// @dev blockTimestamp 必须按时间顺序大于或等于 last.blockTimestamp，安全处理 0 或 1 次溢出
    ///
    /// 转换逻辑：
    /// 1. 计算时间差：delta = blockTimestamp - last.blockTimestamp
    /// 2. 更新 tick 累加器：tickCumulative += tick * delta
    /// 3. 更新 secondsPerLiquidity 累加器：
    ///    secondsPerLiquidity += delta / max(1, liquidity)
    /// 4. 标记为已初始化
    ///
    /// 溢出处理：
    /// - blockTimestamp 使用 uint32，每约 136 年溢出一次
    /// - 减法运算安全处理溢出（只要时间差 < 2^32 秒 ≈ 136 年）
    ///
    /// @param last 要转换的指定观察点
    /// @param blockTimestamp 新观察点的时间戳
    /// @param tick 新观察点时的活动 tick
    /// @param liquidity 新观察点时的范围内总流动性
    /// @return 新填充的观察点
    function transform(
        Observation memory last,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity
    ) private pure returns (Observation memory) {
        // 计算时间差（安全处理 uint32 溢出）
        uint32 delta = blockTimestamp - last.blockTimestamp;
        return
            Observation({
                blockTimestamp: blockTimestamp,
                // tick 累加：当前 tick * 时间差
                tickCumulative: last.tickCumulative + int56(tick) * delta,
                // secondsPerLiquidity 累加：时间差 / 流动性（Q128 格式）
                // 如果流动性为 0，使用 1 避免除零错误
                secondsPerLiquidityCumulativeX128: last.secondsPerLiquidityCumulativeX128 +
                    ((uint160(delta) << 128) / (liquidity > 0 ? liquidity : 1)),
                initialized: true
            });
    }

    /// @notice 初始化预言机数组，写入第一个槽
    /// @dev 在观察数组的生命周期中只调用一次（池的 initialize 函数中）
    ///
    /// 初始化逻辑：
    /// - 在索引 0 处写入初始观察点
    /// - tickCumulative 和 secondsPerLiquidity 都从 0 开始
    /// - cardinality 和 cardinalityNext 都设为 1
    ///
    /// @param self 存储的预言机数组
    /// @param time 预言机初始化时间（通过 block.timestamp 截断为 uint32）
    /// @return cardinality 预言机数组中已填充的元素数量
    /// @return cardinalityNext 预言机数组的新长度，与填充状态无关
    function initialize(Observation[65535] storage self, uint32 time)
        internal
        returns (uint16 cardinality, uint16 cardinalityNext)
    {
        self[0] = Observation({
            blockTimestamp: time,
            tickCumulative: 0,
            secondsPerLiquidityCumulativeX128: 0,
            initialized: true
        });
        return (1, 1);
    }

    /// @notice 向数组写入一个预言机观察点
    /// @dev 每个区块最多写入一次。index 表示最近写入的元素。
    /// cardinality 和 index 必须在外部追踪。
    ///
    /// 写入逻辑：
    /// 1. 如果本区块已经写入过，直接返回（幂等性）
    /// 2. 如果当前索引在数组末尾且 cardinalityNext > cardinality，则扩容
    /// 3. 计算新索引：(index + 1) % cardinality
    /// 4. 使用 transform 函数转换上一个观察点，写入新位置
    ///
    /// 扩容规则：
    /// - 只有当 index == cardinality - 1 且 cardinalityNext > cardinality 时才能扩容
    /// - 这个限制是为了保持顺序（防止覆盖未初始化的槽）
    ///
    /// @param self 存储的预言机数组
    /// @param index 最近写入观察点的索引
    /// @param blockTimestamp 新观察点的时间戳
    /// @param tick 新观察点时的活动 tick
    /// @param liquidity 新观察点时的范围内总流动性
    /// @param cardinality 预言机数组中已填充的元素数量
    /// @param cardinalityNext 预言机数组的目标长度
    /// @return indexUpdated 最近写入元素的新索引
    /// @return cardinalityUpdated 预言机数组的新容量
    function write(
        Observation[65535] storage self,
        uint16 index,
        uint32 blockTimestamp,
        int24 tick,
        uint128 liquidity,
        uint16 cardinality,
        uint16 cardinalityNext
    ) internal returns (uint16 indexUpdated, uint16 cardinalityUpdated) {
        Observation memory last = self[index];

        // 如果本区块已经写入过观察点，直接返回（幂等性）
        if (last.blockTimestamp == blockTimestamp) return (index, cardinality);

        // 如果条件满足，可以增加容量
        // 条件：目标容量 > 当前容量 且 当前索引在数组末尾
        if (cardinalityNext > cardinality && index == (cardinality - 1)) {
            cardinalityUpdated = cardinalityNext;
        } else {
            cardinalityUpdated = cardinality;
        }

        // 计算新索引（环形缓冲区）
        indexUpdated = (index + 1) % cardinalityUpdated;
        // 转换上一个观察点并写入新位置
        self[indexUpdated] = transform(last, blockTimestamp, tick, liquidity);
    }

    /// @notice 准备预言机数组以存储最多 `next` 个观察点
    /// @dev 通过预写入 blockTimestamp 来避免 swap 过程中的冷 SSTORE
    ///
    /// 扩容策略：
    /// - 不是真正初始化观察点（initialized 仍为 false）
    /// - 而是将 blockTimestamp 设为 1，触发 SSTORE 分配存储槽
    /// - 这样在后续写入时，存储槽已经是"温暖的"，gas 成本更低
    ///
    /// 为什么需要预分配？
    /// - 冷 SSTORE（首次写入存储槽）成本 20000 gas
    /// - 热 SSTORE（修改已有存储槽）成本 5000 gas
    /// - 通过预分配，将冷 SSTORE 成本分散到多次 grow 调用中
    ///
    /// @param self 存储的预言机数组
    /// @param current 当前预言机数组的目标容量
    /// @param next 提议的下一个目标容量
    /// @return next 将在预言机数组中填充的下一个容量
    function grow(
        Observation[65535] storage self,
        uint16 current,
        uint16 next
    ) internal returns (uint16) {
        require(current > 0, 'I');
        // 如果传入的 next 不大于当前值，不做任何操作
        if (next <= current) return current;
        // 在每个槽中存储 blockTimestamp = 1，防止 swap 中的冷 SSTORE
        // 这些数据不会被使用，因为 initialized 布尔值仍为 false
        for (uint16 i = current; i < next; i++) self[i].blockTimestamp = 1;
        return next;
    }

    /// @notice 32 位时间戳的比较器
    /// @dev 安全处理 0 或 1 次溢出，a 和 b 必须按时间顺序在 time 之前或等于 time
    ///
    /// 溢出处理逻辑：
    /// - 如果 a 和 b 都没有溢出（都 <= time），直接比较
    /// - 如果发生溢出，调整时间戳：大于 time 的值加上 2^32
    /// - 这样可以在时间戳溢出的情况下正确比较先后顺序
    ///
    /// @param time 截断为 32 位的时间戳
    /// @param a 用于确定 `time` 相对位置的比较时间戳
    /// @param b 用于确定 `time` 相对位置的比较时间戳
    /// @return bool `a` 是否在时间顺序上 <= `b`
    function lte(
        uint32 time,
        uint32 a,
        uint32 b
    ) private pure returns (bool) {
        // 如果没有发生溢出，直接比较
        if (a <= time && b <= time) return a <= b;

        // 处理溢出情况：将超过 time 的值加上 2^32
        uint256 aAdjusted = a > time ? a : a + 2**32;
        uint256 bAdjusted = b > time ? b : b + 2**32;

        return aAdjusted <= bAdjusted;
    }

    /// @notice 获取目标时间之前或之后（包含）的观察点，即满足 [beforeOrAt, atOrAfter]
    /// @dev 结果可能是同一个观察点，或相邻的观察点
    /// 答案必须包含在数组中，当目标位于存储的观察点边界内时使用：
    /// 比最近的观察点更旧，且比最旧的观察点更新或相同
    ///
    /// 二分搜索算法：
    /// 1. 确定搜索范围：[最老观察点, 最新观察点]
    /// 2. 循环直到找到满足条件的区间：
    ///    a. 计算中间位置
    ///    b. 如果中间位置未初始化，向右搜索
    ///    c. 检查目标是否在 [beforeOrAt, atOrAfter] 范围内
    ///    d. 如果目标 < beforeOrAt，向左搜索
    ///    e. 如果目标 > atOrAfter，向右搜索
    ///
    /// @param self 存储的预言机数组
    /// @param time 当前区块时间戳
    /// @param target 保留观察点的目标时间戳
    /// @param index 最近写入观察点的索引
    /// @param cardinality 预言机数组中已填充的元素数量
    /// @return beforeOrAt 在目标时间或之前记录的观察点
    /// @return atOrAfter 在目标时间或之后记录的观察点
    function binarySearch(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        uint16 index,
        uint16 cardinality
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        // l = 最老观察点的索引
        uint256 l = (index + 1) % cardinality;
        // r = 最新观察点的索引（考虑到环形缓冲区）
        uint256 r = l + cardinality - 1;
        uint256 i;
        while (true) {
            // 计算中间位置
            i = (l + r) / 2;

            beforeOrAt = self[i % cardinality];

            // 如果落在未初始化的 tick 上，继续向更高（更新）的方向搜索
            if (!beforeOrAt.initialized) {
                l = i + 1;
                continue;
            }

            atOrAfter = self[(i + 1) % cardinality];

            // 检查 beforeOrAt 的时间戳是否 <= target
            bool targetAtOrAfter = lte(time, beforeOrAt.blockTimestamp, target);

            // 检查是否找到了答案：beforeOrAt <= target <= atOrAfter
            if (targetAtOrAfter && lte(time, target, atOrAfter.blockTimestamp)) break;

            // 否则调整搜索范围
            if (!targetAtOrAfter) r = i - 1;
            else l = i + 1;
        }
    }

    /// @notice 获取给定目标之前和之后的观察点，即满足 [beforeOrAt, atOrAfter]
    /// @dev 假设至少有 1 个已初始化的观察点
    /// 被 observeSingle() 用于计算给定区块时间戳的反事实累加器值
    ///
    /// 查找策略：
    /// 1. 乐观地将 beforeOrAt 设为最新观察点
    /// 2. 如果目标在最新观察点之后或同时：
    ///    - 如果时间戳完全匹配，直接返回
    ///    - 否则使用 transform 模拟到目标时间的观察点
    /// 3. 如果目标早于最新观察点，将 beforeOrAt 设为最老观察点
    /// 4. 确保目标不早于最老观察点（否则 revert 'OLD'）
    /// 5. 如果到达这里，使用二分搜索查找
    ///
    /// @param self 存储的预言机数组
    /// @param time 当前区块时间戳
    /// @param target 保留观察点的目标时间戳
    /// @param tick 返回或模拟观察点时的活动 tick
    /// @param index 最近写入观察点的索引
    /// @param liquidity 调用时的总池流动性
    /// @param cardinality 预言机数组中已填充的元素数量
    /// @return beforeOrAt 在给定时间戳或之前发生的观察点
    /// @return atOrAfter 在给定时间戳或之后发生的观察点
    function getSurroundingObservations(
        Observation[65535] storage self,
        uint32 time,
        uint32 target,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) private view returns (Observation memory beforeOrAt, Observation memory atOrAfter) {
        // 乐观地将 before 设为最新观察点
        beforeOrAt = self[index];

        // 如果目标在时间上 >= 最新观察点，可以提前返回
        if (lte(time, beforeOrAt.blockTimestamp, target)) {
            if (beforeOrAt.blockTimestamp == target) {
                // 如果最新观察点等于目标，说明在同一区块中，可以忽略 atOrAfter
                return (beforeOrAt, atOrAfter);
            } else {
                // 否则需要使用 transform 模拟到目标时间
                return (beforeOrAt, transform(beforeOrAt, target, tick, liquidity));
            }
        }

        // 现在将 before 设为最老观察点
        beforeOrAt = self[(index + 1) % cardinality];
        if (!beforeOrAt.initialized) beforeOrAt = self[0];

        // 确保目标在时间上 >= 最老观察点
        require(lte(time, beforeOrAt.blockTimestamp, target), 'OLD');

        // 到达这里说明目标在数组范围内，使用二分搜索
        return binarySearch(self, time, target, index, cardinality);
    }

    /// @notice 获取指定时间前的累加器值
    /// @dev 如果在期望的观察时间戳处或之前不存在观察点，将 revert
    /// 可以传递 0 作为 `secondsAgo` 来返回当前累加值
    /// 如果调用时的时间戳落在两个观察点之间，返回两个观察点之间精确时间戳的反事实累加器值
    ///
    /// 插值算法：
    /// - 如果目标时间正好匹配某个观察点，直接返回
    /// - 如果目标在两个观察点之间，使用线性插值：
    ///   value = before + (after - before) * (target - beforeTime) / (afterTime - beforeTime)
    /// - 这确保了即使在观察点之间也能获得准确的历史数据
    ///
    /// @param self 存储的预言机数组
    /// @param time 当前区块时间戳
    /// @param secondsAgo 回溯的秒数，返回该时间点的观察结果
    /// @param tick 当前 tick
    /// @param index 最近写入观察点的索引
    /// @param liquidity 当前范围内池流动性
    /// @param cardinality 预言机数组中已填充的元素数量
    /// @return tickCumulative 自池初始化以来的 tick * 经过时间，截至 `secondsAgo`
    /// @return secondsPerLiquidityCumulativeX128 自池初始化以来的经过时间 / max(1, liquidity)，截至 `secondsAgo`
    function observeSingle(
        Observation[65535] storage self,
        uint32 time,
        uint32 secondsAgo,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) internal view returns (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) {
        // 如果 secondsAgo == 0，返回最新的累加值
        if (secondsAgo == 0) {
            Observation memory last = self[index];
            // 如果最后观察点的时间戳不是当前时间，使用 transform 模拟到当前时间
            if (last.blockTimestamp != time) last = transform(last, time, tick, liquidity);
            return (last.tickCumulative, last.secondsPerLiquidityCumulativeX128);
        }

        // 计算目标时间戳
        uint32 target = time - secondsAgo;

        // 获取目标时间前后的观察点
        (Observation memory beforeOrAt, Observation memory atOrAfter) =
            getSurroundingObservations(self, time, target, tick, index, liquidity, cardinality);

        if (target == beforeOrAt.blockTimestamp) {
            // 目标正好在左边界
            return (beforeOrAt.tickCumulative, beforeOrAt.secondsPerLiquidityCumulativeX128);
        } else if (target == atOrAfter.blockTimestamp) {
            // 目标正好在右边界
            return (atOrAfter.tickCumulative, atOrAfter.secondsPerLiquidityCumulativeX128);
        } else {
            // 目标在两个观察点之间，使用线性插值
            uint32 observationTimeDelta = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
            uint32 targetDelta = target - beforeOrAt.blockTimestamp;
            return (
                // tickCumulative 插值
                beforeOrAt.tickCumulative +
                    ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative) / observationTimeDelta) *
                    targetDelta,
                // secondsPerLiquidityCumulative 插值
                beforeOrAt.secondsPerLiquidityCumulativeX128 +
                    uint160(
                        (uint256(
                            atOrAfter.secondsPerLiquidityCumulativeX128 - beforeOrAt.secondsPerLiquidityCumulativeX128
                        ) * targetDelta) / observationTimeDelta
                    )
            );
        }
    }

    /// @notice 返回 `secondsAgos` 数组中每个时间点的累加器值
    /// @dev 如果 `secondsAgos` > 最老观察点将 revert
    ///
    /// 批量查询：
    /// - 对 secondsAgos 数组中的每个元素调用 observeSingle
    /// - 返回对应的 tickCumulatives 和 secondsPerLiquidityCumulativeX128s 数组
    /// - 用于计算多个时间窗口的 TWAP
    ///
    /// @param self 存储的预言机数组
    /// @param time 当前区块时间戳
    /// @param secondsAgos 每个回溯的秒数，返回对应时间点的观察结果
    /// @param tick 当前 tick
    /// @param index 最近写入观察点的索引
    /// @param liquidity 当前范围内池流动性
    /// @param cardinality 预言机数组中已填充的元素数量
    /// @return tickCumulatives 自池初始化以来的 tick * 经过时间，对应每个 `secondsAgo`
    /// @return secondsPerLiquidityCumulativeX128s 自池初始化以来的累积秒数 / max(1, liquidity)，对应每个 `secondsAgo`
    function observe(
        Observation[65535] storage self,
        uint32 time,
        uint32[] memory secondsAgos,
        int24 tick,
        uint16 index,
        uint128 liquidity,
        uint16 cardinality
    ) internal view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s) {
        require(cardinality > 0, 'I');

        // 初始化返回数组
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        // 对每个查询时间点调用 observeSingle
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            (tickCumulatives[i], secondsPerLiquidityCumulativeX128s[i]) = observeSingle(
                self,
                time,
                secondsAgos[i],
                tick,
                index,
                liquidity,
                cardinality
            );
        }
    }
}
