-- 构建身份戳（勿手改）：由 tests/prepush_check.py 在每次推送前自动重写。
-- 用途：真机与 PC 预览同屏显示，双端版本核对（PC/手机版本不一致类事故的判读依据）。
-- 权威身份是 commit（云构建取 Maker 远端 HEAD）；version 为 .project/project.json 快照。
return {
    version = "1.0.56",
    commit = "fda6251",
    commitDate = "2026-10-16",
    note = "auto-stamped by prepush_check",
}
