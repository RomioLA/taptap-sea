# Sea Runtime V1 — 第二次数值补充当前决定

当前参数已确定：米制；相机全高45m/16:9宽80m；抛网30m、网半径8m、动作4s；普通操作5m、港口10m、投放12m、轮廓80m/识别20m、透视揭示20m。不再留空抛网参数，正式配置为V1_IMPLEMENTATION_VALUE。

鱼数值保留：tuna prey30/BIG36/attracted6；Avoid sardine4/tuna6；初次生成距当前船15/30，tuna当天出发点200同时成立。第10条覆盖旧诱饵优先级，当前为Avoid > 危险/Chase > Attracted > Wander。20/4继续为BALANCE_TARGET，不补满。

当前A_NUMERIC_SUPPLEMENT_02=PARTIAL：现有配置和可运行世界接口自动检查通过，尚无完整4秒动作/CompleteFishing、打捞/港口/地点识别流程；按附件只记录契约不扩大范围。A未来负责世界动作/结果，B负责体力/库存和保存识别状态，不修改其经济/玩法配置。

详细20项核查、接口和真实运行范围见A_NUMERIC_SUPPLEMENT_02.md。硬件/视觉/正式集成仍待验证；DDS/DLL环境问题未处理，preview停止，未push。
