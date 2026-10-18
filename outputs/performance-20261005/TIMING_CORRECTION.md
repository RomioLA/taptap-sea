# 旧计时字段更正

本目录此前使用Windows Lua `os.clock()`输出的`luaCpuMs`、`cpuReductionPercent`及热点`ms`，实际为经过时间与其比较，不能视为CPU时间／FPS改善。等待0.25秒实验已确认这一行为。原JSON保持原样，调用次数和分配量统计不受影响。

`island-components-legacy-elapsed.json`保留首次岛组件报告；新`profile_islands.py`使用Python `process_time`／`perf_counter`，分别输出`processCpuMs`／`elapsedMs`。相邻分项对照仍存在波动，不能把增量作为精确占比。插桩组件的`traceElapsedMs`只是经过时间，含诊断开销。

`compare_fix.py`后续新报告使用`*-process-clock.json`并区分两类计时，不覆盖旧结果。未重新执行的旧历史基准不因脚本修改而变成CPU证据。详细结论见`docs/ISLAND_PERFORMANCE_ANALYSIS_20261005.md`。
