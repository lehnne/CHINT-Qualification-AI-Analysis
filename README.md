# CHINT 任职资格 AI 分析

> 基于飞书 Aily 平台的任职资格智能分析系统设计方案

## 项目概述

本项目旨在对任职资格平台中每个人的关键成果和项目经历进行 AI 分析，生成能力标签、金标签，并诊断个人能力短板。

## 文件说明

| 文件 | 说明 |
|------|------|
| `qualification-ai-analysis.html` | 完整设计文档（11 章节，含架构设计、Prompt 设计、MCP 工具设计、数据库设计、接口规范等） |
| `任职资格平台查询SQL手册.md` | 任职资格平台查询 SQL 手册（SQL Server T-SQL 语法） |
| `智能体Prompt-标签生成Agent.md` | 能力标签生成 Agent 的完整提示词 |
| `项目交接文档.md` | 项目交接文档 |

## 技术栈

- **平台**：飞书 Aily（智能体 + 知识库 + 工作流 + MCP）
- **数据库**：SQL Server（任职资格平台）+ PostgreSQL（AI 分析系统，含 pgvector）
- **Prompt 技术**：ReAct、Plan-and-Execute、Chain-of-Thought、Self-Consistency
- **MCP 工具**：query_assessment_materials、get_dimension_schema 等

## 核心设计

### 双轨架构

1. **预生成 Pipeline**：定期批量分析，生成能力标签和金标签
2. **实时 HR Agent**：HR 对话时实时调用，基于预生成数据回答问题

### 标签提取逻辑

- 个人能力标签：按 **人员 + 岗位序列 + 原职级** 分组提取
- 金标签：按 **岗位序列 + 职级 + 维度** 分组，通过 D 系数识别优秀人员共性能力

### 维度体系

不同岗位序列有不同的能力维度，例如：

| 岗位序列 | 能力维度 |
|---------|---------|
| 技术研发类 | 技术专长、技术创新、客户导向、知识技能 |
| 产品类 | 产品规划、用户洞察、数据分析、项目推进 |
| 设计类 | 设计执行、创意表达、用户研究、协作沟通 |

## License

Private - Internal Use Only
