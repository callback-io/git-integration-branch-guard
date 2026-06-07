# Git Integration Branch Guard

[English](README.md)

Git Integration Branch Guard 是一个通用的 Agent Skill，适用于使用共享开发、测试、UAT、预发或集成分支的 Git 仓库。

它让 agent 记住一条核心规则：

> 共享验证分支是收集池或晋级池，不是工作分支的上游。

工作分支可以合入共享验证分支做测试或环境晋级，但这些共享分支不能反向合回工作分支，也不能直接合入生产分支。

## 为什么需要它

很多团队会用 `dev`、`test`、`uat`、`staging` 这类共享分支部署或验证多个进行中的改动。这些分支适合测试和环境晋级，但不适合作为上游。

如果某个工作分支从共享验证分支执行 merge、rebase、pull 或 cherry-pick，它可能会悄悄带入其他尚未完成的改动。之后这个工作分支一旦发布，那些不属于本次范围的改动也可能一起进入生产。

这个 skill 会把这类团队分支策略变成明确的 agent 行为：

- 在执行会改变分支历史的命令前识别 source 和 target
- 拒绝共享验证分支到工作分支或生产分支的危险流向
- 建议改为从生产分支同步
- 发布前审计分支历史
- 保持工作分支范围清晰、生产发布干净

## 目录结构

```text
git-integration-branch-guard/
├── .github/
│   └── workflows/
│       └── ci.yml
├── .editorconfig
├── .gitattributes
├── .gitignore
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
├── SKILL.md
├── README.md
├── README.zh-CN.md
├── LICENSE
├── scripts/
│   └── audit-branch-flow.sh
└── tests/
    └── audit-branch-flow-tests.sh
```

## Skill 格式

这个仓库遵循 Agent Skills 格式：

```text
skill-name/
├── SKILL.md          # 必需：YAML frontmatter + Markdown 指令
├── scripts/          # 可选：可执行辅助脚本
├── references/       # 可选：按需加载的补充文档
└── assets/           # 可选：静态模板或资源
```

只有 `SKILL.md` 是必需的。这个 skill 额外包含一个 shell 脚本，因为发布前分支审计是一组重复的 Git 检查，用确定性脚本承载更可靠。

## 安装方式

作为 Agent Skill 使用：

1. 将这个目录复制或克隆到你的 agent 运行时的 skills 目录。
2. 保持 `SKILL.md` 和 `scripts/audit-branch-flow.sh` 在同一个 skill 目录下，方便 skill 引用辅助脚本。
3. 按照你的 agent 运行时说明启用或加载这个 skill。

只作为审计脚本使用：

1. 将 `scripts/audit-branch-flow.sh` 复制到目标仓库或团队共享工具目录。
2. 在需要审计的 Git 工作区内运行它。
3. 如果脚本放在仓库外，请用绝对路径调用。

## 工作流概览

允许：

```text
production -> work branch
production -> shared validation branch
work branch -> shared validation branch
work branch -> production
shared validation branch -> later shared validation branch
```

最后一种只在仓库明确规定环境晋级路径时允许，例如 `dev -> test -> uat`。

禁止：

```text
shared validation branch -> work branch
shared validation branch -> production
```

Skill 里的分支名只是常见示例：

- 生产分支：`main`、`master`、`trunk`、`prod`、`production`、`release`，或自定义命名
- 共享验证分支：`dev`、`develop`、`test`、`qa`、`uat`、`stage`、`staging`、`preprod`、`integration`，或自定义命名
- 工作分支：`feat/*`、`feature/*`、`features/*`、`fix/*`、`bugfix/*`、`hotfix/*`、`chore/*`、`refactor/*`、`task/*`、`ticket/*`，或团队自定义命名

不要只靠前缀判断。只要某个分支承载的是一个有限范围的改动，并准备独立发布到生产，它就是工作分支；名字可以是 `features/foo`、`user/foo`、`ticket-123` 或其他团队约定。

不要只靠分支名判断。某个仓库里的 `dev` 可能是共享验证分支；另一个仓库里的 `dev` 可能是局部开发分支、长期环境分支，或者环境晋级链路的一环。先映射角色，再套规则。

使用前先把这些角色映射到自己的仓库。

## 使用审计脚本

脚本需要 Bash 环境。Windows 上请在 Git Bash（随 Git for Windows 一起安装）或 WSL 里运行。

在 Git 工作区内执行：

```bash
scripts/audit-branch-flow.sh --production origin/main --integration dev
```

审计另一个分支：

```bash
scripts/audit-branch-flow.sh --production origin/main --integration origin/dev --integration origin/test --integration origin/uat --head feature/example
```

脚本退出码：

- `0`：没有发现明显的共享验证分支污染
- `1`：发现疑似污染
- `2`：参数或运行环境错误

如果仓库有多个共享验证分支，可以重复传入 `--integration`。

脚本会检查三类信号：

- merge commit 或 commit subject 是否按字面量提到共享验证分支名
- 当共享验证分支 ref 在本地存在时，merge commit 的非第一父提交是否可从该共享验证分支到达
- 发布范围内的所有非 merge commit，供人工复核

这个脚本有意保持保守。它是发布前辅助检查，不是“分支一定干净”的证明。rebase、cherry-pick、复制 patch、已删除 ref、重写历史和自定义仓库流程仍可能需要人工 review。

## 开发检查

发布改动前建议运行：

```bash
bash -n scripts/audit-branch-flow.sh tests/audit-branch-flow-tests.sh
bash tests/audit-branch-flow-tests.sh
shellcheck scripts/audit-branch-flow.sh tests/audit-branch-flow-tests.sh
```

GitHub Actions 会在 push 和 pull request 时运行同样的检查：ShellCheck 在 Linux 上运行，语法检查和测试在 Linux、macOS 和 Windows（Git Bash）上分别运行，持续保证 Bash 3.2 基线和 Windows 兼容性。

## 这个 Skill 应该拦住的请求

- “创建一个 feature 分支做这个修复。”
- “把这个分支同步到最新。”
- “把这个工作分支合到 dev 测试。”
- “把 dev 拉到这个 feature 分支。”
- “把这个 fix 分支 rebase 到 staging 上。”
- “把 uat 拉到我的本地工作分支。”
- “把 dev 晋级到 test。”
- “把 develop 合到 main。”
- “发布前帮我检查一下这个分支。”

## 推荐 Commit 风格

如果你要发布这个仓库的改动，commit message 建议保持产品无关、工具无关。好的例子：

```text
docs: add Chinese README
feat: add branch flow audit script
fix: clarify integration branch release rule
```

避免在 commit message 里提到具体助手运行时、产品或内部项目。

## 贡献与安全

贡献指南见 [CONTRIBUTING.md](CONTRIBUTING.md)，漏洞报告说明见 [SECURITY.md](SECURITY.md)。

## 开源协议

MIT，见 [LICENSE](LICENSE)。
