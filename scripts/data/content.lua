-- Authored fixed world content. Keep this file as data only.
return {
    fixed = {
        -- 来源：既有 V25 fixed content；T01 等价迁移。
        {
            contentId = "island_01",
            entityType = "island",
            kind = "fixed",
            position = { x = 35, y = 25 },
            radius = 12,
            layer = "surface",
            blocking = true,
            actionKind = "explore",
            rewardId = "memory_island_01",
            markable = false,
        },
        -- 来源：既有 V25 fixed content；T01 等价迁移。
        {
            contentId = "island_02",
            entityType = "island",
            kind = "fixed",
            position = { x = -80, y = 90 },
            radius = 20,
            layer = "surface",
            blocking = true,
            actionKind = "explore",
            rewardId = "memory_island_02",
            markable = false,
        },
        -- 来源：既有 V25 fixed content；T01 等价迁移。
        {
            contentId = "underwater_treasure_01",
            entityType = "treasure",
            kind = "fixed",
            position = { x = 35, y = 45 },
            radius = 0.5,
            layer = "underwater",
            blocking = false,
            actionKind = "salvage",
            rewardId = "memory_treasure_01",
            markable = true,
            tuningStatus = "V25_INTEGRATION_PLAYTEST_GEOMETRY",
        },
    },
}
