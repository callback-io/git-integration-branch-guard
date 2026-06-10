# Git Integration Branch Guard

[English](README.md)

Git Integration Branch Guard 是一个通用的 Agent Skill，适用于使用共享开发、测试、UAT、预发或集成分支的 Git 仓库。

这个项目源自我反复踩过的同一个坑：AI 编程助手总是"贴心地"把 `dev` 合进我的功能分支帮我同步最新，或者直接从 `dev` 而不是 `main` 拉新的工作分支。每一次，别人未完成的改动都会悄悄跟着我的分支流向发布。

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
├── .claude-plugin/
│   ├── plugin.json            # Claude Code plugin 元数据
│   └── marketplace.json       # /plugin marketplace add 用的 marketplace 清单
├── .github/
│   └── workflows/
│       └── ci.yml
├── action.yml                 # 包装审计脚本的 GitHub Action
├── hooks/
│   └── hooks.json             # PreToolUse hook 注册（仅 plugin 安装路径）
├── install.sh                 # 把 skill 复制进检测到的 agent 运行时
├── schema/
│   └── branch-guard.schema.json
├── scripts/
│   └── guard-git-command.sh   # PreToolUse 命令守卫
├── skills/
│   └── git-integration-branch-guard/
│       ├── SKILL.md
│       └── scripts/
│           └── audit-branch-flow.sh
├── tests/
│   ├── audit-branch-flow-tests.sh
│   ├── guard-git-command-tests.sh
│   └── install-tests.sh
├── CHANGELOG.md
├── CONTRIBUTING.md
├── SECURITY.md
├── README.md
├── README.zh-CN.md
└── LICENSE
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

只有 `SKILL.md` 是必需的。这个 skill 额外包含一个 shell 脚本，因为发布前分支审计是一组重复的 Git 检查，用确定性脚本承载更可靠。skill 本体位于 `skills/git-integration-branch-guard/`，手动安装时复制这个目录即可。

## 安装方式

按你的工具链选择安装路径。以下每种方式安装的都是同一个 skill；只有 Claude Code plugin 路径会额外注册命令守卫 hook。

### 作为 Claude Code plugin（skill + 命令守卫 hook）

```text
/plugin marketplace add callback-io/git-integration-branch-guard
/plugin install git-integration-branch-guard@git-integration-branch-guard
```

这是唯一会启用 PreToolUse 命令守卫的安装路径，因为 plugin 安装流程自带 hook 注册的用户确认环节。兼容 Claude Code marketplace 的运行时（例如 Qwen Code）可以安装同一个包。

### 使用安装脚本（任何 Agent Skills 运行时）

```bash
git clone https://github.com/callback-io/git-integration-branch-guard
cd git-integration-branch-guard
./install.sh --list   # 先预览检测到的运行时
./install.sh          # 把 skill 复制进每个检测到的运行时
```

安装脚本会检测 `~/.claude`、`~/.codex`（遵循 `$CODEX_HOME`）、`~/.gemini` 和 `~/.qwen`，把 skill 复制进各运行时的 `skills` 目录。其他运行时用 `--target <目录>` 指定；`--project` 装进当前仓库的 `.claude/skills`；`--update` 刷新旧版本。安装脚本只复制 skill 文件，绝不修改 agent 设置或注册 hook。

### 让 AI agent 自助安装

想让你的编程 agent 替你安装时，把仓库地址给它并让它执行：

```bash
git clone https://github.com/callback-io/git-integration-branch-guard /tmp/git-integration-branch-guard
/tmp/git-integration-branch-guard/install.sh --list
/tmp/git-integration-branch-guard/install.sh
```

运行前先审阅安装脚本。它被刻意限制为只向 skills 目录复制文件，授权执行的风险很低；不要用管道直接从网络执行脚本。

### 手动安装

1. 将 `skills/git-integration-branch-guard/` 复制到你的 agent 运行时的 skills 目录。
2. 保持 `SKILL.md` 和 `scripts/audit-branch-flow.sh` 在同一个 skill 目录下，方便 skill 引用辅助脚本。
3. 按照你的 agent 运行时说明启用或加载这个 skill。

### 只作为审计脚本使用

1. 将 `skills/git-integration-branch-guard/scripts/audit-branch-flow.sh` 复制到目标仓库或团队共享工具目录。
2. 在需要审计的 Git 工作区内运行它。
3. 如果脚本放在仓库外，请用绝对路径调用。

### 平台支持

skill 遵循 [Agent Skills](https://agentskills.io) 开放标准，任何兼容运行时都可以加载,包括与 CLI 共享 skills 目录的桌面端和 web 端：

| 运行时 | Skill | 命令守卫 hook | 安装方式 |
|---|---|---|---|
| Claude Code（CLI、桌面、web） | 支持 | 支持 | plugin 或安装脚本 |
| Qwen Code | 支持 | 通过 Claude Code marketplace 兼容获得 | plugin 或安装脚本 |
| OpenAI Codex（CLI、桌面 app） | 支持 | 不支持 | 安装脚本（`~/.codex/skills`） |
| Gemini CLI | 支持 | 不支持 | 安装脚本（`~/.gemini/skills`） |
| Cursor、GitHub Copilot、OpenCode 等 | 支持 | 不支持 | 手动复制进运行时 skills 目录 |

不支持 hook 的运行时仍有两层防护：skill 在行动前引导 agent，审计脚本（或 GitHub Action）在发布前验证历史。

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

## 仓库级配置

在仓库根目录用 `.branch-guard.json` 声明一次分支角色，skill、命令守卫 hook 和审计脚本会读取同一份策略：

```json
{
  "$schema": "https://raw.githubusercontent.com/callback-io/git-integration-branch-guard/main/schema/branch-guard.schema.json",
  "production": ["main"],
  "integration": ["dev", "staging"],
  "workPatterns": ["feat/*", "fix/*"],
  "promotionPaths": ["dev->staging"],
  "enforcement": "deny"
}
```

- `production` 和 `integration` 接受分支名或 glob pattern；不属于这两类的都按工作分支处理。
- `promotionPaths` 列出唯一允许的共享环境晋级路径，写法为 `source->target`。
- `enforcement` 控制命令守卫 hook 的反应：`deny` 直接拦截，`ask` 交给用户确认，`warn` 放行但给出警告。

没有这个文件时，守卫回退到常见分支名（`main`/`master` 等视为生产，`dev`/`test`/`staging` 等视为验证池）。文件要保持扁平——只用字符串数组和字符串标量——纯 shell 的消费方才能解析。仓库定制的 agent skill 往往可以退化成这一个配置文件加通用 skill。

## 命令守卫 Hook（Claude Code plugin）

以 Claude Code plugin 安装后，`scripts/guard-git-command.sh` 会作为 PreToolUse hook 在每次 Bash 工具调用时运行，在执行前拦截违反单向策略的 git 流向：

- 把共享验证分支带进工作分支或生产分支的 `merge`、`rebase`、`pull`、`reset --hard`
- 从共享验证分支创建新分支（`switch -c`、`checkout -b`、`branch`）
- 把验证分支推上生产的 refspec（`push origin dev:main`）
- 未在 `promotionPaths` 声明的共享环境晋级
- cherry-pick 只能从验证分支到达的提交（以 `ask` 应答,因为复制提交的来源存在歧义）

hook 按 fail-open 设计：payload 无法解析、找不到 JSON 解析器、目录不是 Git 工作区时,它保持沉默,绝不阻塞正常工作。临时绕过可设置 `BRANCH_GUARD_DISABLE=1`。skill 是第一层（行动前引导），审计脚本是最后一层（发布前验证），hook 是中间的强制层。

## 使用审计脚本

脚本需要 Bash 环境。Windows 上请在 Git Bash（随 Git for Windows 一起安装）或 WSL 里运行。

在 Git 工作区内执行：

```bash
skills/git-integration-branch-guard/scripts/audit-branch-flow.sh --production origin/main --integration dev
```

仓库里有 `.branch-guard.json` 时不需要参数：

```bash
skills/git-integration-branch-guard/scripts/audit-branch-flow.sh
```

审计另一个分支：

```bash
skills/git-integration-branch-guard/scripts/audit-branch-flow.sh --production origin/main --integration origin/dev --integration origin/test --integration origin/uat --head feature/example
```

脚本退出码：

- `0`：没有发现明显的共享验证分支污染
- `1`：发现疑似污染；带 `--strict` 时，仅有 patch-id 提示性匹配也按此退出
- `2`：参数或运行环境错误

如果仓库有多个共享验证分支，可以重复传入 `--integration`。

脚本会检查四类信号：

- merge commit 或 commit subject 是否按字面量整词提到共享验证分支名（`dev` 不会再误匹配 `developer` 这类词）
- 当共享验证分支 ref 在本地存在时，merge commit 的非第一父提交是否可从该共享验证分支到达
- 提交的 stable patch-id 是否以不同 hash 同时存在于共享验证分支上——这能查出改写过 message 的 cherry-pick 或 rebase 副本（提示性输出，可用 `--no-check-patch-id` 关闭）
- 发布范围内的所有非 merge commit，供人工复核

这个脚本有意保持保守。它是发布前辅助检查，不是“分支一定干净”的证明。复制 patch、已删除 ref、重写历史和自定义仓库流程仍可能需要人工 review。

## GitHub Action

在每个指向生产分支的 pull request 上跑同样的审计：

```yaml
name: branch-guard
on:
  pull_request:
    branches: [main]

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: callback-io/git-integration-branch-guard@main
        with:
          production: origin/main
          integration: dev,staging
```

审计需要完整历史，所以 `fetch-depth: 0` 是必需的。仓库里有 `.branch-guard.json` 时 `production` 和 `integration` 可以省略；`strict: "true"` 会让提示性 patch-id 匹配也判失败。这把守卫从 agent 扩展到了每一个人类贡献者。

## 开发检查

发布改动前建议运行：

```bash
bash -n skills/git-integration-branch-guard/scripts/audit-branch-flow.sh scripts/guard-git-command.sh install.sh tests/*.sh
bash tests/audit-branch-flow-tests.sh
bash tests/guard-git-command-tests.sh
bash tests/install-tests.sh
shellcheck skills/git-integration-branch-guard/scripts/audit-branch-flow.sh scripts/guard-git-command.sh install.sh tests/*.sh
```

GitHub Actions 会在 push 和 pull request 时运行同样的检查：ShellCheck 在 Linux 上运行，语法检查和测试在 Linux、macOS 和 Windows（Git Bash）上分别运行，持续保证 Bash 3.2 基线和 Windows 兼容性。CI 还会校验所有 JSON / YAML 清单，并对 GitHub Action 做自测：现场构造干净分支和污染分支，断言审计放行前者、拦下后者、并拒绝浅克隆。

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
