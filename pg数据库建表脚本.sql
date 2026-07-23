-- ============================================================
-- 任职资格 AI 分析系统 · PostgreSQL 数据库建表脚本
-- 数据库：PostgreSQL（需开启 pgvector 扩展用于向量检索）
-- 共 5 张表：batch_upload_log / employee_capability_tags / gold_tags
--           position_benchmarks / dimension_schema
-- ============================================================

-- 扩展：向量相似度搜索（用于后续标签匹配，非必须）
-- CREATE EXTENSION IF NOT EXISTS vector;

-- ============================================================
-- 表0：batch_upload_log（批次原始数据归档）
-- 用途：存储每次写入的完整原始 JSON 请求体，用于审计、追溯和重跑
--       MCP 写入时，先存原始 JSON，再解析转存到具体业务表
-- 核心查询：按 batch_id 检索某次写入的原始数据
-- ============================================================
CREATE TABLE batch_upload_log (
    id                  BIGSERIAL       PRIMARY KEY,
    raw_json            TEXT            NOT NULL,       -- 完整的原始 JSON 请求体字符串（未转义前的原始内容），数据中台直接写入此字段
    status              VARCHAR(20)     NOT NULL        DEFAULT 'pending',  -- 处理状态：pending / processing / success / failed
    batch_id            VARCHAR(50),                   -- 批次ID，如 BATCH_20250714_0001（解析时回填）
    assessment_cycle    VARCHAR(20),                   -- 评审周期，如 2025-H1（解析时回填）
    mode                VARCHAR(20),                   -- 写入模式：initial / incremental（解析时回填）
    error_message       TEXT,                          -- 处理失败时的错误信息
    employee_count      INT             DEFAULT 0,     -- 本批次包含的员工数，解析后回填
    tag_count           INT             DEFAULT 0,     -- 本批次生成的标签总数，解析后回填
    created_at          TIMESTAMP     DEFAULT NOW()  -- 写入时间

    -- 没有唯一约束，同一个 batch_id 可能重跑多次，每次都会有一条记录
);

CREATE INDEX idx_batch_log_batch   ON batch_upload_log (batch_id);
CREATE INDEX idx_batch_log_cycle   ON batch_upload_log (assessment_cycle DESC);
CREATE INDEX idx_batch_log_status  ON batch_upload_log (status);

COMMENT ON TABLE  batch_upload_log           IS '中间表（批次原始数据归档）：数据中台直接写入原始JSON，触发器自动解析metadata回填，解析转存过程从中读取并转存到业务表';
COMMENT ON COLUMN batch_upload_log.id                IS '自增主键，无业务含义';
COMMENT ON COLUMN batch_upload_log.batch_id          IS '批次ID，格式BATCH_YYYYMMDD_HHMM，触发器自动从raw_json解析回填，用于标识一次写入操作';
COMMENT ON COLUMN batch_upload_log.assessment_cycle  IS '评审周期，如2025-H1，触发器自动从raw_json解析回填，冗余存储方便按周期检索';
COMMENT ON COLUMN batch_upload_log.mode              IS '写入模式：initial（首次全量）/ incremental（增量按人覆盖），触发器自动从raw_json解析回填';
COMMENT ON COLUMN batch_upload_log.raw_json           IS '完整的原始JSON请求体，MCP传入的request_body字符串，数据中台直接写入此字段，含所有员工标签数据';
COMMENT ON COLUMN batch_upload_log.status            IS '处理状态：pending=待处理/processing=处理中/success=成功/failed=失败';
COMMENT ON COLUMN batch_upload_log.error_message      IS '处理失败时的错误信息，用于排查问题';
COMMENT ON COLUMN batch_upload_log.employee_count     IS '本批次包含的员工人数，解析后回填';
COMMENT ON COLUMN batch_upload_log.tag_count          IS '本批次生成的标签总数，解析后回填';
COMMENT ON COLUMN batch_upload_log.created_at         IS '记录创建时间，即中台收到请求的时间';

-- ============================================================
-- 触发器：自动从 raw_json 解析元数据字段
-- 说明：BEFORE INSERT，在数据写入前自动解析 raw_json 中的
--       batch_id、assessment_cycle、mode 三个字段并回填
--       这样数据中台只需 INSERT raw_json，其他字段自动补全
-- ============================================================
CREATE OR REPLACE FUNCTION parse_batch_upload_metadata()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_json     JSONB;
    v_tag_elem JSONB;
    v_dim_key  TEXT;
BEGIN
    -- 只有当 raw_json 有值且元数据字段为空时才解析
    IF NEW.raw_json IS NOT NULL AND NEW.batch_id IS NULL THEN
        BEGIN
            v_json := REPLACE(NEW.raw_json, '\"', '"')::JSONB;

            -- 提取元数据字段
            NEW.batch_id        := v_json ->> 'batch_id';
            NEW.assessment_cycle := v_json ->> 'assessment_cycle';
            NEW.mode             := v_json ->> 'mode';

            -- 统计人员总数和标签总数
            NEW.employee_count := 0;
            NEW.tag_count := 0;

            IF v_json ? 'tags' AND jsonb_typeof(v_json -> 'tags') = 'array' THEN
                NEW.employee_count := jsonb_array_length(v_json -> 'tags');

                FOR v_tag_elem IN SELECT * FROM jsonb_array_elements(v_json -> 'tags')
                LOOP
                    IF v_tag_elem ? 'dimension_tags' AND jsonb_typeof(v_tag_elem -> 'dimension_tags') = 'object' THEN
                        FOR v_dim_key IN SELECT * FROM jsonb_object_keys(v_tag_elem -> 'dimension_tags')
                        LOOP
                            IF jsonb_typeof(v_tag_elem -> 'dimension_tags' -> v_dim_key) = 'array' THEN
                                NEW.tag_count := NEW.tag_count + jsonb_array_length(
                                    v_tag_elem -> 'dimension_tags' -> v_dim_key
                                );
                            END IF;
                        END LOOP;
                    END IF;
                END LOOP;
            END IF;

        EXCEPTION
            WHEN OTHERS THEN
                -- 解析失败不阻断插入，标记状态为 failed
                NEW.status := 'failed';
                NEW.error_message := '触发器解析raw_json失败: ' || SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_batch_upload_parse_metadata
    BEFORE INSERT ON batch_upload_log
    FOR EACH ROW
    EXECUTE FUNCTION parse_batch_upload_metadata();

-- ============================================================
-- 触发器：自动将 tag 内容转存到员工标签表
-- 说明：AFTER INSERT，在数据写入后自动解析 raw_json 中的 tags
--       遍历人员→维度→标签，将展平后的数据写入 employee_capability_tags
--       按 mode 策略处理旧数据（initial=清空整周期，incremental=按人覆盖）
-- ============================================================
CREATE OR REPLACE FUNCTION process_batch_upload_trigger()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_payload         JSONB;
    v_batch_id        VARCHAR(50);
    v_assessment_cycle VARCHAR(20);
    v_mode             VARCHAR(20);
    v_emp_rec          RECORD;
    v_dim_key          TEXT;
    v_tag_rec          RECORD;
    v_employee_count   INT := 0;
    v_tag_count        INT := 0;
BEGIN
    -- 只处理 status = 'pending' 的记录
    IF NEW.status = 'pending' THEN
        v_payload := REPLACE(NEW.raw_json, '\"', '"')::JSONB;

        v_batch_id        := v_payload ->> 'batch_id';
        v_assessment_cycle := v_payload ->> 'assessment_cycle';
        v_mode             := v_payload ->> 'mode';

        -- 更新状态为 processing
        UPDATE batch_upload_log SET status = 'processing' WHERE id = NEW.id;

        -- mode = 'initial'：清空整个评审周期的旧数据
        IF v_mode = 'initial' THEN
            DELETE FROM employee_capability_tags
            WHERE assessment_cycle = v_assessment_cycle;
        END IF;

        -- 遍历 tags 数组，解析转存
        FOR v_emp_rec IN
            SELECT * FROM JSONB_TO_RECORDSET(v_payload -> 'tags')
              AS x(
                  employee_id          VARCHAR(50),
                  employee_name        VARCHAR(50),
                  position_family_code VARCHAR(20),
                  position_family_name VARCHAR(50),
                  original_position    VARCHAR(100),
                  original_grade       VARCHAR(20),
                  target_grade         VARCHAR(20),
                  dimension_tags       JSONB
              )
        LOOP
            v_employee_count := v_employee_count + 1;

            -- 对每个人，先删掉该评审周期下的旧标签，再插新的
            IF v_mode = 'incremental' THEN
                DELETE FROM employee_capability_tags
                WHERE employee_id = v_emp_rec.employee_id
                  AND assessment_cycle = v_assessment_cycle;
            END IF;

            -- 遍历 dimension_tags 的每个维度
            FOR v_dim_key IN
                SELECT JSONB_OBJECT_KEYS(v_emp_rec.dimension_tags)
            LOOP
                -- 遍历该维度下的标签数组
                FOR v_tag_rec IN
                    SELECT * FROM JSONB_TO_RECORDSET(
                        v_emp_rec.dimension_tags -> v_dim_key
                    ) AS y(
                        tag_name         VARCHAR(100),
                        score            SMALLINT,
                        confidence       DECIMAL(3,2),
                        evidence         TEXT,
                        source_materials JSONB
                    )
                LOOP
                    v_tag_count := v_tag_count + 1;

                    INSERT INTO employee_capability_tags (
                        employee_id,          employee_name,
                        position_family_code, position_family_name,
                        original_position,    original_grade,
                        target_grade,         assessment_cycle,
                        dimension,            tag_name,
                        score,                confidence,
                        evidence,             source_materials,
                        batch_id,             created_at,
                        updated_at
                    ) VALUES (
                        v_emp_rec.employee_id,          v_emp_rec.employee_name,
                        v_emp_rec.position_family_code, v_emp_rec.position_family_name,
                        v_emp_rec.original_position,    v_emp_rec.original_grade,
                        v_emp_rec.target_grade,         v_assessment_cycle,
                        v_dim_key,                      v_tag_rec.tag_name,
                        v_tag_rec.score,                v_tag_rec.confidence,
                        v_tag_rec.evidence,             v_tag_rec.source_materials,
                        v_batch_id,                     NOW(),
                        NOW()
                    );
                END LOOP;
            END LOOP;
        END LOOP;

        -- 更新成功状态及统计
        UPDATE batch_upload_log
        SET status = 'success',
            employee_count = v_employee_count,
            tag_count = v_tag_count
        WHERE id = NEW.id;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_batch_upload_process_tags
    AFTER INSERT ON batch_upload_log
    FOR EACH ROW
    EXECUTE FUNCTION process_batch_upload_trigger();


-- 功能索引（用于写入函数中的 DELETE 操作，按 employee_id + assessment_cycle 快速定位）
CREATE INDEX IF NOT EXISTS idx_emp_tags_delete
    ON employee_capability_tags (employee_id, assessment_cycle);

-- 排序索引（用于按评审周期倒序查询最新标签）
CREATE INDEX IF NOT EXISTS idx_emp_tags_cycle
    ON employee_capability_tags (assessment_cycle DESC);

-- ============================================================
-- 表1：employee_capability_tags（个人能力标签）
-- 用途：存储每个人在每次评审中，每个维度下的能力标签。
--       每行 = 一个人在某次评审中，某个维度下的一个标签。
--       如张三在"技术专长"维度下有"架构设计"和"高并发优化"两个标签，就占两行。
-- 核心查询：按 employee_id + assessment_cycle 检索个人全部标签
-- ============================================================
CREATE TABLE employee_capability_tags (
    id                  BIGSERIAL       PRIMARY KEY,
    employee_id         VARCHAR(50)     NOT NULL,       -- 员工工号，来自任职资格平台
    employee_name       VARCHAR(50)     NOT NULL,       -- 员工姓名（冗余字段，方便查询和展示，避免联表）
    position_family_code VARCHAR(20)    NOT NULL,       -- 岗位序列代码（如：DYJS15），对应任职资格平台码表 PostCode
    position_family_name VARCHAR(50)    NOT NULL,       -- 岗位序列名称（如：技术研发类），对应任职资格平台码表 PostName
    original_position   VARCHAR(100)    NOT NULL,       -- 原岗位名称（如：后端开发工程师）
    original_grade      VARCHAR(20)     NOT NULL,       -- 原职级（如：P5），对应 TB_ZC_ReviewApply.OldPostLev
    target_grade        VARCHAR(20)     NOT NULL,       -- 申报目标职级（如：P6）
    assessment_cycle    VARCHAR(20)     NOT NULL,       -- 评审周期标识（如：2025-H1），用于区分不同周期的评审
    dimension           VARCHAR(50)     NOT NULL,       -- 能力维度名称（如：技术专长、技术创新、客户导向、知识技能）
    tag_name            VARCHAR(100)    NOT NULL,       -- 能力标签名称（如：复杂架构设计、高并发优化）
    score               SMALLINT        NOT NULL CHECK (score >= 0 AND score <= 100),  -- 标签得分 0-100，基于材料中的量化成果和角色重要性综合评定
    confidence          DECIMAL(3,2),                  -- 置信度 0.00-1.00，描述越具体、量化越清楚则置信度越高
    evidence            TEXT,                          -- 生成该标签的依据摘要（来自具体材料中的哪段描述）
    source_materials    JSONB,                         -- 支撑该标签的材料ID列表，格式：["MAT_001","MAT_002"]
    batch_id            VARCHAR(50)     NOT NULL,       -- 写入批次ID，用于追溯本次Pipeline的运行批次
    created_at          TIMESTAMP     DEFAULT NOW(), -- 创建时间
    updated_at          TIMESTAMP     DEFAULT NOW(), -- 更新时间

    -- 唯一约束：同一人同一评审周期同一维度下，标签名称唯一，确保UPSERT幂等
    UNIQUE (employee_id, assessment_cycle, dimension, tag_name)
);

COMMENT ON TABLE  employee_capability_tags IS '个人能力标签表：存储每个人在每次评审中各维度下的能力标签，每行=人员+评审周期+维度下的一个标签';
COMMENT ON COLUMN employee_capability_tags.id                  IS '自增主键，无业务含义';
COMMENT ON COLUMN employee_capability_tags.employee_id         IS '员工工号，来自任职资格平台TB_ZC_ReviewApply.EmplySFCode';
COMMENT ON COLUMN employee_capability_tags.employee_name       IS '员工姓名，冗余存储避免查询时联表';
COMMENT ON COLUMN employee_capability_tags.position_family_code IS '岗位序列代码，如DYJS15，对应任职资格平台TB_ZC_ReviewApply.PostCode码表';
COMMENT ON COLUMN employee_capability_tags.position_family_name IS '岗位序列名称，如技术研发类/产品类/设计类，对应任职资格平台TB_ZC_ReviewApply.PostName';
COMMENT ON COLUMN employee_capability_tags.original_position   IS '原岗位名称，如后端开发工程师、产品经理等';
COMMENT ON COLUMN employee_capability_tags.original_grade      IS '原职级，如P5/P6/P7，对应TB_ZC_ReviewApply.OldPostLev';
COMMENT ON COLUMN employee_capability_tags.target_grade        IS '申报目标职级，如P5/P6/P7，代表本次评审的目标等级';
COMMENT ON COLUMN employee_capability_tags.assessment_cycle    IS '评审周期标识，如2025-H1，用于区分不同周期的评审数据';
COMMENT ON COLUMN employee_capability_tags.dimension           IS '能力维度，与dimension_schema中定义一致，如技术专长/技术创新';
COMMENT ON COLUMN employee_capability_tags.tag_name            IS '能力标签名称，要求具体而非泛泛，如"复杂架构设计"而非"技术能力强"';
COMMENT ON COLUMN employee_capability_tags.score               IS '标签得分0-100，基于材料量化成果和角色重要性综合评定';
COMMENT ON COLUMN employee_capability_tags.confidence           IS '置信度0.00-1.00，材料描述越具体量化越清楚则置信度越高';
COMMENT ON COLUMN employee_capability_tags.evidence            IS '生成该标签的依据摘要，来自具体材料的原始描述';
COMMENT ON COLUMN employee_capability_tags.source_materials    IS '支撑该标签的材料ID列表JSON数组，如["MAT_001","MAT_002"]';
COMMENT ON COLUMN employee_capability_tags.batch_id            IS '写入批次ID，格式BATCH_YYYYMMDD_HHMM，用于追溯Pipeline运行记录';
COMMENT ON COLUMN employee_capability_tags.created_at          IS '记录创建时间，自动生成';
COMMENT ON COLUMN employee_capability_tags.updated_at          IS '记录更新时间，自动生成';


-- ============================================================
-- 表2：gold_tags（金标签库）
-- 用途：存储按岗位序列+职级+维度聚合计算出的金标签。
--       Pipeline从employee_capability_tags中聚合计算，
--       按"通过组"和"未通过组"分别统计每个标签的平均分，算出D系数。
--       每行 = 一个岗位序列+职级+维度下的一个金标签。
-- 核心查询：按 position_family_code + grade + dimension 检索某岗位层级下的金标签
-- ============================================================
CREATE TABLE gold_tags (
    id                  BIGSERIAL       PRIMARY KEY,
    position_family_code VARCHAR(20)    NOT NULL,       -- 岗位序列代码（如：DYJS15）
    position_family_name VARCHAR(50)    NOT NULL,       -- 岗位序列名称（如：技术研发类）
    grade               VARCHAR(20)     NOT NULL,       -- 职级（如：P6）
    dimension           VARCHAR(50)     NOT NULL,       -- 能力维度（如：技术专长）
    tag_name            VARCHAR(100)    NOT NULL,       -- 金标签名称（如：复杂架构设计）
    distinction_coef    DECIMAL(5,3)    NOT NULL,       -- D系数 = (通过组均分 - 未通过组均分) / 未通过组均分，衡量区分度
    penetration_rate    DECIMAL(4,3)    NOT NULL,       -- P系数 = 通过组中持有该标签的人数 / 通过组总人数，衡量穿透率
    avg_score_passed    DECIMAL(5,2)    NOT NULL,       -- 通过组在该标签上的平均得分
    avg_score_failed    DECIMAL(5,2)    NOT NULL,       -- 未通过组在该标签上的平均得分
    passed_count        INT             NOT NULL,       -- 通过组中有该标签的人数
    failed_count        INT             NOT NULL,       -- 未通过组中有该标签的人数
    is_core             BOOLEAN         DEFAULT FALSE,  -- 是否核心金标签（判定条件：D≥0.30 且 P≥0.50）
    is_verified         BOOLEAN         DEFAULT FALSE,  -- HRBP是否已人工确认此金标签生效
    batch_id            VARCHAR(50)     NOT NULL,       -- 写入批次ID，用于追溯Pipeline运行记录
    updated_at          TIMESTAMP     DEFAULT NOW(), -- 更新时间

    -- 唯一约束：同一岗位序列+职级+维度+标签名，不会重复
    UNIQUE (position_family_code, grade, dimension, tag_name)
);

COMMENT ON TABLE  gold_tags IS '金标签库：按岗位序列+职级+维度聚合计算的金标签，通过D系数和P系数识别区分通过/未通过的关键能力';
COMMENT ON COLUMN gold_tags.id                  IS '自增主键，无业务含义';
COMMENT ON COLUMN gold_tags.position_family_code IS '岗位序列代码，如DYJS15，对应任职资格平台码表PostCode';
COMMENT ON COLUMN gold_tags.position_family_name IS '岗位序列名称，如技术研发类/产品类/设计类，冗余存储方便展示';
COMMENT ON COLUMN gold_tags.grade               IS '职级，如P5/P6/P7，金标签按岗位序列+职级分组计算';
COMMENT ON COLUMN gold_tags.dimension           IS '能力维度，金标签在每个维度下独立计算，如技术专长维度下的金标签';
COMMENT ON COLUMN gold_tags.tag_name            IS '金标签名称，与employee_capability_tags中的tag_name对应';
COMMENT ON COLUMN gold_tags.distinction_coef    IS 'D系数区分度=(通过组均分-未通过组均分)/未通过组均分，D>0.25有区分意义';
COMMENT ON COLUMN gold_tags.penetration_rate    IS 'P系数穿透率=通过组持有该标签人数/通过组总人数，P>0.6表示该标签在通过组中普遍存在';
COMMENT ON COLUMN gold_tags.avg_score_passed    IS '通过组在该标签上的平均得分，用于计算D系数和判断标签水平';
COMMENT ON COLUMN gold_tags.avg_score_failed    IS '未通过组在该标签上的平均得分，用于计算D系数';
COMMENT ON COLUMN gold_tags.passed_count        IS '通过组中有该标签的人数，用于计算P系数和统计校验';
COMMENT ON COLUMN gold_tags.failed_count        IS '未通过组中有该标签的人数，用于统计校验';
COMMENT ON COLUMN gold_tags.is_core             IS '是否核心金标签，D≥0.30且P≥0.50标记为核心金标签，更具参考价值';
COMMENT ON COLUMN gold_tags.is_verified         IS 'HRBP是否已人工确认，金标签生成后需HRBP审核确认才能正式生效使用';
COMMENT ON COLUMN gold_tags.batch_id            IS '写入批次ID，格式BATCH_YYYYMMDD_HHMM，用于追溯Pipeline运行记录';
COMMENT ON COLUMN gold_tags.updated_at          IS '更新时间，每次Pipeline全量覆盖时更新';


-- ============================================================
-- 表3：position_benchmarks（岗位基准画像）
-- 用途：存储每个岗位序列+职级下各维度标签的统计分布。
--       用于劣势诊断时回答"张三的架构设计得分88，在同岗位序列同职级中处于什么水平？"
--       每行 = 一个岗位序列+职级+维度下某个标签的统计分布。
-- 核心查询：按 position_family_code + grade + dimension 检索某岗位层级的基准画像
-- ============================================================
CREATE TABLE position_benchmarks (
    id                  BIGSERIAL       PRIMARY KEY,
    position_family_code VARCHAR(20)    NOT NULL,       -- 岗位序列代码（如：DYJS15）
    position_family_name VARCHAR(50)    NOT NULL,       -- 岗位序列名称（如：技术研发类）
    grade               VARCHAR(20)     NOT NULL,       -- 职级（如：P6）
    dimension           VARCHAR(50)     NOT NULL,       -- 能力维度（如：技术专长）
    tag_name            VARCHAR(100)    NOT NULL,       -- 标签名称（如：复杂架构设计）
    mean_score          DECIMAL(5,2)    NOT NULL,       -- 该标签在同岗位序列同职级中的平均得分
    median_score        DECIMAL(5,2)    NOT NULL,       -- 中位数（P50），反映典型水平，比均值更抗极端值
    std_dev             DECIMAL(5,2)    NOT NULL,       -- 标准差，反映得分离散程度，标准差大说明该标签水平差异大
    percentile_25       DECIMAL(5,2)    NOT NULL,       -- 25分位数（P25），反映下四分位水平
    percentile_75       DECIMAL(5,2)    NOT NULL,       -- 75分位数（P75），反映上四分位水平
    sample_count        INT             NOT NULL,       -- 样本量，参与统计的人数，样本量太小则基准参考价值有限
    batch_id            VARCHAR(50)     NOT NULL,       -- 写入批次ID，用于追溯Pipeline运行记录

    -- 唯一约束：同一岗位序列+职级+维度+标签名，不会重复
    UNIQUE (position_family_code, grade, dimension, tag_name)
);

COMMENT ON TABLE  position_benchmarks IS '岗位基准画像：按岗位序列+职级+维度统计各标签的得分分布，用于个人能力对标分析';
COMMENT ON COLUMN position_benchmarks.id                  IS '自增主键，无业务含义';
COMMENT ON COLUMN position_benchmarks.position_family_code IS '岗位序列代码，如DYJS15，对应任职资格平台码表PostCode';
COMMENT ON COLUMN position_benchmarks.position_family_name IS '岗位序列名称，如技术研发类/产品类/设计类，冗余存储方便展示';
COMMENT ON COLUMN position_benchmarks.grade               IS '职级，如P5/P6/P7，基准画像按岗位序列+职级分组统计';
COMMENT ON COLUMN position_benchmarks.dimension           IS '能力维度，如技术专长/技术创新，基准画像在每个维度下独立统计';
COMMENT ON COLUMN position_benchmarks.tag_name            IS '标签名称，与employee_capability_tags中的tag_name对应';
COMMENT ON COLUMN position_benchmarks.mean_score          IS '平均得分，反映该标签在同岗位序列同职级中的平均水平';
COMMENT ON COLUMN position_benchmarks.median_score        IS '中位数P50，反映典型水平，比均值更抗极端值影响';
COMMENT ON COLUMN position_benchmarks.std_dev             IS '标准差，反映得分离散程度，标准差大说明该标签水平差异大';
COMMENT ON COLUMN position_benchmarks.percentile_25       IS '25分位数P25，反映下四分位水平，25%的人低于此分数';
COMMENT ON COLUMN position_benchmarks.percentile_75       IS '75分位数P75，反映上四分位水平，25%的人高于此分数';
COMMENT ON COLUMN position_benchmarks.sample_count        IS '样本量，参与统计的人数，样本量太小（如<10）则基准参考价值有限';
COMMENT ON COLUMN position_benchmarks.batch_id            IS '写入批次ID，格式BATCH_YYYYMMDD_HHMM，用于追溯Pipeline运行记录';


-- ============================================================
-- 表4：dimension_schema（维度定义配置表）
-- 用途：配置表，定义每个岗位序列有哪些能力维度。
--       HR在后台配置，代码读取后动态注入Prompt。
--       这是系统的元数据层，新增岗位序列只需加一行配置，不需要改代码。
-- 核心查询：按 position_family_code 检索某岗位序列的所有维度定义
-- ============================================================
CREATE TABLE dimension_schema (
    id                  BIGSERIAL       PRIMARY KEY,
    position_family_code VARCHAR(20)    NOT NULL,       -- 岗位序列代码（如：DYJS15），关联任职资格平台码表
    position_family_name VARCHAR(50)    NOT NULL,       -- 岗位序列名称（如：技术研发类），冗余存储方便展示
    dimension_name      VARCHAR(50)     NOT NULL,       -- 维度名称（如：技术专长）
    description         TEXT            NOT NULL,       -- 维度描述，说明该维度考察什么能力，用于AI理解维度含义
    sort_order          SMALLINT,                      -- 展示排序（1-5），控制维度在页面和Prompt中的展示顺序
    typical_evidence    TEXT,                          -- 该维度下典型的能力证据示例，用于Prompt的Few-shot示例
    is_active           BOOLEAN         DEFAULT TRUE,  -- 是否启用，可临时禁用某个维度而不删除数据

    -- 唯一约束：同一岗位序列下维度名称唯一
    UNIQUE (position_family_code, dimension_name)
);

COMMENT ON TABLE  dimension_schema IS '维度定义配置表：定义每个岗位序列的能力维度体系，作为系统的元数据层，可动态配置';
COMMENT ON COLUMN dimension_schema.id                  IS '自增主键，无业务含义';
COMMENT ON COLUMN dimension_schema.position_family_code IS '岗位序列代码，如DYJS15，关联任职资格平台码表PostCode';
COMMENT ON COLUMN dimension_schema.position_family_name IS '岗位序列名称，如技术研发类/产品类/设计类/市场类/管理类，冗余存储方便展示';
COMMENT ON COLUMN dimension_schema.dimension_name      IS '维度名称，如技术研发类的维度：技术专长、技术创新、客户导向、知识技能';
COMMENT ON COLUMN dimension_schema.description         IS '维度描述，说明该维度考察什么能力，用于AI理解维度含义并准确分类材料';
COMMENT ON COLUMN dimension_schema.sort_order          IS '展示排序1-5，控制维度在页面和Prompt中的展示顺序，越小越靠前';
COMMENT ON COLUMN dimension_schema.typical_evidence    IS '典型能力证据示例，用于Prompt的Few-shot示例，帮助AI理解该维度下什么样的材料算优秀';
COMMENT ON COLUMN dimension_schema.is_active           IS '是否启用，可临时禁用某个维度而不删除数据，用于维度体系调整过渡期';


-- ============================================================
-- 初始数据：dimension_schema 维度配置
-- !! 注意：以下 position_family_code 为占位值，请替换为任职资格平台码表中的真实 PostCode !!
-- ============================================================
INSERT INTO dimension_schema (position_family_code, position_family_name, dimension_name, description, sort_order, typical_evidence) VALUES
('DYJS15', '技术研发类', '技术专长',   '考察技术深度和广度，包括但不限于编程语言掌握度、框架运用能力、系统设计能力', 1, '主导核心模块设计、解决复杂技术难题、引入新技术栈'),
('DYJS15', '技术研发类', '技术创新',   '考察技术改进和创新能力，包括工具/流程优化、技术方案创新、开源贡献', 2, '引入AI代码审查系统使缺陷检出率提升40%、开发自动化工具提升团队效率'),
('DYJS15', '技术研发类', '客户导向',   '考察以用户/客户为中心的意识，包括需求理解、用户体验优化、业务价值创造', 3, '优化首屏加载性能从3.2s降至0.8s、用户满意度提升15%'),
('DYJS15', '技术研发类', '知识技能',   '考察知识沉淀和团队赋能能力，包括技术文档建设、代码评审、新人指导、技术分享', 4, '建立团队技术规范文档体系、定期组织技术分享、培养3名新人独立负责模块'),
('CP0001', '产品类',     '产品规划',   '考察产品中长期规划能力，包括市场分析、竞品研究、产品路线图制定', 1, '制定6个月产品路线图、推动3个核心功能从0到1上线'),
('CP0001', '产品类',     '用户洞察',   '考察用户需求挖掘能力，包括用户调研、数据分析、用户画像构建', 2, '通过用户访谈发现3个核心痛点、DAU提升30%'),
('CP0001', '产品类',     '数据分析',   '考察数据驱动决策能力，包括AB实验设计、数据指标体系搭建、数据洞察输出', 3, '搭建核心指标看板、通过AB实验优化转化率提升25%'),
('CP0001', '产品类',     '商业思维',   '考察商业敏感度和ROI意识，包括成本控制、商业变现、投入产出分析', 4, '设计付费会员体系提升ARPU 40%、优化资源分配节省30%成本'),
('CP0001', '产品类',     '项目管理',   '考察项目推进和资源协调能力，包括跨部门协作、进度管理、风险控制', 5, '协调3个部门10人团队按时交付、项目延期率降低60%'),
('SJ0001', '设计类',     '设计方法论', '考察设计方法和工具掌握程度，包括设计系统搭建、设计规范制定、设计工具运用', 1, '搭建企业级设计系统覆盖200+组件、制定设计规范文档'),
('SJ0001', '设计类',     '用户研究',   '考察用户研究能力，包括可用性测试、用户行为分析、设计验证', 2, '主导可用性测试发现15个可用性问题、设计迭代后NPS提升20%'),
('SJ0001', '设计类',     '技术实现',   '考察设计与技术实现结合能力，包括前端基础认知、动效设计、设计交付质量', 3, '设计复杂交互动效并推动前端实现、设计还原度达95%'),
('SJ0001', '设计类',     '审美判断',   '考察审美水平和视觉表达能力，包括色彩运用、排版布局、品牌一致性', 4, '主导品牌视觉升级、设计作品获得内部创新奖'),
('SJ0001', '设计类',     '行业视野',   '考察设计趋势关注和行业影响力，包括设计趋势研究、行业分享、设计社区贡献', 5, '在行业大会分享设计经验、设计文章阅读量10万+'),
('SC0001', '市场类',     '市场洞察',   '考察市场分析和趋势判断能力', 1, '通过行业分析报告发现3个增长机会点'),
('SC0001', '市场类',     '策略制定',   '考察营销策略制定和执行能力', 2, '制定年度营销策略实现GMV增长50%'),
('SC0001', '市场类',     '创意能力',   '考察创意策划和内容生产能力', 3, '策划创意活动获得行业奖项、内容传播量100万+'),
('SC0001', '市场类',     '渠道管理',   '考察渠道拓展和运营能力', 4, '开拓5个新渠道、渠道ROI提升30%'),
('SC0001', '市场类',     '效果评估',   '考察营销效果评估和优化能力', 5, '建立效果评估模型、优化ROI提升40%'),
('GL0001', '管理类',     '团队管理',   '考察团队建设和人员管理能力', 1, '带领15人团队、团队稳定性90%以上'),
('GL0001', '管理类',     '战略规划',   '考察战略制定和分解能力', 2, '制定部门年度战略并拆解为可执行方案'),
('GL0001', '管理类',     '资源协调',   '考察跨部门资源整合和协调能力', 3, '协调4个部门资源完成重大项目'),
('GL0001', '管理类',     '绩效驱动',   '考察目标设定和绩效管理能力', 4, '建立OKR体系、团队目标达成率120%'),
('GL0001', '管理类',     '人才培养',   '考察人才梯队建设和培养能力', 5, '培养2名管理者、团队晋升率30%');


-- ============================================================
-- 如果之前已按旧表结构创建了 batch_upload_log，执行以下 ALTER 语句迁移
-- 注意：仅迁移结构，已有数据不受影响
-- ============================================================
-- ALTER TABLE batch_upload_log
--     ALTER COLUMN batch_id         DROP NOT NULL,
--     ALTER COLUMN assessment_cycle DROP NOT NULL,
--     ALTER COLUMN mode             DROP NOT NULL;