# 微信公众号 / 收藏文章阅读 MCP 接口调研

> 调研目标：为 TechMarkdown 寻找接入“微信公众号文章阅读 / 收藏文章阅读”并一键总结成知识文档的技术路径。
> 调研日期：2026-06-27

---

## 1. 核心结论

| 需求 | 官方 API 支持 | 可行方案 | 推荐度 |
|---|---|---|---|
| **阅读任意公众号文章（给定 URL）** | ❌ 无官方接口 | 第三方 MCP Server 通过浏览器/爬虫解析 | ⭐⭐⭐⭐ |
| **读取微信「收藏」文章列表** | ❌ 无公开 API | 浏览器自动化、手动导出、或等待腾讯官方工具 | ⭐⭐ |
| **微信读书划线/笔记** | ⚠️ 无官方开放 API，但社区有 MCP | wechat-reader / 微信读书 MCP | ⭐⭐⭐ |
| **公众号后台（自己的号）管理** | ✅ 有官方 API | wechat_oa_mcp / wechat-publisher-mcp | ⭐⭐⭐⭐ |

**结论**：若目标是“用户复制一篇公众号文章链接，AI 一键抓取并总结为本地知识文档”，最成熟的路径是 **集成一个基于浏览器自动化的 WeChat 文章抓取 MCP Server**；若目标是“批量导入微信收藏夹”，当前没有稳定官方方案，需走浏览器自动化或人工中转。

---

## 2. 微信公众号文章阅读的 MCP Server 生态

### 2.1 按 URL 提取文章内容

#### 1) guanshilong/mcp（公众号文章爬取 MCP）
- **GitHub**：https://github.com/guanshilong/mcp
- **协议**：同时支持 MCP stdio 与 HTTP Server（端口 5002）
- **核心接口**：
  - `POST /extract` → 输入微信公众号文章 URL，返回 `{title, author, content}`，content 为 Markdown
- **优点**：简单、返回 Markdown、可本地部署
- **缺点**：依赖网页解析，微信反爬升级可能失效

```bash
python mcp_server.py           # stdio MCP
curl -X POST http://localhost:5002/extract \
  -H "Content-Type: application/json" \
  -d '{"url": "https://mp.weixin.qq.com/s/..."}'
```

#### 2) wechat-reader（xiguawang）
- **GitHub**：https://github.com/xiguawang/wechat-reader
- **特点**：CLI + MCP Server + Python API 三位一体；可复用已登录浏览器会话
- **MCP 工具**：
  - `wechat_read_article(url)`
  - `wechat_open_article(url)`
  - `wechat_read_current_tab()`
  - `wechat_get_status()`
- **状态返回**：`ok` / `captcha_required` / `rate_limited` / `browser_not_ready`
- **优点**：稳定性高、可处理验证、返回结构化状态
- **缺点**：需要 Playwright + Chromium，首次 setup 较重

```bash
pip install -e .
python -m playwright install chromium
wechat-reader-mcp   # 启动 stdio MCP server
```

#### 3) MCPWeChatOfficialAccounts（ditingdapeng）
- **GitHub**：https://github.com/ditingdapeng/MCPWeChatOfficialAccounts
- **技术栈**：FastMCP + Selenium
- **能力**：抓取公众号文章、下载图片、内容分析
- **配置**：`HEADLESS=true`、`DOWNLOAD_IMAGES=true`
- **优点**：可抓取图片、完整文章
- **缺点**：Selenium 环境重、易被反爬/验证码拦截

### 2.2 搜索公众号文章

#### weixin-search-mcp（wbsu2003）
- **GitHub**：https://github.com/wbsu2003/weixin-search-mcp
- **原理**：基于搜狗微信搜索（`weixin.sogou.com`）
- **接口**：
  - `POST /search_articles` → `{query, top_num}`
- **优点**：无需登录即可按关键词搜索
- **缺点**：搜狗反爬严格、结果可能不全、需要处理验证码

### 2.3 公众号后台管理（发布/素材，非阅读）

若业务目标是“将总结后的知识文档发布到公众号”，可使用：

| 项目 | 链接 | 说明 |
|---|---|---|
| wechat_oa_mcp | https://github.com/kakaxi3019/wechat_oa_mcp | 获取 access_token、创建草稿、发布 |
| wechat-publisher-mcp | https://github.com/BobGod/wechat-publisher-mcp | 自动发布公众号文章 |
| wenyan-mcp | https://github.com/caol64/wenyan-mcp | Markdown → 公众号排版 → 发布 |

> 这些与本需求的“阅读/收藏”方向相反，仅作记录。

---

## 3. 微信「收藏」文章的读取路径

### 3.1 官方能力

- **微信公众平台 API**：没有提供读取用户收藏夹的接口。
- **微信开放/小程序 API**：没有“获取用户收藏文章”能力。
- **腾讯内测产品“狍子AI”**（2026-05 新闻）：主打“微信收藏文章一键入库知识库”，但目前未正式上线，且入口在公众号/小程序，非开放 API。

### 3.2 可行但非官方路径

| 方案 | 原理 | 稳定性 | 推荐度 |
|---|---|---|---|
| **浏览器自动化访问 `wx.qq.com` / 微信网页版收藏** | 模拟登录后抓取收藏列表 | 低（登录难、易风控） | ⭐⭐ |
| **Android 辅助功能 / 微信 Hook** | 读取微信本地数据库 | 极低（封号风险、违法协议） | ⭐ |
| **用户手动转发文章给文件传输助手/小程序** | 用户主动分享，服务端解析链接 | 高 | ⭐⭐⭐⭐ |
| **微信读书 MCP** | 读取微信读书里的划线/笔记 | 中 | ⭐⭐⭐ |

### 3.3 微信读书 MCP

- 已有社区项目支持将微信读书划线笔记同步到本地并生成知识卡片。
- 适合场景：用户在微信读书里划线，AI 自动整理成读书笔记。
- 与“公众号收藏”不同，但可作为知识来源补充。

---

## 4. 接入 TechMarkdown 的技术实现路径

### 4.1 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│  TechMarkdown（macOS App）                                    │
│  ├─ LaunchScreen / ContentView                                │
│  ├─ AIAgent                                                   │
│  ├─ ToolRegistry                                              │
│  └─ MCPClient                                                 │
└──────────────────────┬──────────────────────────────────────┘
                       │ MCP stdio / HTTP
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  wechat-reader / guanshilong/mcp（本地 MCP Server）           │
│  ├─ 输入：微信公众号文章 URL                                   │
│  ├─ 输出：Markdown 格式正文 {title, author, content}          │
│  └─ 处理：浏览器自动化 / 网页解析                              │
└──────────────────────┬──────────────────────────────────────┘
                       │ Markdown
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  TechMarkdown 内部总结流程                                    │
│  ├─ 1. 接收文章 Markdown                                      │
│  ├─ 2. 调用 LLM 生成摘要/知识结构（可复用 AIService）          │
│  ├─ 3. 保存为本地 .md 文件（项目目录 / memory 目录）           │
│  ├─ 4. MemoryService.recordFileInteraction 加入索引           │
│  └─ 5. 可选：注入 AI 对话上下文，支持追问                      │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 推荐的最小可行实现（MVP）

#### Step 1：集成 wechat-reader MCP Server

在 `AISettingsView` 的 MCP 配置中增加一个预设：

```json
{
  "mcpServers": {
    "wechat-reader": {
      "command": "wechat-reader-mcp",
      "args": []
    }
  }
}
```

#### Step 2：新增 TechMarkdown 内部 Tool

在 `ToolRegistry` 注册一个 `summarize_wechat_article` 工具：

```swift
// 伪代码
func summarizeWechatArticle(url: String) async throws -> String {
    // 1. 调用 MCP 工具读取文章
    let article = try await mcpClient.call(tool: "wechat_read_article", arguments: ["url": url])
    // 2. 构造总结 prompt
    let prompt = """
    请对以下微信公众号文章进行结构化总结，输出 Markdown：
    标题：\(article.title)
    作者：\(article.author)
    正文：\(article.content)

    要求：
    - 提取 3-5 个核心观点
    - 保留关键数据、引用、结论
    - 生成适合放入知识库的格式
    """
    // 3. 调用 LLM
    let summary = try await aiService.complete(prompt: prompt)
    // 4. 保存文件
    let fileURL = try saveToKnowledgeBase(summary, title: article.title)
    // 5. 记录索引
    MemoryService.shared.recordFileInteraction(path: fileURL.path, text: summary)
    return "已保存至 \(fileURL.path)"
}
```

#### Step 3：用户交互入口

- 在启动页或 AI 侧边栏增加“粘贴公众号链接”输入框。
- 在 Skill 列表中新增“总结公众号文章”快捷任务。
- 支持用户拖拽公众号文章链接到编辑器/AI 侧边栏触发总结。

### 4.3 批量粘贴与批量总结

可以支持一次性粘贴多条链接进行批量总结。底层 MCP Server 多为单 URL 接口，因此批量能力需要在 TechMarkdown 应用层实现调度。

#### 批量流程

```
用户粘贴多行文本
    │
    ▼
解析链接（每行一个，或自动识别 mp.weixin.qq.com/s/...）
    │
    ▼
去重 + 校验 URL 格式
    │
    ▼
串行 / 限流并发调用 wechat_read_article(url)
    │
    ▼
每篇独立生成总结（调用 LLM）
    │
    ▼
分别保存为 .md 文件 + MemoryService 索引
    │
    ▼
汇总报告：成功 N 篇 / 失败 M 篇，列出结果路径
```

#### Swift 伪代码

```swift
struct BatchWechatSummaryResult {
    let url: String
    let title: String
    let savedURL: URL?
    let error: Error?
}

func batchSummarizeWechatArticles(input: String) async -> [BatchWechatSummaryResult] {
    let urls = extractWechatURLs(from: input)
    let uniqueURLs = Array(Set(urls))
    
    var results: [BatchWechatSummaryResult] = []
    
    // 串行调用，避免触发微信反爬；如后端支持限流并发可改为 withTaskGroup
    for url in uniqueURLs {
        do {
            let article = try await mcpClient.call(tool: "wechat_read_article", arguments: ["url": url])
            let summary = try await aiService.summarize(article: article)
            let fileURL = try saveToKnowledgeBase(summary, title: article.title)
            MemoryService.shared.recordFileInteraction(path: fileURL.path, text: summary)
            results.append(BatchWechatSummaryResult(url: url, title: article.title, savedURL: fileURL, error: nil))
        } catch {
            results.append(BatchWechatSummaryResult(url: url, title: "", savedURL: nil, error: error))
        }
    }
    
    return results
}
```

#### 产品形态建议

1. **批量输入框**：AI 侧边栏新增多行文本框，提示“每行粘贴一个公众号文章链接”。
2. **自动识别**：即使用户从微信聊天记录复制了一大段文字，也能正则提取出所有 `mp.weixin.qq.com/s/...` 链接。
3. **进度反馈**：显示 `正在总结 3/10...`，并允许取消。
4. **结果面板**：批量处理完成后，列出每篇文章的标题、保存路径、成功/失败状态；失败的可单独重试。
5. **反爬保护**：
   - 默认串行调用，间隔 1–3 秒；
   - 当 MCP Server 返回 `rate_limited` 或 `captcha_required` 时自动暂停并提示用户。
6. **合并模式（可选）**：除了每篇单独保存，还可提供“合并为一份主题笔记”选项，由 LLM 先分别总结，再生成一份跨文章的综合知识卡片。

### 4.4 微信收藏的折中方案

由于无官方 API，建议采用“用户主动转发”模式：

1. 用户在微信中看到想收藏的文章，点击“复制链接”。
2. 回到 TechMarkdown，粘贴链接到“公众号文章总结”输入框。
3. 或者：用户把链接发送给 TechMarkdown 的某种“接收端”（如本地 HTTP 服务、剪贴板监听）。

若未来“狍子AI”或微信开放收藏 API，再升级为自动同步。

---

## 5. 风险与注意事项

| 风险 | 说明 | 缓解措施 |
|---|---|---|
| **微信反爬 / 验证码** | 频繁抓取可能触发风控 | 使用 wechat-reader 的浏览器复用模式、降低频率、提示用户手动验证 |
| **URL 失效 / 文章删除** | 原链接可能 404 | 抓取后立即本地保存原始 Markdown |
| **版权与隐私** | 抓取他人文章需遵守微信规范 | 仅用于个人知识管理，不对外发布；支持用户自有公众号后台 API |
| **MCP Server 稳定性** | 第三方项目更新不及时 | 本地部署、固定版本、做好 fallback（提示用户手动粘贴正文） |
| **收藏夹无 API** | 无法自动批量导入 | 引导用户手动转发/复制链接；关注腾讯官方工具动态 |

---

## 6. 推荐选型

| 场景 | 推荐 MCP Server | 理由 |
|---|---|---|
| **用户粘贴公众号文章链接 → 总结为知识文档** | **wechat-reader** | 复用真实浏览器会话，结构化状态，稳定性最好 |
| **快速原型 / 不依赖浏览器** | **guanshilong/mcp** | 部署简单，HTTP 接口直接可用 |
| **按关键词搜索公众号文章** | **weixin-search-mcp** | 无需登录，但需处理反爬 |
| **批量导入微信收藏夹** | 暂无稳定方案 | 建议等待“狍子AI”或采用手动转发 |

---

## 7. 下一步行动建议

1. **短期**：在 TechMarkdown 中接入 `wechat-reader` MCP，实现“粘贴公众号链接 → 抓取 → LLM 总结 → 保存为本地 Markdown”的 MVP。
2. **中期**：将总结结果与 `MemoryService` 深度整合，支持按文章标题/标签检索。
3. **长期**：关注微信生态开放动态，一旦收藏夹 API 或“狍子AI”开放，升级为一键同步收藏夹。
