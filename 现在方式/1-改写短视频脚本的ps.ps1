#!/usr/bin/env pwsh
# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    故事改写为短视频脚本 - 修复中文引号版
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

$BatchSize = 999

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

function Get-PendingStories {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [int]$Limit = 999
    )
    
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = @"
SELECT TOP ($Limit) 
    story_id,
    story_code,
    story_name,
    original_content,
    target_duration
FROM dbo.Story_Master
WHERE status_code = 'pending'
    AND story_id NOT IN (SELECT DISTINCT story_id FROM dbo.Video_Script)
ORDER BY priority, story_id
"@
    
    $reader = $cmd.ExecuteReader()
    $stories = @()
    
    while ($reader.Read()) {
        $stories += @{
            story_id = $reader["story_id"]
            story_code = $reader["story_code"]
            story_name = $reader["story_name"]
            original_content = $reader["original_content"]
            target_duration = $reader["target_duration"]
        }
    }
    
    $reader.Close()
    return $stories
}

function Build-Prompt {
    param(
        [string]$StoryName,
        [string]$StoryContent,
        [int]$TargetDuration = 120
    )
    
    $sceneCount = [Math]::Ceiling($TargetDuration / 5)
    
    # 截取内容避免太长
    $maxContentLength = 1500
    if ($StoryContent.Length -gt $maxContentLength) {
        $StoryContent = $StoryContent.Substring(0, $maxContentLength) + "..."
    }
    
    $prompt = @"
你是一个专业的儿童短视频编剧。请将以下历史/神话故事改写成适合短视频的脚本。

【故事名称】$StoryName

【原始内容】
$StoryContent

【要求】
1. 总时长约$TargetDuration秒，拆分成$sceneCount个场景
2. 每个场景3-5秒，旁白字数控制在20-40字
3. 语言口语化，适合儿童理解，要有感染力
4. 每个场景包含：旁白文案 + 画面描述 + 情绪基调
5. 开头要有吸引力，结尾要有教育意义
6. 场景之间要有逻辑连贯性

【严格要求】
- 所有文本内容必须使用标准英文引号，禁止使用中文引号
- narration、visual_desc、mood 字段中不能出现任何引号字符
- 如果必须引用，使用单引号'代替

【输出格式】
请严格按照以下JSON格式输出，不要有任何其他内容：

{
  "scenes": [
    {
      "scene_no": 1,
      "timestamp_start": 0,
      "timestamp_end": 5,
      "narration": "旁白文案（中文，不要带引号）",
      "visual_desc": "画面描述（中文，不要带引号）",
      "mood": "情绪基调（中文，不要带引号）"
    }
  ]
}

注意：
- timestamp_start和timestamp_end是秒数，从0开始
- 每个场景时长3-5秒
- mood可选：庄严神秘、欢快轻松、紧张刺激、悲伤沉重、温馨感人、激昂振奋
- 只输出JSON，不要任何解释文字
- 所有内容必须是中文
- 严禁使用中文引号
"@
    
    return $prompt
}

function Invoke-KimiApi {
    param(
        [string]$Prompt
    )
    
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
        
        $stream = $request.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
        
        $response = $request.GetResponse()
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $content = $reader.ReadToEnd()
        $reader.Close()
        
        $data = $content | ConvertFrom-Json
        return $data.choices[0].message.content
    }
    catch {
        Write-Host "  ✗ API调用失败: $_" -ForegroundColor Red
        return $null
    }
}

function Parse-ScriptResponse {
    param(
        [string]$Response
    )
    
    try {
        # 清理Markdown代码块
        $json = $Response -replace '```json\s*', '' -replace '```\s*$', ''
        $json = $json.Trim()
        
        # 修复中文引号：替换为英文引号
        $json = $json.Replace('“', '"').Replace('”', '"')
        
        # 修复单引号为双引号（JSON标准要求）
        # 但要注意不要破坏已有的双引号
        $json = $json -replace "(?<=: )'([^']*)'", '"$1"'
        
        # 修复可能的尾随逗号
        $json = $json -replace ',(\s*[\}\]])', '$1'
        
        # 移除所有控制字符
        $json = $json -replace '[\x00-\x1F\x7F]', ''
        
        $data = $json | ConvertFrom-Json
        return $data.scenes
    }
    catch {
        Write-Host "  ✗ JSON解析失败，尝试备选方案..." -ForegroundColor Yellow
        
        # 备选方案：正则提取
        try {
            $scenes = @()
            # 匹配场景块
            $scenePattern = '"scene_no":\s*(\d+)[^}]*?"timestamp_start":\s*(\d+)[^}]*?"timestamp_end":\s*(\d+)[^}]*?"narration":\s*"([^"]*?)"[^}]*?"visual_desc":\s*"([^"]*?)"[^}]*?"mood":\s*"([^"]*?)"'
            $matches = [regex]::Matches($json, $scenePattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
            
            foreach ($match in $matches) {
                $scenes += @{
                    scene_no = [int]$match.Groups[1].Value
                    timestamp_start = [int]$match.Groups[2].Value
                    timestamp_end = [int]$match.Groups[3].Value
                    narration = $match.Groups[4].Value.Trim()
                    visual_desc = $match.Groups[5].Value.Trim()
                    mood = $match.Groups[6].Value.Trim()
                }
            }
            
            if ($scenes.Count -gt 0) {
                Write-Host "  ✓ 备选方案提取 $($scenes.Count) 个场景" -ForegroundColor Green
                return $scenes
            }
        }
        catch {
            Write-Host "  ✗ 备选方案失败: $_" -ForegroundColor Red
        }
        
        # 最后尝试：逐行解析
        try {
            Write-Host "  → 尝试逐行解析..." -ForegroundColor Yellow
            $scenes = @()
            $lines = $Response -split "`n"
            
            $currentScene = @{}
            foreach ($line in $lines) {
                if ($line -match '"scene_no":\s*(\d+)') {
                    if ($currentScene.Count -gt 0) {
                        $scenes += $currentScene
                    }
                    $currentScene = @{
                        scene_no = [int]$matches[1]
                    }
                }
                elseif ($line -match '"timestamp_start":\s*(\d+)') {
                    $currentScene.timestamp_start = [int]$matches[1]
                }
                elseif ($line -match '"timestamp_end":\s*(\d+)') {
                    $currentScene.timestamp_end = [int]$matches[1]
                }
                elseif ($line -match '"narration":\s*"([^"]*)"') {
                    $currentScene.narration = $matches[1]
                }
                elseif ($line -match '"visual_desc":\s*"([^"]*)"') {
                    $currentScene.visual_desc = $matches[1]
                }
                elseif ($line -match '"mood":\s*"([^"]*)"') {
                    $currentScene.mood = $matches[1]
                }
            }
            
            if ($currentScene.Count -gt 0) {
                $scenes += $currentScene
            }
            
            if ($scenes.Count -gt 0) {
                Write-Host "  ✓ 逐行解析提取 $($scenes.Count) 个场景" -ForegroundColor Green
                return $scenes
            }
        }
        catch {
            Write-Host "  ✗ 逐行解析失败: $_" -ForegroundColor Red
        }
        
        return $null
    }
}

function Insert-VideoScript {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [int]$StoryId,
        [array]$Scenes
    )
    
    $successCount = 0
    
    foreach ($scene in $Scenes) {
        $cmd = $Connection.CreateCommand()
        $cmd.CommandText = @"
INSERT INTO dbo.Video_Script (
    story_id,
    scene_no,
    timestamp_start,
    timestamp_end,
    narration,
    visual_desc,
    mood,
    bgm_type,
    create_date,
    update_date
) VALUES (
    @story_id,
    @scene_no,
    @timestamp_start,
    @timestamp_end,
    @narration,
    @visual_desc,
    @mood,
    @bgm_type,
    GETDATE(),
    GETDATE()
)
"@
        
        # 使用SqlParameter确保中文正确传递
        $paramNarration = New-Object System.Data.SqlClient.SqlParameter("@narration", [System.Data.SqlDbType]::NVarChar, 2000)
        $paramNarration.Value = [string]$scene.narration
        
        $paramVisual = New-Object System.Data.SqlClient.SqlParameter("@visual_desc", [System.Data.SqlDbType]::NVarChar, 1000)
        $paramVisual.Value = [string]$scene.visual_desc
        
        $paramMood = New-Object System.Data.SqlClient.SqlParameter("@mood", [System.Data.SqlDbType]::NVarChar, 50)
        $paramMood.Value = [string]$scene.mood
        
        $paramBgm = New-Object System.Data.SqlClient.SqlParameter("@bgm_type", [System.Data.SqlDbType]::NVarChar, 50)
        $paramBgm.Value = [string](Get-BgmType -Mood $scene.mood)
        
        $cmd.Parameters.Add($paramNarration) | Out-Null
        $cmd.Parameters.Add($paramVisual) | Out-Null
        $cmd.Parameters.Add($paramMood) | Out-Null
        $cmd.Parameters.Add($paramBgm) | Out-Null
        $cmd.Parameters.AddWithValue("@story_id", $StoryId) | Out-Null
        $cmd.Parameters.AddWithValue("@scene_no", [int]$scene.scene_no) | Out-Null
        $cmd.Parameters.AddWithValue("@timestamp_start", [int]$scene.timestamp_start) | Out-Null
        $cmd.Parameters.AddWithValue("@timestamp_end", [int]$scene.timestamp_end) | Out-Null
        
        try {
            $cmd.ExecuteNonQuery() | Out-Null
            $successCount++
            $preview = if ($scene.narration.Length -gt 20) { $scene.narration.Substring(0, 20) + "..." } else { $scene.narration }
            Write-Host "    ✓ 场景 $($scene.scene_no): $preview" -ForegroundColor Gray
        }
        catch {
            Write-Host "  ✗ 插入场景 $($scene.scene_no) 失败: $_" -ForegroundColor Red
        }
    }
    
    return $successCount
}

function Get-BgmType {
    param([string]$Mood)
    
    switch -Wildcard ($Mood) {
        "*庄严*" { return "古风悠扬" }
        "*神秘*" { return "神秘空灵" }
        "*欢快*" { return "轻快活泼" }
        "*轻松*" { return "轻松愉悦" }
        "*紧张*" { return "紧张悬疑" }
        "*刺激*" { return "激昂紧张" }
        "*悲伤*" { return "低沉悲伤" }
        "*沉重*" { return "沉重压抑" }
        "*温馨*" { return "温暖柔和" }
        "*感人*" { return "深情动人" }
        "*激昂*" { return "激昂振奋" }
        "*振奋*" { return "激昂振奋" }
        default { return "古风悠扬" }
    }
}

function Update-StoryStatus {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [int]$StoryId,
        [string]$Status
    )
    
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = "UPDATE dbo.Story_Master SET status_code = @status, update_date = GETDATE() WHERE story_id = @story_id"
    $cmd.Parameters.AddWithValue("@status", $Status) | Out-Null
    $cmd.Parameters.AddWithValue("@story_id", $StoryId) | Out-Null
    $cmd.ExecuteNonQuery() | Out-Null
}

# =============================================
# 主程序
# =============================================

function Main {
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "短视频脚本自动生成工具 (Kimi API)" -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host ""
    
    if ($KimiApiKey -eq "YOUR_API_TOKEN") {
        Write-Host "! 使用的是默认API Key，如果失败请检查Key是否有效" -ForegroundColor Yellow
    }
    
    $connection = Get-DbConnection
    $stories = Get-PendingStories -Connection $connection -Limit $BatchSize
    
    if ($stories.Count -eq 0) {
        Write-Host "没有待处理的故事" -ForegroundColor Yellow
        $connection.Close()
        return
    }
    
    Write-Host "找到 $($stories.Count) 个待处理的故事"
    Write-Host "-" * 60
    
    foreach ($story in $stories) {
        Write-Host ""
        Write-Host "处理故事: [$($story.story_code)] $($story.story_name)" -ForegroundColor Cyan
        
        $prompt = Build-Prompt -StoryName $story.story_name -StoryContent $story.original_content -TargetDuration $story.target_duration
        
        Write-Host "  → 调用Kimi API生成脚本..."
        
        $response = Invoke-KimiApi -Prompt $prompt
        
        if (-not $response) {
            Write-Host "  ✗ API调用失败，跳过" -ForegroundColor Red
            continue
        }
        
        # 显示API返回的前150字符用于调试
        $preview = if ($response.Length -gt 150) { $response.Substring(0, 150) + "..." } else { $response }
        Write-Host "  ← API返回: $preview" -ForegroundColor DarkGray
        
        $scenes = Parse-ScriptResponse -Response $response
        
        if (-not $scenes) {
            Write-Host "  ✗ 解析失败，跳过" -ForegroundColor Red
            continue
        }
        
        Write-Host "  ✓ 生成 $($scenes.Count) 个场景"
        
        $inserted = Insert-VideoScript -Connection $connection -StoryId $story.story_id -Scenes $scenes
        
        if ($inserted -eq $scenes.Count) {
            Write-Host "  ✓ 成功插入 $inserted 个场景" -ForegroundColor Green
            Update-StoryStatus -Connection $connection -StoryId $story.story_id -Status "script_done"
            Write-Host "  ✓ 故事状态更新为: 脚本完成" -ForegroundColor Green
        } else {
            Write-Host "  ! 部分场景插入失败: $inserted/$($scenes.Count)" -ForegroundColor Yellow
        }
        
        if ($story -ne $stories[-1]) {
            Write-Host "  → 等待3秒后继续..."
            Start-Sleep -Seconds 3
        }
    }
    
    $connection.Close()
    
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "处理完成！" -ForegroundColor Green
    Write-Host "=" * 60 -ForegroundColor Cyan
}

Main