# 了不起的修仙家族模拟器

## 项目概况

独立于《除魔务尽》的真人家族文字修仙游戏。技术栈为 React、TypeScript、Vite、CloudBase PostgreSQL、Capacitor Android。项目目录为 `C:\Users\23604\family-cultivation`，公网地址为 https://family-cultivation-chumowujin-beta-d0faxqcq5b2c32fa.webapps.tcloudbase.com/ 。

## 运行与发布

```powershell
npm install
npm run dev
npm run build
```

静态网页通过 CloudBase MCP 上传 `dist/`。发布前必须先构建，发布后检查公网 HTML 返回的 JS/CSS 构建哈希。`.env.local`、管理密钥、签名文件、`dist/`、`.tmp/` 和 `node_modules/` 不得提交。

CloudBase 环境：`chumowujin-beta-d0faxqcq5b2c32fa`，区域 `ap-shanghai`。数据库迁移在 `cloudbase/migrations/`。PostgreSQL 关键数据只能通过受控 RPC 修改；`auth.uid()` 是 text，管理密钥不得进入前端。

## 当前已实现

- 用户名密码登录、注册中转、设备注册限制；前50名立族，后续玩家作为真人道侣子女出生。
- 道侣、子女名额、家族、族谱、家族城池分配、坐化注销。坐化保留族谱记录、清理资产并释放立族名额。
- 修炼、六大境界九层、九品试炼、丹田灵气/容量、道基、寿元、生命、灵力、攻击、防御、速度、神识、心境、战力。
- 储物200格、装备槽、基础装备、装备穿戴、炼器/炼丹/画符/功法创作配方、采矿、灵田采集。
- 无名心法、无名战技、家族心法、神识术；卷二功法页面。
- 24州、100城、城内九宫格、房间出口、相邻城池30秒徒步、州域/大陆地图。
- 野外闭关需要金刚阵；荒原/森林遇怪；引妖散；自动战斗、中文怪物名、怪物图片、回合日志、材料和灵石掉落。
- 战力榜、境界榜、灵石榜、家族榜；个人主页、新手教程；聊天、头像、表情、语音、资料卡和社交操作。
- 手机端明亮布局：主页面上方大世界九宫格和快速寻路，下方闭关区；聊天浮窗支持自动消息、隐藏、长按拖动和归位。

## 最近 UI 验收目标

- 地名行显示地点、遇怪概率、危险等级和附近人数，不显示重复的方位文字。
- 大世界地图显示为“大世界地图”浮窗，点击后展开；城内、州域、大陆默认400%并聚焦当前建筑/城池/州。
- 快速寻路先列城内建筑，再列相邻城池；非相邻城市提示沿城市连接路线前往。
- 出口走到后自动切换下一房间。
- 自动寻路中才显示底部取消按钮。
- 闭关区只保留开始闭关、结束闭关；城内安全，野外需要防御阵法。

## 重要维护规则

- 不要修改 `F:\lingjiechuanshuo` 的 Godot 项目代码。
- 新增数据库结构必须使用版本迁移；修改 RPC 前先检查实际表字段，避免引用不存在的列。
- 页面改动必须运行 `npm run build`；涉及交互时用浏览器检查真实渲染，不能把静态上传成功当成用户界面验收。
- 当前怪物的复杂毒、幻象、属性克制和高阶怪物仍可继续扩展；高阶资源产区和部分制造产出仍在迭代。

## Git

远程仓库：<https://github.com/13645264864/liaobuqide-xiuxian-jiazu-moniji>

推送前确认 `.gitignore` 没有遗漏密钥、临时文件、构建产物和签名文件。

## 当前版本记录（2026-10-07）

- Git 当前基线：`4da1ff1`（自动跨房间出口版本）。
- 本次已将网页和数据库地图状态恢复到怪物名称修复前的稳定地图状态；未把后续 `20261007012200` 之后的错误地图覆盖迁移纳入仓库。
- 当前公网验证地址：<https://family-cultivation-chumowujin-beta-d0faxqcq5b2c32fa.webapps.tcloudbase.com/?v=rollback-map-20261007>。
- 当前已验证：项目构建成功、静态托管上传成功、地图 RPC 包含 `cells`、`exits`、`navigation`、`map_rooms`、`atlas` 字段。
- 继续开发前，先检查 `git log`、`git status` 和线上 `fc_get_world_state()`；不要再次整段覆盖地图 RPC。怪物中文名修复应单独处理，不得影响地图返回结构。
