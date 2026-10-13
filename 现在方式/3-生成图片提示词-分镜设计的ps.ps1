#!/usr/bin/env pwsh
# -*- coding: utf-8 -*-
<#
.SYNOPSIS
    分镜设计 + 图片提示词生成
.DESCRIPTION
    读取Video_Script场景，拆分为分镜，生成AI生图提示词
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

# 画风设置
$ArtStyle = "Q版儿童绘本"
$StyleEnglish = "chibi style, cute cartoon, children's book illustration, vibrant colors, soft lighting, highly detailed"

# 分辨率
$Resolution = "1080x1920"  # 竖屏9:16

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

function Get-PendingScenes {
    <#
    .SYNOPSIS
        获取待设计分镜的场景
    #>
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [int]$Limit = 30
    )
    
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = @"
SELECT TOP ($Limit)
    s.story_id,
    s.story_code,
    s.story_name,
    vs.script_id,
    vs.scene_no,
    vs.narration,
    vs.visual_desc,
    vs.mood,
    vs.timestamp_start,
    vs.timestamp_end,
    s.category
FROM dbo.Video_Script vs
INNER JOIN dbo.Story_Master s ON vs.story_id = s.story_id
WHERE vs.script_id NOT IN (
    SELECT DISTINCT script_id FROM dbo.Storyboard
)
ORDER BY s.story_id, vs.scene_no
"@
    
    $reader = $cmd.ExecuteReader()
    $scenes = @()
    
    while ($reader.Read()) {
        $scenes += @{
            story_id = $reader["story_id"]
            story_code = $reader["story_code"]
            story_name = $reader["story_name"]
            script_id = $reader["script_id"]
            scene_no = $reader["scene_no"]
            narration = $reader["narration"]
            visual_desc = $reader["visual_desc"]
            mood = $reader["mood"]
            timestamp_start = $reader["timestamp_start"]
            timestamp_end = $reader["timestamp_end"]
            category = $reader["category"]
        }
    }
    
    $reader.Close()
    return $scenes
}

function Get-StoryCharacters {
    <#
    .SYNOPSIS
        获取故事中的角色
    #>
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [int]$StoryId
    )
    
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = @"
SELECT char_code, char_name, appearance, key_features, prompt_template
FROM dbo.Character_Design
WHERE story_id = @story_id OR story_id IS NULL
ORDER BY char_id
"@
    $cmd.Parameters.AddWithValue("@story_id", $StoryId) | Out-Null
    
    $reader = $cmd.ExecuteReader()
    $characters = @()
    
    while ($reader.Read()) {
        $characters += @{
            char_code = $reader["char_code"]
            char_name = $reader["char_name"]
            appearance = $reader["appearance"]
            key_features = $reader["key_features"]
            prompt_template = $reader["prompt_template"]
        }
    }
    
    $reader.Close()
    return $characters
}

function Build-StoryboardPrompt {
    <#
    .SYNOPSIS
        构建分镜设计Prompt
    #>
    param(
        [hashtable]$Scene,
        [array]$Characters
    )
    
    $charInfo = ""
    if ($Characters.Count -gt 0) {
        $charInfo = "`n`n【角色信息】`n"
        foreach ($char in $Characters) {
            $charInfo += "- $($char.char_name): $($char.appearance)`n"
        }
    }
    
    $prompt = @"
你是一个专业的分镜设计师，擅长将场景描述拆分为具体的镜头。

【故事】$($Scene.story_name)
【分类】$($Scene.category)

【场景信息】
- 场景编号: $($Scene.scene_no)
- 时间范围: $($Scene.timestamp_start)-$($Scene.timestamp_end)秒
- 旁白: $($Scene.narration)
- 画面描述: $($Scene.visual_desc)
- 情绪: $($Scene.mood)
$charInfo

【任务】
将上述场景拆分为2-3个分镜，每个分镜包含具体的景别、角度、镜头运动。

【输出格式】
请严格按照以下JSON格式输出：

{
  "shots": [
    {
      "shot_no": 1,
      "shot_type": "景别(全景/中景/近景/特写)",
      "camera_move": "镜头运动(固定/推/拉/摇/移)",
      "angle": "角度(平视/俯视/仰视)",
      "subject": "主体",
      "action": "动作",
      "background": "背景",
      "lighting": "光线",
      "prompt_en": "英文生图提示词(详细描述画面内容)"
    }
  ]
}

【要求】
- 画风: $ArtStyle
- 每个分镜3-5秒
- prompt_en必须包含: 角色描述 + 场景描述 + $StyleEnglish
- prompt_en用英文，详细具体，50-100词
- 严禁使用中文引号
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
                messages = @(@{role = "user"; content = $Prompt})
                temperature = 0.7
                max_tokens = 4000
            } | ConvertTo-Json -Depth 10
            
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            
            $request = [System.Net.WebRequest]::Create($KimiApiUrl)
            $request.Method = "POST"
            $request.ContentType = "application/json; charset=utf-8"
            $request.Headers.Add("Authorization", "Bearer $KimiApiKey")
            $request.ContentLength = $bytes.Length
            $request.Timeout = 120000
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
                Write-Host "  ✗ API调用失败: $_" -ForegroundColor Red
                $result = $null
            }
        }
    }
    
    return $result
}

function ConvertTo-Hashtable {
    param([Parameter(ValueFromPipeline)]$InputObject)
    
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

function Parse-StoryboardResponse {
    param([string]$Response)
    
    try {
        $json = $Response -replace '```json\s*', '' -replace '```\s*$', ''
        $json = $json.Trim()
        $json = $json.Replace("""", """").Replace("""", """")
        $json = $json -replace ',(\s*[\}\]])', '$1'
        $json = $json -replace '[\x00-\x1F\x7F]', ''
        
        $data = $json | ConvertFrom-Json
        $shots = ConvertTo-Hashtable -InputObject $data.shots
        
        return $shots
    }
    catch {
        Write-Host "  ✗ JSON解析失败" -ForegroundColor Red
        return $null
    }
}

function Insert-StoryboardAndPrompt {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection,
        [int]$ScriptId,
        [int]$StoryId,
        [array]$Shots
    )
    
    $shotCount = 0
    $promptCount = 0
    
    foreach ($shot in $Shots) {
        # 插入分镜
        $cmd = $Connection.CreateCommand()
        $cmd.CommandText = @"
INSERT INTO dbo.Storyboard (
    script_id, story_id, shot_no, shot_type_code, camera_move_code, angle_code,
    subject, action, background, lighting, reference_note, create_date, update_date
) VALUES (
    @script_id, @story_id, @shot_no, @shot_type, @camera_move, @angle,
    @subject, @action, @background, @lighting, @note, GETDATE(), GETDATE()
);
SELECT SCOPE_IDENTITY();
"@
        
        # 映射字典值
        $shotType = Map-ShotType -Type $shot.shot_type
        $cameraMove = Map-CameraMove -Move $shot.camera_move
        $angle = Map-Angle -Angle $shot.angle
        
        $cmd.Parameters.AddWithValue("@script_id", $ScriptId) | Out-Null
        $cmd.Parameters.AddWithValue("@story_id", $StoryId) | Out-Null
        $cmd.Parameters.AddWithValue("@shot_no", $shot.shot_no) | Out-Null
        $cmd.Parameters.AddWithValue("@shot_type", $shotType) | Out-Null
        $cmd.Parameters.AddWithValue("@camera_move", $cameraMove) | Out-Null
        $cmd.Parameters.AddWithValue("@angle", $angle) | Out-Null
        
        $pSubject = New-Object System.Data.SqlClient.SqlParameter("@subject", [System.Data.SqlDbType]::NVarChar, 200)
        $pSubject.Value = $shot.subject
        $cmd.Parameters.Add($pSubject) | Out-Null
        
        $pAction = New-Object System.Data.SqlClient.SqlParameter("@action", [System.Data.SqlDbType]::NVarChar, 500)
        $pAction.Value = $shot.action
        $cmd.Parameters.Add($pAction) | Out-Null
        
        $pBackground = New-Object System.Data.SqlClient.SqlParameter("@background", [System.Data.SqlDbType]::NVarChar, 500)
        $pBackground.Value = $shot.background
        $cmd.Parameters.Add($pBackground) | Out-Null
        
        $pLighting = New-Object System.Data.SqlClient.SqlParameter("@lighting", [System.Data.SqlDbType]::NVarChar, 200)
        $pLighting.Value = $shot.lighting
        $cmd.Parameters.Add($pLighting) | Out-Null
        
        $pNote = New-Object System.Data.SqlClient.SqlParameter("@note", [System.Data.SqlDbType]::NVarChar, 500)
        $pNote.Value = "Auto generated"
        $cmd.Parameters.Add($pNote) | Out-Null
        
        try {
            $shotId = $cmd.ExecuteScalar()
            $shotCount++
            
            # 插入提示词
            $cmd2 = $Connection.CreateCommand()
            $cmd2.CommandText = @"
INSERT INTO dbo.Image_Prompt (
    shot_id, script_id, story_id, prompt_no, prompt_en, style_tag,
    negative_prompt, gen_status, resolution, create_date, update_date
) VALUES (
    @shot_id, @script_id, @story_id, 1, @prompt_en, @style_tag,
    @negative, 'pending', @resolution, GETDATE(), GETDATE()
)
"@
            
            $cmd2.Parameters.AddWithValue("@shot_id", $shotId) | Out-Null
            $cmd2.Parameters.AddWithValue("@script_id", $ScriptId) | Out-Null
            $cmd2.Parameters.AddWithValue("@story_id", $StoryId) | Out-Null
            
            $pPromptEn = New-Object System.Data.SqlClient.SqlParameter("@prompt_en", [System.Data.SqlDbType]::NVarChar, 3000)
            $pPromptEn.Value = $shot.prompt_en
            $cmd2.Parameters.Add($pPromptEn) | Out-Null
            
            $pStyle = New-Object System.Data.SqlClient.SqlParameter("@style_tag", [System.Data.SqlDbType]::NVarChar, 500)
            $pStyle.Value = $ArtStyle
            $cmd2.Parameters.Add($pStyle) | Out-Null
            
            $pNegative = New-Object System.Data.SqlClient.SqlParameter("@negative", [System.Data.SqlDbType]::NVarChar, 1000)
            $pNegative.Value = "ugly, deformed, noisy, blurry, distorted, out of focus, bad anatomy, extra limbs, poorly drawn face, poorly drawn hands, missing fingers, low quality, worst quality"
            $cmd2.Parameters.Add($pNegative) | Out-Null
            
            $cmd2.Parameters.AddWithValue("@resolution", $Resolution) | Out-Null
            
            $cmd2.ExecuteNonQuery() | Out-Null
            $promptCount++
            
            Write-Host "    ✓ 分镜$($shot.shot_no): $shotType | $cameraMove | $angle" -ForegroundColor Gray
        }
        catch {
            Write-Host "    ✗ 插入失败: $_" -ForegroundColor Red
        }
    }
    
    return @{shots = $shotCount; prompts = $promptCount}
}

function Map-ShotType {
    param([string]$Type)
    
    switch -Wildcard ($Type) {
        "*极远*" { return "extreme_long" }
        "*远景*" { return "long" }
        "*全景*" { return "full" }
        "*中景*" { return "medium" }
        "*近景*" { return "close_up" }
        "*特写*" { return "extreme_close" }
        default { return "medium" }
    }
}

function Map-CameraMove {
    param([string]$Move)
    
    switch -Wildcard ($Move) {
        "*固定*" { return "static" }
        "*推*" { return "push" }
        "*拉*" { return "pull" }
        "*摇*" { return "pan" }
        "*移*" { return "tilt" }
        "*变焦推*" { return "zoom_in" }
        "*变焦拉*" { return "zoom_out" }
        default { return "static" }
    }
}

function Map-Angle {
    param([string]$Angle)
    
    switch -Wildcard ($Angle) {
        "*平视*" { return "eye_level" }
        "*仰视*" { return "low_angle" }
        "*俯视*" { return "high_angle" }
        "*鸟瞰*" { return "bird_eye" }
        "*倾斜*" { return "dutch_angle" }
        default { return "eye_level" }
    }
}

function Show-ProgressStats {
    param(
        [System.Data.SqlClient.SqlConnection]$Connection
    )
    
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = @"
SELECT 
    (SELECT COUNT(*) FROM dbo.Video_Script) as total_scenes,
    (SELECT COUNT(*) FROM dbo.Storyboard) as total_shots,
    (SELECT COUNT(*) FROM dbo.Image_Prompt) as total_prompts,
    (SELECT COUNT(*) FROM dbo.Image_Prompt WHERE gen_status = 'done') as done_images
"@
    
    $reader = $cmd.ExecuteReader()
    if ($reader.Read()) {
        Write-Host ""
        Write-Host "当前进度统计:" -ForegroundColor Cyan
        Write-Host "  场景数: $($reader["total_scenes"])" -ForegroundColor Gray
        Write-Host "  分镜数: $($reader["total_shots"])" -ForegroundColor Gray
        Write-Host "  提示词: $($reader["total_prompts"])" -ForegroundColor Gray
        Write-Host "  已生图: $($reader["done_images"])" -ForegroundColor Gray
    }
    $reader.Close()
}

# =============================================
# 主程序
# =============================================

function Main {
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "分镜设计 + 图片提示词生成工具" -ForegroundColor Cyan
    Write-Host "画风: $ArtStyle" -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host ""
    
    $connection = Get-DbConnection
    Show-ProgressStats -Connection $connection
    
    # 获取待处理的场景
    $scenes = Get-PendingScenes -Connection $connection -Limit 20
    
    if ($scenes.Count -eq 0) {
        Write-Host ""
        Write-Host "所有场景已设计分镜，无需处理" -ForegroundColor Green
        $connection.Close()
        return
    }
    
    Write-Host ""
    Write-Host "找到 $($scenes.Count) 个待处理的场景"
    Write-Host "-" * 60
    
    $totalShots = 0
    $totalPrompts = 0
    
    foreach ($scene in $scenes) {
        Write-Host ""
        Write-Host "处理场景: [$($scene.story_code)] $($scene.story_name) - 场景$($scene.scene_no)" -ForegroundColor Cyan
        Write-Host "  旁白: $($scene.narration.Substring(0, [Math]::Min(30, $scene.narration.Length)))..." -ForegroundColor Gray
        
        # 获取角色信息
        $characters = Get-StoryCharacters -Connection $connection -StoryId $scene.story_id
        Write-Host "  找到 $($characters.Count) 个角色"
        
        # 构建Prompt
        $prompt = Build-StoryboardPrompt -Scene $scene -Characters $characters
        
        # 调用API
        Write-Host "  → 调用AI设计分镜..."
        $response = Invoke-KimiApi -Prompt $prompt
        
        if (-not $response) {
            Write-Host "  ✗ API调用失败，跳过" -ForegroundColor Red
            continue
        }
        
        # 解析响应
        $shots = Parse-StoryboardResponse -Response $response
        
        if (-not $shots) {
            Write-Host "  ✗ 解析失败，跳过" -ForegroundColor Red
            continue
        }
        
        Write-Host "  ✓ 生成 $($shots.Count) 个分镜"
        
        # 插入数据库
        $result = Insert-StoryboardAndPrompt -Connection $connection -ScriptId $scene.script_id -StoryId $scene.story_id -Shots $shots
        
        $totalShots += $result.shots
        $totalPrompts += $result.prompts
        
        Write-Host "  插入: $($result.shots) 分镜, $($result.prompts) 提示词" -ForegroundColor Green
        
        # 限流
        if ($scene -ne $scenes[-1]) {
            Write-Host "  → 等待3秒..."
            Start-Sleep -Seconds 3
        }
    }
    
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "本次新增: $totalShots 分镜, $totalPrompts 提示词" -ForegroundColor Green
    
    Show-ProgressStats -Connection $connection
    
    $connection.Close()
    
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host "完成！" -ForegroundColor Green
}

Main