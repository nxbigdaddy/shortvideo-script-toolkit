#!/usr/bin/env pwsh
# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    自动提取角色并建立角色档案
.DESCRIPTION
    从Story_Master读取故事内容，调用AI提取角色信息，写入Character_Design表
#>

# =============================================
# 配置区域
# =============================================

$Server = "localhost\mssql,2433"
$Database = "MythStoryVideoDB"
$TrustedConnection = $true
$Username = "sa"
$Password = "YOUR_PASSWORD"

$KimiApiKey = "YOUR_API_TOKEN"
$KimiApiUrl = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
$KimiModel = "kimi-k2.5"

# 角色风格设置
$CharacterStyle = "国朝卡通"  # 可选：Q版卡通 / 写实国画 / 皮影戏 / 3D卡通

# =============================================
# 函数定义
# =============================================

function Get-DbConnection {
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

function Get-StoriesForCharacterExtract {
    <#
    .SYNOPSIS
        获取需要提取角色的故事
    #>
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [int]$Limit = 50
    )
    
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = @"
SELECT TOP ($Limit)
    story_id,
    story_code,
    story_name,
    original_content,
    category
FROM dbo.Story_Master
WHERE story_id NOT IN (
    SELECT DISTINCT story_id 
    FROM dbo.Character_Design 
    WHERE story_id IS NOT NULL
)
ORDER BY story_id
"@
    
    $reader = $cmd.ExecuteReader()
    $stories = @()
    
    while ($reader.Read()) {
        $stories += @{
            story_id = $reader["story_id"]
            story_code = $reader["story_code"]
            story_name = $reader["story_name"]
            original_content = $reader["original_content"]
            category = $reader["category"]
        }
    }
    
    $reader.Close()
    return $stories
}

function Build-CharacterExtractPrompt {
    <#
    .SYNOPSIS
        构建角色提取Prompt
    #>
    param(
        [string]$StoryName,
        [string]$StoryContent,
        [string]$Category
    )
    
    # 截取内容避免太长
    $maxLength = 2000
    if ($StoryContent.Length -gt $maxLength) {
        $StoryContent = $StoryContent.Substring(0, $maxLength) + "..."
    }
    
    $prompt = @"
你是一个专业的角色设计师，擅长从故事中提取角色信息并设计形象。

【故事名称】$StoryName
【故事分类】$Category

【故事内容】
$StoryContent

【任务】
请从故事中提取所有重要角色（主角、关键配角），为每个角色设计档案。

【输出格式】
请严格按照以下JSON格式输出，不要有任何其他内容：

{
  "characters": [
    {
      "char_name": "角色名称（中文）",
      "char_code": "角色编码（英文小写，下划线连接，如pan_gu）",
      "appearance": "外貌描述（50-100字，包含身材、面容、发型、特殊特征）",
      "color_palette": "主色调（3-4个颜色，如金色、红色、黑色）",
      "key_features": "关键特征（20-30字，最标志性的特点）",
      "pose_ref": "常用姿势（站立、行走、战斗、思考等）",
      "emotion_range": "表情范围（慈祥、威严、愤怒、微笑等）",
      "props": "标志性道具（武器、工具、饰品等）"
    }
  ]
}

【设计要求】
- 风格：$CharacterStyle
- 如果是神话人物，保留传统特征（如女娲人首蛇身、神农牛首）
- 如果是历史人物，符合时代背景
- char_code命名规则：拼音小写，下划线连接，如huang_di、nv_wa
- 只提取重要角色，不要群众演员
- 严禁使用中文引号，只使用英文引号
"@
    
    return $prompt
}

function Invoke-KimiApi {
    param(
        [string]$Prompt,
        [int]$MaxRetries = 3
    )
    
    $retryCount = 0
    $success = $false
    $result = $null
    
    while ($retryCount -lt $MaxRetries -and -not $success) {
        try {
            $body = @{
                model = $KimiModel
                messages = @(
                    @{
                        role = "user"
                        content = $Prompt
                    }
                )
                temperature = 0.7
                max_tokens = 4000
            } | ConvertTo-Json -Depth 10
            
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            
            $request = [System.Net.WebRequest]::Create($KimiApiUrl)
            $request.Method = "POST"
            $request.ContentType = "application/json; charset=utf-8"
            $request.Headers.Add("Authorization", "Bearer $KimiApiKey")
            $request.ContentLength = $bytes.Length
            
            # 设置超时时间（毫秒）
            $request.Timeout = 120000  # 120秒
            $request.ReadWriteTimeout = 120000
            
            $stream = $request.GetRequestStream()
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Close()
            
            $response = $request.GetResponse()
            $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $content = $reader.ReadToEnd()
            $reader.Close()
            
            $data = $content | ConvertFrom-Json
            $result = $data.choices[0].message.content
            $success = $true
        }
        catch {
            $retryCount++
            if ($retryCount -lt $MaxRetries) {
                Write-Host "  ! API超时，第 $retryCount 次重试..." -ForegroundColor Yellow
                Start-Sleep -Seconds 5
            } else {
                Write-Host "  ✗ API调用失败（已重试$MaxRetries次）: $_" -ForegroundColor Red
                $result = $null
            }
        }
    }
    
    return $result
}

function ConvertTo-Hashtable {
    <#
    .SYNOPSIS
        将PSCustomObject转换为Hashtable
    #>
    param(
        [Parameter(ValueFromPipeline)]
        $InputObject
    )
    
    process {
        if ($null -eq $InputObject) { return $null }
        
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $collection = @()
            foreach ($item in $InputObject) {
                $collection += (ConvertTo-Hashtable -InputObject $item)
            }
            return $collection
        }
        
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $hash = @{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $hash[$property.Name] = ConvertTo-Hashtable -InputObject $property.Value
            }
            return $hash
        }
        
        return $InputObject
    }
}

function Parse-CharacterResponse {
    param(
        [string]$Response
    )
    
    try {
        # 清理Markdown代码块
        $json = $Response -replace '```json\s*', '' -replace '```\s*$', ''
        $json = $json.Trim()
        
        # 修复中文引号 - 使用双引号包裹字符串
        $json = $json.Replace("""", """").Replace("""", """")
        $json = $json.Replace("'", "'").Replace("'", "'")
        
        # 修复尾随逗号
        $json = $json -replace ',(\s*[\}\]])', '$1'
        
        # 移除控制字符
        $json = $json -replace '[\x00-\x1F\x7F]', ''
        
        $data = $json | ConvertFrom-Json
        
        # 转换为Hashtable
        $characters = ConvertTo-Hashtable -InputObject $data.characters
        
        return $characters
    }
    catch {
        Write-Host "  ✗ JSON解析失败，尝试备选方案..." -ForegroundColor Yellow
        
        # 备选：正则提取
        try {
            $characters = @()
            $pattern = '"char_name":\s*"([^"]*)"[^}]*?"char_code":\s*"([^"]*)"[^}]*?"appearance":\s*"([^"]*)"[^}]*?"color_palette":\s*"([^"]*)"[^}]*?"key_features":\s*"([^"]*)"[^}]*?"pose_ref":\s*"([^"]*)"[^}]*?"emotion_range":\s*"([^"]*)"[^}]*?"props":\s*"([^"]*)"'
            $matches = [regex]::Matches($json, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
            
            foreach ($match in $matches) {
                $characters += @{
                    char_name = $match.Groups[1].Value.Trim()
                    char_code = $match.Groups[2].Value.Trim()
                    appearance = $match.Groups[3].Value.Trim()
                    color_palette = $match.Groups[4].Value.Trim()
                    key_features = $match.Groups[5].Value.Trim()
                    pose_ref = $match.Groups[6].Value.Trim()
                    emotion_range = $match.Groups[7].Value.Trim()
                    props = $match.Groups[8].Value.Trim()
                }
            }
            
            if ($characters.Count -gt 0) {
                Write-Host "  ✓ 备选方案提取 $($characters.Count) 个角色" -ForegroundColor Green
                return $characters
            }
        }
        catch {
            Write-Host "  ✗ 备选方案失败: $_" -ForegroundColor Red
        }
        
        return $null
    }
}

function Build-PromptTemplate {
    <#
    .SYNOPSIS
        构建AI生图的Prompt模板
    #>
    param(
        [hashtable]$Character,
        [string]$Style
    )
    
    $styleDesc = switch ($Style) {
        "Q版卡通" { "chibi style, cute cartoon, big head small body, children's book illustration, vibrant colors, soft lighting" }
        "写实国画" { "traditional Chinese ink painting, realistic, historical style, elegant, detailed, classical atmosphere" }
        "皮影戏" { "Chinese shadow puppet style, flat design, silhouette art, traditional folk art, dramatic lighting" }
        "3D卡通" { "3D cartoon style, Pixar style, cute and friendly, high quality rendering, soft shadows" }
        default { "traditional Chinese painting style, children's book illustration, vibrant colors" }
    }
    
    $template = @"
$($Character.appearance), $($Character.pose_ref), holding $($Character.props), $($styleDesc), highly detailed, masterpiece, best quality
"@
    
    return $template.Trim()
}

function Test-CharacterExists {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [string]$CharCode
    )
    
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = "SELECT COUNT(*) FROM dbo.Character_Design WHERE char_code = @char_code"
    $cmd.Parameters.AddWithValue("@char_code", $CharCode) | Out-Null
    
    $count = $cmd.ExecuteScalar()
    return $count -gt 0
}

function Insert-Character {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [int]$StoryId,
        [hashtable]$Character,
        [string]$Style
    )
    
    # 检查是否已存在
    if (Test-CharacterExists -Connection $Connection -CharCode $Character.char_code) {
        Write-Host "    ! 角色 $($Character.char_name) 已存在，跳过" -ForegroundColor Yellow
        return $false
    }
    
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = @"
INSERT INTO dbo.Character_Design (
    char_code,
    char_name,
    story_id,
    appearance,
    color_palette,
    key_features,
    pose_ref,
    emotion_range,
    prompt_template,
    create_date,
    update_date,
    is_active
) VALUES (
    @char_code,
    @char_name,
    @story_id,
    @appearance,
    @color_palette,
    @key_features,
    @pose_ref,
    @emotion_range,
    @prompt_template,
    GETDATE(),
    GETDATE(),
    1
)
"@
    
    $promptTemplate = Build-PromptTemplate -Character $Character -Style $Style
    
    # 使用SqlParameter确保中文正确
    $pCharCode = New-Object System.Data.SqlClient.SqlParameter("@char_code", [System.Data.SqlDbType]::VarChar, 50)
    $pCharCode.Value = $Character.char_code
    
    $pCharName = New-Object System.Data.SqlClient.SqlParameter("@char_name", [System.Data.SqlDbType]::NVarChar, 100)
    $pCharName.Value = $Character.char_name
    
    $pAppearance = New-Object System.Data.SqlClient.SqlParameter("@appearance", [System.Data.SqlDbType]::NVarChar, 1000)
    $pAppearance.Value = $Character.appearance
    
    $pColor = New-Object System.Data.SqlClient.SqlParameter("@color_palette", [System.Data.SqlDbType]::NVarChar, 200)
    $pColor.Value = $Character.color_palette
    
    $pFeatures = New-Object System.Data.SqlClient.SqlParameter("@key_features", [System.Data.SqlDbType]::NVarChar, 500)
    $pFeatures.Value = $Character.key_features
    
    $pPose = New-Object System.Data.SqlClient.SqlParameter("@pose_ref", [System.Data.SqlDbType]::NVarChar, 500)
    $pPose.Value = $Character.pose_ref
    
    $pEmotion = New-Object System.Data.SqlClient.SqlParameter("@emotion_range", [System.Data.SqlDbType]::NVarChar, 500)
    $pEmotion.Value = $Character.emotion_range
    
    $pTemplate = New-Object System.Data.SqlClient.SqlParameter("@prompt_template", [System.Data.SqlDbType]::NVarChar, 2000)
    $pTemplate.Value = $promptTemplate
    
    $cmd.Parameters.Add($pCharCode) | Out-Null
    $cmd.Parameters.Add($pCharName) | Out-Null
    $cmd.Parameters.AddWithValue("@story_id", $StoryId) | Out-Null
    $cmd.Parameters.Add($pAppearance) | Out-Null
    $cmd.Parameters.Add($pColor) | Out-Null
    $cmd.Parameters.Add($pFeatures) | Out-Null
    $cmd.Parameters.Add($pPose) | Out-Null
    $cmd.Parameters.Add($pEmotion) | Out-Null
    $cmd.Parameters.Add($pTemplate) | Out-Null
    
    try {
        $cmd.ExecuteNonQuery() | Out-Null
        return $true
    }
    catch {
        Write-Host "    ✗ 插入角色失败: $_" -ForegroundColor Red
        return $false
    }
}

function Show-CharacterStats {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection
    )
    
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = @"
SELECT 
    COUNT(*) as total_chars,
    COUNT(DISTINCT story_id) as stories_with_chars
FROM dbo.Character_Design
WHERE is_active = 1
"@
    
    $reader = $cmd.ExecuteReader()
    if ($reader.Read()) {
        $total = $reader["total_chars"]
        $stories = $reader["stories_with_chars"]
        Write-Host ""
        Write-Host "当前角色档案统计: $total 个角色，来自 $stories 个故事" -ForegroundColor Cyan
    }
    $reader.Close()
    
    # 显示已有角色列表
    $cmd.CommandText = "SELECT TOP 20 char_code, char_name FROM dbo.Character_Design ORDER BY char_id"
    $reader = $cmd.ExecuteReader()
    Write-Host "已有角色预览:" -ForegroundColor Gray
    while ($reader.Read()) {
        Write-Host "  - $($reader["char_code"]): $($reader["char_name"])" -ForegroundColor Gray
    }
    $reader.Close()
}

# =============================================
# 主程序
# =============================================

function Main {
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "角色档案自动生成工具" -ForegroundColor Cyan
    Write-Host "风格设置: $CharacterStyle" -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host ""
    
    $connection = Get-DbConnection
    
    # 显示当前统计
    Show-CharacterStats -Connection $connection
    
    # 获取待处理的故事
    $stories = Get-StoriesForCharacterExtract -Connection $connection -Limit 50
    
    if ($stories.Count -eq 0) {
        Write-Host ""
        Write-Host "所有故事已提取角色，无需处理" -ForegroundColor Green
        $connection.Close()
        return
    }
    
    Write-Host ""
    Write-Host "找到 $($stories.Count) 个待处理的故事"
    Write-Host "-" * 60
    
    $totalChars = 0
    
    foreach ($story in $stories) {
        Write-Host ""
        Write-Host "处理故事: [$($story.story_code)] $($story.story_name)" -ForegroundColor Cyan
        
        $prompt = Build-CharacterExtractPrompt -StoryName $story.story_name -StoryContent $story.original_content -Category $story.category
        
        Write-Host "  → 调用AI提取角色..."
        
        # 故事级别重试
        $storyRetry = 0
        $maxStoryRetries = 2
        $characters = $null
        
        while ($storyRetry -lt $maxStoryRetries -and -not $characters) {
            $response = Invoke-KimiApi -Prompt $prompt
            
            if ($response) {
                $preview = if ($response.Length -gt 100) { $response.Substring(0, 100) + "..." } else { $response }
                Write-Host "  ← API返回: $preview" -ForegroundColor DarkGray
                
                $characters = Parse-CharacterResponse -Response $response
                
                if (-not $characters) {
                    $storyRetry++
                    if ($storyRetry -lt $maxStoryRetries) {
                        Write-Host "  → 解析失败，等待5秒后重试..." -ForegroundColor Yellow
                        Start-Sleep -Seconds 5
                    }
                }
            } else {
                $storyRetry++
                if ($storyRetry -lt $maxStoryRetries) {
                    Write-Host "  → API调用失败，等待10秒后重试..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 10
                }
            }
        }
        
        if (-not $characters) {
            Write-Host "  ✗ 最终失败，跳过本故事" -ForegroundColor Red
            continue
        }
        
        Write-Host "  ✓ 提取到 $($characters.Count) 个角色"
        
        $inserted = 0
        foreach ($char in $characters) {
            if (Insert-Character -Connection $connection -StoryId $story.story_id -Character $char -Style $CharacterStyle) {
                Write-Host "    ✓ 角色 [$($char.char_code)] $($char.char_name)" -ForegroundColor Green
                Write-Host "      特征: $($char.key_features)" -ForegroundColor Gray
                $inserted++
            }
        }
        
        $totalChars += $inserted
        Write-Host "  本故事成功插入 $inserted/$($characters.Count) 个角色"
        
        # API限流
        if ($story -ne $stories[-1]) {
            Write-Host "  → 等待3秒..."
            Start-Sleep -Seconds 3
        }
    }
    
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "本次新增角色: $totalChars 个" -ForegroundColor Green
    
    # 显示最终统计
    Show-CharacterStats -Connection $connection
    
    $connection.Close()
    
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "完成！" -ForegroundColor Green
}

Main