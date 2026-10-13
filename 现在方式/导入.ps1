# =============================================
# 故事文件批量导入数据库脚本 (PowerShell)
# 功能：读取指定文件夹中的故事txt文件，从list.txt获取分类，导入SQL Server数据库
# =============================================

# =============================================
# 配置区域
# =============================================

# 数据库连接配置
$Server = "localhost\mssql,2433"           # SQL Server服务器地址
$Database = "MythStoryVideoDB"  # 数据库名
$TrustedConnection = $true      # $true=Windows身份验证, $false=SQL Server认证
$Username = "sa"                # SQL Server认证时的用户名
$Password = "YOUR_PASSWORD"     # SQL Server认证时的密码

# 故事文件所在目录
$StoryFolder = "D:\code\50000\ok\上下五千年故事"

# list.txt文件路径
$ListFile = "D:\code\50000\ok\list.txt"

# 文件编码
$FileEncoding = "UTF8"

# =============================================
# 函数定义
# =============================================

function Get-DbConnection {
    <#
    .SYNOPSIS
        获取数据库连接
    #>
    param()
    
    try {
        if ($TrustedConnection) {
            $connString = "Server=$Server;Database=$Database;Trusted_Connection=True;"
        } else {
            $connString = "Server=$Server;Database=$Database;User Id=$Username;Password=YOUR_PASSWORD;"
        }
        
        $connection = New-Object System.Data.SqlClient.SqlConnection($connString)
        $connection.Open()
        Write-Host "✓ 数据库连接成功" -ForegroundColor Green
        return $connection
    }
    catch {
        Write-Host "✗ 数据库连接失败: $_" -ForegroundColor Red
        throw
    }
}

function Load-StoryCategories {
    <#
    .SYNOPSIS
        从list.txt加载故事分类信息
    #>
    param(
        [string]$ListFilePath
    )
    
    $categories = @{}
    
    if (-not (Test-Path $ListFilePath)) {
        Write-Host "✗ list.txt文件不存在: $ListFilePath" -ForegroundColor Red
        return $categories
    }
    
    try {
        $lines = Get-Content -Path $ListFilePath -Encoding $FileEncoding
        
        foreach ($line in $lines) {
            $line = $line.Trim()
            if ([string]::IsNullOrEmpty($line)) { continue }
            
            # 匹配格式：序号. 故事名称 (分类)
            # 例如：72. 董卓乱政 (历史事件)
            if ($line -match '^\d+\.\s*(.+?)\s*\((.+?)\)$') {
                $storyName = $matches[1].Trim()
                $category = $matches[2].Trim()
                $categories[$storyName] = $category
            }
        }
        
        Write-Host "✓ 从list.txt加载了 $($categories.Count) 个故事分类" -ForegroundColor Green
        return $categories
    }
    catch {
        Write-Host "✗ 读取list.txt失败: $_" -ForegroundColor Red
        return $categories
    }
}

function Get-Category {
    <#
    .SYNOPSIS
        根据故事名称获取分类
    #>
    param(
        [hashtable]$Categories,
        [string]$StoryName
    )
    
    # 精确匹配
    if ($Categories.ContainsKey($StoryName)) {
        return $Categories[$StoryName]
    }
    
    # 模糊匹配
    foreach ($name in $Categories.Keys) {
        if ($StoryName -like "*$name*" -or $name -like "*$StoryName*") {
            return $Categories[$name]
        }
    }
    
    # 默认分类
    return "未分类"
}

function Extract-StoryCode {
    <#
    .SYNOPSIS
        从文件名提取故事编号
    #>
    param(
        [string]$FileName
    )
    
    if ($FileName -match '^(\d+)') {
        $code = $matches[1]
        return $code.PadLeft(2, '0')
    }
    return $null
}

function Extract-StoryName {
    <#
    .SYNOPSIS
        从文件名提取故事名称
    #>
    param(
        [string]$FileName
    )
    
    # 去掉序号和扩展名
    $name = $FileName -replace '^\d+\.', ''
    $name = $name -replace '\.txt$', ''
    return $name.Trim()
}

function Test-StoryExists {
    <#
    .SYNOPSIS
        检查故事是否已存在
    #>
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$StoryCode
    )
    
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = "SELECT COUNT(*) FROM dbo.Story_Master WHERE story_code = @story_code"
    $cmd.Parameters.AddWithValue("@story_code", $StoryCode) | Out-Null
    
    $count = $cmd.ExecuteScalar()
    return $count -gt 0
}

function Insert-Story {
    <#
    .SYNOPSIS
        将故事数据插入数据库
    #>
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [hashtable]$StoryData
    )
    
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = @"
INSERT INTO dbo.Story_Master (
    story_code,
    story_name,
    file_name,
    file_path,
    original_content,
    category,
    word_count,
    target_duration,
    status_code,
    priority,
    create_date,
    is_active
) VALUES (
    @story_code,
    @story_name,
    @file_name,
    @file_path,
    @original_content,
    @category,
    @word_count,
    @target_duration,
    @status_code,
    @priority,
    @create_date,
    @is_active
)
"@
    
    # 根据字数估算目标时长（每分钟约200字）
    $targetDuration = [Math]::Max(60, [Math]::Floor($StoryData.word_count / 200) * 60)
    
    $now = Get-Date
    
    $cmd.Parameters.AddWithValue("@story_code", $StoryData.story_code) | Out-Null
    $cmd.Parameters.AddWithValue("@story_name", $StoryData.story_name) | Out-Null
    $cmd.Parameters.AddWithValue("@file_name", $StoryData.file_name) | Out-Null
    $cmd.Parameters.AddWithValue("@file_path", $StoryData.file_path) | Out-Null
    $cmd.Parameters.AddWithValue("@original_content", $StoryData.content) | Out-Null
    $cmd.Parameters.AddWithValue("@category", $StoryData.category) | Out-Null
    $cmd.Parameters.AddWithValue("@word_count", $StoryData.word_count) | Out-Null
    $cmd.Parameters.AddWithValue("@target_duration", $targetDuration) | Out-Null
    $cmd.Parameters.AddWithValue("@status_code", "pending") | Out-Null
    $cmd.Parameters.AddWithValue("@priority", "P1") | Out-Null
    $cmd.Parameters.AddWithValue("@create_date", $now) | Out-Null
    $cmd.Parameters.AddWithValue("@is_active", 1) | Out-Null
    
    try {
        $cmd.ExecuteNonQuery() | Out-Null
        return $true
    }
    catch [System.Data.SqlClient.SqlException] {
        if ($_.Exception.Number -eq 2627) {
            # 唯一键冲突
            Write-Host "  ! 故事已存在，跳过: $($StoryData.story_name)" -ForegroundColor Yellow
        } else {
            Write-Host "  ✗ 插入失败: $_" -ForegroundColor Red
        }
        return $false
    }
    catch {
        Write-Host "  ✗ 插入失败: $_" -ForegroundColor Red
        return $false
    }
}

# =============================================
# 主程序
# =============================================

function Main {
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "故事文件批量导入工具 (PowerShell)" -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "目标文件夹: $StoryFolder"
    Write-Host "分类文件: $ListFile"
    Write-Host ""
    
    # 检查文件夹是否存在
    if (-not (Test-Path $StoryFolder)) {
        Write-Host "✗ 文件夹不存在: $StoryFolder" -ForegroundColor Red
        return
    }
    
    # 加载分类信息
    $categories = Load-StoryCategories -ListFilePath $ListFile
    if ($categories.Count -eq 0) {
        Write-Host "警告：未能加载分类信息，将使用默认分类" -ForegroundColor Yellow
    }
    
    # 获取所有txt文件
    $txtFiles = Get-ChildItem -Path $StoryFolder -Filter "*.txt" | Sort-Object Name
    
    Write-Host "发现 $($txtFiles.Count) 个txt文件"
    Write-Host "-" * 60
    
    if ($txtFiles.Count -eq 0) {
        Write-Host "没有找到txt文件，请检查文件夹路径" -ForegroundColor Red
        return
    }
    
    # 连接数据库
    $connection = Get-DbConnection
    
    # 统计
    $successCount = 0
    $skipCount = 0
    $errorCount = 0
    $errorFiles = @()
    
    # 处理每个文件
    for ($i = 0; $i -lt $txtFiles.Count; $i++) {
        $file = $txtFiles[$i]
        $fileName = $file.Name
        $fileIndex = $i + 1
        
        Write-Host ""
        Write-Host "[$fileIndex/$($txtFiles.Count)] 处理: $fileName"
        
        try {
            # 提取故事编号和名称
            $storyCode = Extract-StoryCode -FileName $fileName
            $storyName = Extract-StoryName -FileName $fileName
            
            if (-not $storyCode) {
                Write-Host "  ✗ 无法提取故事编号，跳过" -ForegroundColor Red
                $errorCount++
                $errorFiles += $fileName
                continue
            }
            
            # 检查是否已存在
            if (Test-StoryExists -Connection $connection -StoryCode $storyCode) {
                Write-Host "  ! 故事编号 $storyCode 已存在，跳过" -ForegroundColor Yellow
                $skipCount++
                continue
            }
            
            # 读取文件内容
            $content = Get-Content -Path $file.FullName -Raw -Encoding $FileEncoding
            
            # 计算字数
            $wordCount = ($content -replace '\s', '').Length
            
            # 从list.txt获取分类
            $category = Get-Category -Categories $categories -StoryName $storyName
            
            # 构建数据
            $storyData = @{
                story_code = $storyCode
                story_name = $storyName
                file_name = $fileName
                file_path = $file.FullName
                content = $content
                category = $category
                word_count = $wordCount
            }
            
            # 插入数据库
            if (Insert-Story -Connection $connection -StoryData $storyData) {
                Write-Host "  ✓ 导入成功: $storyName" -ForegroundColor Green
                Write-Host "    编号: $storyCode, 分类: $category, 字数: $wordCount"
                $successCount++
            } else {
                $skipCount++
            }
        }
        catch {
            Write-Host "  ✗ 处理失败: $_" -ForegroundColor Red
            $errorCount++
            $errorFiles += $fileName
        }
    }
    
    # 关闭连接
    $connection.Close()
    
    # 输出统计
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "导入完成统计" -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "总文件数: $($txtFiles.Count)"
    Write-Host "导入成功: $successCount" -ForegroundColor Green
    Write-Host "已存在跳过: $skipCount" -ForegroundColor Yellow
    Write-Host "处理失败: $errorCount" -ForegroundColor Red
    
    if ($errorFiles.Count -gt 0) {
        Write-Host ""
        Write-Host "失败文件列表:"
        foreach ($f in $errorFiles) {
            Write-Host "  - $f" -ForegroundColor Red
        }
    }
    
    Write-Host ""
    Write-Host "完成！" -ForegroundColor Green
}

# 执行主程序
Main