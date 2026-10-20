# 近景海面动态效果（焦散 + DuDv）

> 2026-10-20 交付。状态：**已实施 + 远端构建通过 + 离线像素验证通过；真机观感/帧率未验证。**

## 1. 原有海面系统（实施前实测）

| 层 | 文件 | 实现方式 | 坐标 |
|---|---|---|---|
| 海面渐变兜底 | `Ocean/SeaViewArt.lua` `Surface()` | NanoVG 线性渐变 | 屏幕空间 |
| 海面底图 | `Ocean/ImageArt.lua` `SeaSurface()` | `nvgImagePattern` + 地平线 48 段裁剪，`REPEATX` | 屏幕空间材质层，`scroll=false` |
| 水彩纸纹兜底 | `ImageArt.WaterPaper()` | 同上 | 屏幕空间 |
| 波纹平铺层（当前默认关） | `ImageArt.SeaRipple()` | 双向平铺 + 相机横移 | 屏幕空间 |
| 程序浪脊 crests（当前默认开） | `SeaViewArt.lua` `drawSurfaceLayer()` | 世界网格 + `Projection` + 贝塞尔笔触 | **世界米制** |
| 船 / 岛 / 鱼 / 桶 | `ImageArt.Plane()` / `Upright()` | 世界平面分片 + `UV→屏幕` 仿射 | 世界米制 |
| 昼夜 | `Draw.ClockVisualState()` + `SeaViewArt.SeaSurfaceFrame()` | phase/progress 驱动；夜间由 `Draw.NightOverlay` 统一压暗 | — |

关键事实：

- 底图与波纹是**屏幕空间**材质层，船一动就与世界实体速率脱节（历史上多次真机反馈的根因）。
- 真正的世界投影只有两条通道：`Ocean/Projection.lua`（`Project` / `ProjectFunction` / `HorizonFunction`）与 `Ocean/ImageArt.lua` 的 `triangle()` 仿射贴图。
- 项目**没有任何 GPU Shader 接入**：`grep Shader scripts/` 为空；NanoVG 是唯一绘制通道（`Ocean/Bootstrap.lua` 里 `nvgCreate(1)` + `NanoVGRender`）。
- NanoVG 能力边界（`.emmylua/NanoVG.d.lua`）：`nvgImagePattern` 只有 `ox/oy/ex/ey/angle/image/alpha`，**没有可编程采样器**；`nvgImagePatternTinted` 只做乘法染色。渲染顺序靠 `nvgSetRenderOrder`，混合靠 `nvgGlobalCompositeOperation`。

## 2. AB vs ABC 结论

| | AB（NanoVG + 图片纹理） | ABC（新增 GPU Shader 路径） |
|---|---|---|
| 焦散滚动 | ✅ | ✅ |
| 多层焦散 | ✅（只多一遍 fill） | ✅ |
| 局部区域 + 边缘渐隐 | ✅（世界网格 + 径向 fade） | ✅ |
| 昼夜强度 | ✅ | ✅ |
| DuDv **逐像素** UV 置换 | ❌ NanoVG 无采样器 | ✅ |
| DuDv **逐顶点** UV 置换 | ✅（CPU 解码 + 逐顶点 UV） | ✅ |
| 接入成本 | 1 新模块 + 1 处调用 | 需新建 Scene + Camera + RenderTarget + SurfaceShader + `nvgCreateVideo` 回送 |
| 与现有 2.5D 架构的一致性 | 完全一致 | 需要维护第二套渲染/坐标/资源链 |
| 真机风险 | 低（同一 NanoVG 通道） | 高（多一次全屏 Texture2D + RT 往返） |

**选择 AB。** 理由：

1. 项目当前没有任何 3D/Shader 通道，ABC 不是"加一个 Shader"，而是要给 2.5D 画面新开一条渲染链路（Scene/Camera/RenderPath/RT/回送），与 `ART_PIPELINE.md` 冻结的技术路线冲突，维护成本远超收益。
2. DuDv 的核心价值（用向量场偏移采样）在 AB 里**可以真实实现**——只是分辨率是"逐顶点"而非"逐像素"，对 22~26m 尺度的低频水纹位移已经足够。
3. ABC 唯一独占的能力是全屏逐像素置换；本效果是低透明度近景叠加层，不需要这个精度。

ABC 若要做，需要的基础设施（**未实施**）：`Scene` + 正交 `Camera` 对齐现有 `Projection`、`Texture2D` RT、`Material:SetSurfaceShader`、`nvgCreateVideo` 回送、每帧一次全屏 RT 合成。建议单独立项，不与本效果捆绑。

## 3. 实现

新增 `scripts/Ocean/WaterFX.lua`（唯一新模块），在 `SeaViewArt.Surface()` 里一行调用：

```
底图/纸纹 → 波纹层(当前关) → 【WaterFX 近景焦散】 → 地平线描边 → 程序 crests
```

- **世界网格**：以相机（`Movement.camera`，已带 `followSec` 平滑跟随船）为中心的 `sizeMeters=84` 方形，切 `cellMeters=12` → 7×7=49 片；每片两个三角形，用 `Projection.ProjectFunction` 投到屏幕后做 `UV→屏幕` 仿射（与 `ImageArt.triangle` 同思路）。
- **焦散 UV**：`u = worldX / tileMeters + scrollX * time`。世界项让纹样钉在世界平面（船动不跟着漂），时间项独立叠加（船动**不**重置动画）。
- **边缘渐隐**：`EdgeFade` 径向 smoothstep（feather=0.52）+ 按片哈希降权，无矩形边界、无同心色阶。
- **昼夜**：`WaterFX.DayFactor(clock, settings)`：day 相 `0.55 + 0.45·sin(π·progress)`（正午最强），night 相压到 `nightScale=0.28`。复用现有 clock，不新增时钟。
- **地平线保护**：整片落在水天交界线之上的网格直接剔除（用 `Projection.HorizonFunction` 做保守判定），焦散不会画到云和日月上。
- **暂停**：`time` 由 voyage time 提供，暂停即冻结；模块不持有任何跨帧可变状态。

### DuDv：真实生效的逐顶点置换

1. `WaterFX.ResolveSampler()` 经 `cache.GetResource("Image", path)` 取 DuDv，**一次性**解码成 17×17 位移网格（`Image:GetPixelBilinear`），缓存；失败缓存 `false` 不再重试。
2. 解码按 `(rg - 0.5) × 2`（中性值 0.5），不是把 RGB 当位移。
3. 每个网格顶点按自身世界位置采样位移场，`u += dx * dudvStrength`。
4. 相邻片共享角点 UV → 沿公共边线性插值一致 → 位移连续、无接缝。

**这不是叠图假象**：关掉 DuDv（`dudvEnabled=false`）会真实改变采样结果 —— 离线像素对比中 5.67% 的像素 alpha 发生变化（strength 0.05 时 12.99%）。

> 实证踩坑：早期实现写 `type(color) == "table"`，而引擎的 `Image`/`Color` 是 **userdata**，导致解码全 0、表面"接了 DuDv"实际纯滚动。现已改为鸭子类型探测，并由 `SeaNearWaterFXTests` 的 "引擎对象是 userdata" 用例锁死。

## 4. 资产

`tests/prepare_ocean_water_fx_art.py` 程序化生成（可完全重跑，无外部源图）：

| 文件 | 规格 | 说明 |
|---|---|---|
| `assets/image/SeaSurface/water_caustic_light.png` | 512² RGBA，双向无缝，preload | 主焦散：低饱和浅青白水彩闭合网眼 |
| `.../water_caustic_light_alt.png` | 512² RGBA，双向无缝，懒加载 | 双层备选（默认关） |
| `.../water_dudv_flow.png` | 256² RGB，双向无缝，懒加载 | R/G = 0.5 + 位移（curl 场，近似无散度） |

生成方式：可平铺值噪声 FBM → 域扭曲 → 等值线抽取（`1-|2f-1|` 取幂）→ 疏密调制 → 环绕模糊柔边。
`--check` 校验尺寸/模式/无缝性（接缝步长 ≤ 内部最大相邻步长）/中性值/覆盖度/饱和度/catalog 同步。

catalog 由既有生成器统一重生成（`repeatTexture=true` 必需：运行期 UV 是无界世界平铺坐标）。

## 5. 开关与回退

- 整体关闭：`Config.visual.nearWaterFX.enabled = false`（默认 **true**）。
  运行时对比：调试面板 **NearWater** 按钮（`SeaDebug`，需 `development` 或 `Config.debug.enabled`）。
- 只关 DuDv：`dudvEnabled = false` → 退回纯滚动（CPU 少 0.27ms/帧）。
- 双层：`secondLayer = true`（默认关；打开约 +1.1ms/帧）。
- 关闭后 `Surface` 完全跳过本模块：不加载贴图、不出笔、原有海面表现一字不变（`SeaNearWaterFXTests` 有断言）。

## 6. 性能（离线 measure，非真机）

Lua 侧 `WaterFX.Draw` 每帧（960×540 逻辑视口）：

| 配置 | ms/帧 | fill/帧 |
|---|---:|---:|
| 默认（7×7 + DuDv） | **0.995** | 58 |
| 关 DuDv | 0.730 | 58 |
| 双层 | 1.865 | 116 |
| 关闭 | 0 | 0 |

无 RenderTarget、无全屏 Shader、无逐帧纹理创建；片数硬上限 12×12，亚像素片剔除。
**真机 FPS / GPU 耗时 / 内存未测量**，不做任何推断。

## 7. 验证记录

- Lua 语法：181 文件全通过。
- 隔离回归：79 套件，78 通过；唯一失败 `SeaMotionEffectsTests / water mark budget` 为**改动前既有失败**（已用 `git stash` 前后对照确认），与本轮无关。
- 新增 `SeaNearWaterFXTests`：19 项全通过。
- EmilLua LSP：error 22 → 22（逐条 diff 无新增）。
- 资产校验：`prepare_ocean_water_fx_art.py --check` PASS；`prepare_ocean_sea_art.py --check` PASS。
- 远端构建：`taptap-maker build` **成功**（commit `343e4c5`，pushed）。
- 离线像素证据：`outputs/near-water-fx/*.png` + `preview-report.json`（Lua 数学 + NanoVG 等价光栅化，**不是**引擎截图）。
- **未做**：真机观感、真机帧率、本地窗口预览（会话已 stopped，按规则不自动重启）。

## 8. 后续建议

1. 真机上用 NearWater 按钮 A/B，按观感微调 `alpha`（0.16 起）、`tileMeters`（22 起）、`feather`（0.52 起）。
2. 若近水想更细碎，把 `cellMeters` 降到 9 提高位移分辨率（fill 数不变，仅片数×2.25）。
3. 若真机出现斜纹/摩尔纹，先提高 `tileMeters`（放大瓦片），不要急着加第二层。
4. 逐像素置换若确实需要，再单独评估 ABC（RT + SurfaceShader + 回送），不要与本层耦合。
