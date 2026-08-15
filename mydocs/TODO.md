# TODO

## mdview 按段增量

- [x] render：segments 记录 + splice_fragment + render_blocks_fragment
- [x] 编辑 TextChanged 按 AST 段 diff 增量
- [x] details 折叠增量
- [x] L 语言只刷文案
- [x] README / CHANGELOG + 冒烟

### 回退全量的情况

- 强制 `r` / `:MdViewRefresh`
- 预览宽度变化
- 脏段过多（>10）或几乎整篇
- 脏段含 **heading**（TOC / 自动序号）
