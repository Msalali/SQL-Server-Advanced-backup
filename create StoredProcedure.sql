USE [yourDB] -- change Name DB
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
-- =============================================
--- CHANGE Only DataBase Name First Line 
--- (:
-- =============================================
create PROCEDURE [dbo].[ReportBackup]

AS
BEGIN

	SET NOCOUNT ON;

	
WITH

AllocationSize AS (
    SELECT 
        container_id AS partition_id,
        SUM(total_pages) AS total_pages
    FROM sys.allocation_units
    GROUP BY container_id
),

TableSizes AS (
    SELECT 
        s.name AS SchemaName,
        o.name AS ObjectName,
        'Table' AS ObjectType,
        SUM(p.rows) AS TotalRows,
        CAST(SUM(ISNULL(a.total_pages, 0)) * 8.0 / 1024 AS decimal(12,2)) AS ObjectSizeMB,
        1 AS SortOrder
    FROM sys.objects o
    INNER JOIN sys.tables t ON o.object_id = t.object_id
    INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
    INNER JOIN sys.partitions p ON t.object_id = p.object_id
    LEFT JOIN AllocationSize a ON p.partition_id = a.partition_id
    WHERE o.is_ms_shipped = 0
          AND p.index_id IN (0,1)  -- 👌
    GROUP BY s.name, o.name
),

TriggerObjects_Table AS (
    SELECT 
        s.name AS SchemaName,
        tr.name AS ObjectName,
        'Trigger (Table)' AS ObjectType,
        NULL AS TotalRows,
        CAST(NULL AS decimal(12,2)) AS ObjectSizeMB,
        2 AS SortOrder
    FROM sys.triggers tr
    INNER JOIN sys.objects o ON tr.parent_id = o.object_id
    INNER JOIN sys.schemas s ON o.schema_id = s.schema_id
    WHERE tr.is_ms_shipped = 0 AND tr.parent_class = 1
),

TriggerObjects_Database AS (
    SELECT 
        NULL AS SchemaName,
        tr.name AS ObjectName,
        'Trigger (Database)' AS ObjectType,
        NULL AS TotalRows,
        CAST(NULL AS decimal(12,2)) AS ObjectSizeMB,
        3 AS SortOrder
    FROM sys.triggers tr
    WHERE tr.is_ms_shipped = 0 AND tr.parent_class = 0
),

UserObjects AS (
    SELECT 
        s.name AS SchemaName,
        o.name AS ObjectName,
        o.type_desc AS ObjectType,
        NULL AS TotalRows,
        CAST(NULL AS decimal(12,2)) AS ObjectSizeMB,
        4 AS SortOrder
    FROM sys.objects o
    INNER JOIN sys.schemas s ON o.schema_id = s.schema_id
    WHERE o.is_ms_shipped = 0
      AND o.type NOT IN ('S', 'IT' ,'TR','U') -- استبعاد الجداول والتريقرات والمزامنات
      AND s.name NOT IN ('sys', 'INFORMATION_SCHEMA')
      AND o.type_desc NOT LIKE '%CONSTRAINT%'
      AND o.type_desc NOT LIKE '%QUEUE%'
      AND o.name NOT LIKE '#%'
	  AND NOT (s.name = 'dbo' AND o.name LIKE 'sp_%diagram%')
),

CombinedObjects AS (
    SELECT * FROM TableSizes
    UNION ALL
    SELECT * FROM TriggerObjects_Table
    UNION ALL
    SELECT * FROM TriggerObjects_Database
    UNION ALL
    SELECT * FROM UserObjects
),

DatabaseUsers AS (
    SELECT 
        NULL AS SchemaName,
        u.name AS ObjectName,
        'DB User' AS ObjectType,
        NULL AS TotalRows,
        CAST(NULL AS decimal(12,2)) AS ObjectSizeMB,
        7 AS SortOrder
    FROM sys.database_principals u
    WHERE u.type IN ('S','U','E','G')
      AND u.name NOT IN ('dbo','guest','INFORMATION_SCHEMA','sys')
),

DatabaseSize AS (
    SELECT 
        CAST(SUM(size) * 8.0 / 1024 AS decimal(12,2)) AS TotalDBSizeMB
    FROM sys.master_files
    WHERE database_id = DB_ID()
),

TotalObjectSize AS (
    SELECT 
        NULL AS SchemaName,
        N'--- Size of All Objects ---' AS ObjectName,
        '---' AS ObjectType,
        NULL AS TotalRows,
        CAST(SUM(ObjectSizeMB) AS decimal(12,2)) AS ObjectSizeMB,
        9 AS SortOrder
    FROM CombinedObjects
),

DBSizeRow AS (
    SELECT 
        NULL AS SchemaName,
        N'--- Total DB Size ---' AS ObjectName,
        '---' AS ObjectType,
        NULL AS TotalRows,
        (SELECT TotalDBSizeMB FROM DatabaseSize) AS ObjectSizeMB,
        10 AS SortOrder
),

ObjectCountSummary AS (
    SELECT 
        NULL AS SchemaName,
        N'--- Count of All Objects ---' AS ObjectName,
        '' AS ObjectType,
        NULL AS TotalRows,
        CAST(COUNT(*) AS decimal(12,2)) AS ObjectSizeMB,
        8 AS SortOrder
   FROM (
    SELECT SchemaName, ObjectName FROM CombinedObjects
    UNION ALL
    SELECT SchemaName, ObjectName FROM DatabaseUsers
) AS AllObjects
)

SELECT 
    DB_NAME() AS [Database_Name],
    CONVERT(VARCHAR, GETDATE(), 120) AS [Date_Report],
    ISNULL(SchemaName, N'--') AS [Schema_Name],
    ObjectName AS Object_Name,
    CASE 
        WHEN ObjectType = '' THEN  + CAST(CAST(ObjectSizeMB AS INT) AS VARCHAR)
        ELSE ObjectType
    END AS [Object_Type],
    ISNULL(CAST(TotalRows AS VARCHAR), '0') AS [Count_Rows],
    CASE 
        WHEN ObjectType IN ('Table', '---', '---') THEN CAST(ObjectSizeMB AS VARCHAR)
        ELSE N'0'
    END AS [SizeMB]
FROM (
    SELECT * FROM CombinedObjects
    UNION ALL
    SELECT * FROM DatabaseUsers
    UNION ALL
    SELECT * FROM ObjectCountSummary
    UNION ALL
    SELECT * FROM TotalObjectSize
    UNION ALL
    SELECT * FROM DBSizeRow
) AS FinalResult
ORDER BY SortOrder,   ObjectType, ObjectName;




END
