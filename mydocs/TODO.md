# TODO

## mdview 代码块折叠增量刷新

- [x] `render.render_code_fragment`：单独渲染一个代码块
- [x] `render.patch_code_block`：替换 result 中该块并平移后续行号
- [x] `render.apply_range`：局部写 buffer + 局部 extmarks
- [x] `toggle_code_fold` 改用增量；仅 `code_fold` hit 触发
- [x] 更新 README / CHANGELOG
- [x] headless 冒烟：expand/collapse 行数与 apply_range
