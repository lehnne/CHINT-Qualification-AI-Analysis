# 任职资格平台查询 SQL 手册

> 数据库：SQL Server（T-SQL）
> 共 4 张核心表

---

## 表结构说明

| 表名 | 说明 | 核心字段 |
|------|------|---------|
| `TB_ZC_Post` | 岗位基础信息表（码表） | PostCode(岗位代号), PostName(岗位名称) |
| `TB_ZC_ReviewApply` | 职称申报申请表头 | RACode(申报编号), RNCode(评审活动ID), EmplySFCode(工号), PostCode(岗位序列代码), LevCode(申报职级), ReviewLevel(审批结果), Status(状态: 4=通过/5=不通过) |
| `TB_ZC_EmplyOtherInfo` | 人员其他信息表 | EmplySFCode(工号), EmplyName(姓名), PostLev(职级) |
| `TB_ZC_WorkProduct` | 关键成果表 | EmplySFCode(集团工号), KeyEvents(关键事件), EventDes(事件描述), WorkAchievements(工作成果), Skill(专业能力), TypeRole(所扮角色) |
| `TB_ZC_ProjectInfo` | 主导或参与项目情况表 | EmplySFCode(集团工号), ProjectName(项目名称), ProjectDesc(项目介绍), ProjectRole(项目角色), ProjectResult(项目贡献度描述) |

---

## 一、合并接口（推荐）

**用途**：一次性拉取某个评审活动（可选）下所有申报人员 + 关键成果 + 项目信息，Pipeline 不用循环调用。

**接口**：`GET /api/v1/assessments/materials-by-activity`

**筛选条件说明**：
- `@RNCode` — **评审活动ID**（可选），不填则查所有评审活动
- `@PostCode` — 岗位序列代码（可选），不填则查所有岗位序列
- `@LevCode` — 职级代码（可选），不填则查所有职级
- `@PageSize` — 每页行数（必须 > 0）
- `@start` — 偏移量（第一页为 0）

```sql
-- ============================================================
-- 合并接口：根据评审活动+岗位序列+职级查询所有申报人员及申报材料
-- 接口：GET /api/v1/assessments/materials-by-activity
-- 用途：Pipeline 一次性拉取，用于标签分析
-- 数据库：SQL Server（需 2012+ 支持 OFFSET FETCH）
-- ============================================================

DECLARE @RNCode   NVARCHAR(20) = NULL;               -- 评审活动ID（NULL=全部活动）
DECLARE @PostCode NVARCHAR(20) = NULL;                -- 岗位序列代码（NULL=全部序列）
DECLARE @LevCode  NVARCHAR(10) = NULL;                -- 职级代码（NULL=全部职级）
DECLARE @PageSize INT = 100;                          -- 每页行数
DECLARE @start    INT = 0;                            -- 偏移量（第一页为0）

-- 查询总行数（分页用）
SELECT COUNT(*) AS total_rows
FROM (
    SELECT R.EmplySFCode
    FROM TB_ZC_ReviewApply R
    WHERE R.Status IN (4, 5)
      AND (@RNCode IS NULL OR R.RNCode = @RNCode)
      AND (@PostCode IS NULL OR R.PostCode = @PostCode)
      AND (@LevCode IS NULL OR R.LevCode = @LevCode)
      AND R.Deleted = 0
) AS base;

-- 分页查询主数据
SELECT 
    R.RNCode              AS assessment_activity_id,
    R.RACode              AS assessment_id,
    R.EmplySFCode         AS employee_id,
    E.EmplyName           AS employee_name,
    R.OldPostName         AS original_position,
    R.OldPostLev          AS original_grade,
    R.PostCode            AS position_family_code,
    PT.PostName           AS position_family_name,
    R.LevCode             AS target_grade,
    R.RADate              AS assessment_date,
    R.ReviewLevel         AS result,
    R.Status              AS status,
    N'关键成果'            AS material_type,
    W.Id                  AS material_id,
    W.KeyEvents           AS title,
    W.EventDes            AS description,
    W.WorkAchievements    AS quantified_results,
    W.Skill               AS skill,
    W.TypeRole            AS role
FROM TB_ZC_ReviewApply R
LEFT JOIN TB_ZC_EmplyOtherInfo E 
    ON R.EmplySFCode = E.EmplySFCode AND E.Deleted = 0
LEFT JOIN TB_ZC_Post PT
    ON R.PostCode = PT.PostCode AND PT.Deleted = 0
LEFT JOIN TB_ZC_WorkProduct W 
    ON R.EmplySFCode = W.EmplySFCode AND W.Deleted = 0
WHERE R.Status IN (4, 5)
  AND (@RNCode IS NULL OR R.RNCode = @RNCode)
  AND (@PostCode IS NULL OR R.PostCode = @PostCode)
  AND (@LevCode IS NULL OR R.LevCode = @LevCode)
  AND R.Deleted = 0

UNION ALL

SELECT 
    R.RNCode              AS assessment_activity_id,
    R.RACode              AS assessment_id,
    R.EmplySFCode         AS employee_id,
    E.EmplyName           AS employee_name,
    R.OldPostName         AS original_position,
    R.OldPostLev          AS original_grade,
    R.PostCode            AS position_family_code,
    PT.PostName           AS position_family_name,
    R.LevCode             AS target_grade,
    R.RADate              AS assessment_date,
    R.ReviewLevel         AS result,
    R.Status              AS status,
    N'项目经历'            AS material_type,
    P.Id                  AS material_id,
    P.ProjectName         AS title,
    P.ProjectDesc         AS description,
    P.ProjectResult       AS quantified_results,
    NULL                  AS skill,
    P.ProjectRole         AS role
FROM TB_ZC_ReviewApply R
LEFT JOIN TB_ZC_EmplyOtherInfo E 
    ON R.EmplySFCode = E.EmplySFCode AND E.Deleted = 0
LEFT JOIN TB_ZC_Post PT
    ON R.PostCode = PT.PostCode AND PT.Deleted = 0
LEFT JOIN TB_ZC_ProjectInfo P 
    ON R.EmplySFCode = P.EmplySFCode AND P.Deleted = 0
WHERE R.Status IN (4, 5)
  AND (@RNCode IS NULL OR R.RNCode = @RNCode)
  AND (@PostCode IS NULL OR R.PostCode = @PostCode)
  AND (@LevCode IS NULL OR R.LevCode = @LevCode)
  AND R.Deleted = 0
ORDER BY employee_id, material_type, material_id
OFFSET @start ROWS
FETCH NEXT @PageSize ROWS ONLY;
```

---

## 二、评审汇总接口

**用途**：返回"在一个评审活动+岗位序列+职级下，谁过了、谁没过"，Pipeline 用这个分组计算金标签的 D 系数。

**接口**：`GET /api/v1/assessments/summary`

```sql
-- ============================================================
-- 评审汇总：拉取某评审活动+岗位序列+职级的评审结果分组
-- 接口：GET /api/v1/assessments/summary
-- 数据库：SQL Server
-- ============================================================

DECLARE @RNCode   NVARCHAR(20) = NULL;                -- 评审活动ID（NULL=全部活动）
DECLARE @PostCode NVARCHAR(20) = 'DYJS15';
DECLARE @LevCode  NVARCHAR(10) = 'P6';
DECLARE @PageSize INT = 200;
DECLARE @start    INT = 0;

-- 查询总行数
SELECT COUNT(*) AS total_rows
FROM TB_ZC_ReviewApply R
WHERE R.Status IN (4, 5)
  AND (@RNCode IS NULL OR R.RNCode = @RNCode)
  AND R.PostCode = @PostCode
  AND R.LevCode = @LevCode
  AND R.Deleted = 0;

-- 分页查询
SELECT 
    R.EmplySFCode         AS employee_id,
    E.EmplyName           AS employee_name,
    R.ReviewLevel         AS result,
    CASE 
        WHEN R.ReviewLevel = N'审核通过' THEN N'passed'
        ELSE N'failed'
    END AS result_code
FROM TB_ZC_ReviewApply R
LEFT JOIN TB_ZC_EmplyOtherInfo E 
    ON R.EmplySFCode = E.EmplySFCode AND E.Deleted = 0
WHERE R.Status IN (4, 5)
  AND (@RNCode IS NULL OR R.RNCode = @RNCode)
  AND R.PostCode = @PostCode
  AND R.LevCode = @LevCode
  AND R.Deleted = 0
ORDER BY R.EmplySFCode
OFFSET @start ROWS
FETCH NEXT @PageSize ROWS ONLY;
```

---

## 三、增量更新版本（可选）

**用途**：如果评审是滚动进行的，每天只处理当天有变更的评审记录。

**接口**：`GET /api/v1/assessments/latest`

```sql
-- ============================================================
-- 增量版本：只拉取指定评审活动中当天有变更的记录
-- 接口：GET /api/v1/assessments/latest
-- 数据库：SQL Server
-- ============================================================

DECLARE @RNCode       NVARCHAR(20) = NULL;                -- 评审活动ID（NULL=全部活动）
DECLARE @UpdatedAfter NVARCHAR(20) = '2025-07-01';
DECLARE @PageSize     INT = 100;
DECLARE @start        INT = 0;

-- 查询总行数
SELECT COUNT(*) AS total_rows
FROM TB_ZC_ReviewApply R
WHERE R.Status IN (4, 5)
  AND (@RNCode IS NULL OR R.RNCode = @RNCode)
  AND R.UpdatedDate > @UpdatedAfter
  AND R.Deleted = 0;

-- 分页查询
SELECT DISTINCT
    R.RACode              AS assessment_id,
    R.EmplySFCode         AS employee_id,
    E.EmplyName           AS employee_name,
    R.PostCode            AS position_family_code,
    R.LevCode             AS target_grade,
    R.ReviewLevel         AS result,
    R.UpdatedDate         AS updated_at
FROM TB_ZC_ReviewApply R
LEFT JOIN TB_ZC_EmplyOtherInfo E 
    ON R.EmplySFCode = E.EmplySFCode AND E.Deleted = 0
WHERE R.Status IN (4, 5)
  AND (@RNCode IS NULL OR R.RNCode = @RNCode)
  AND R.UpdatedDate > @UpdatedAfter
  AND R.Deleted = 0
ORDER BY R.UpdatedDate ASC
OFFSET @start ROWS
FETCH NEXT @PageSize ROWS ONLY;
```

---

## 附：字段映射说明

| 接口返回字段 | 对应数据库表字段 | 说明 |
|-------------|----------------|------|
| `assessment_activity_id` | `TB_ZC_ReviewApply.RNCode` | 评审活动ID |
| `assessment_id` | `TB_ZC_ReviewApply.RACode` | 个人申报编号 |
| `employee_id` | `TB_ZC_ReviewApply.EmplySFCode` | 员工工号 |
| `employee_name` | `TB_ZC_EmplyOtherInfo.EmplyName` | 员工姓名 |
| `position_family_code` | `TB_ZC_ReviewApply.PostCode` | 岗位序列代码 |
| `position_family_name` | `TB_ZC_Post.PostName`（LEFT JOIN TB_ZC_ReviewApply.PostCode） | 岗位序列名称 |
| `target_grade` | `TB_ZC_ReviewApply.LevCode` | 申报职级 |
| `result` | `TB_ZC_ReviewApply.ReviewLevel` | 审批结果：审核通过/审核不通过 |
| `status` | `TB_ZC_ReviewApply.Status` | 状态码：4=通过，5=不通过 |
| `original_position` | `TB_ZC_ReviewApply.OldPostName` | 当前岗位 |
| `original_grade` | `TB_ZC_ReviewApply.OldPostLev` | 原职级 |
| `title` | `TB_ZC_WorkProduct.KeyEvents` / `TB_ZC_ProjectInfo.ProjectName` | 材料标题 |
| `description` | `TB_ZC_WorkProduct.EventDes` / `TB_ZC_ProjectInfo.ProjectDesc` | 材料描述 |
| `quantified_results` | `TB_ZC_WorkProduct.WorkAchievements` / `TB_ZC_ProjectInfo.ProjectResult` | 量化成果 |
| `role` | `TB_ZC_WorkProduct.TypeRole` / `TB_ZC_ProjectInfo.ProjectRole` | 所扮角色 |
| `skill` | `TB_ZC_WorkProduct.Skill` | 专业能力（仅关键成果表有） |