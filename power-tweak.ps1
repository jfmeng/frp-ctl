<#
.SYNOPSIS
    配置 Windows 电源计划，将睡眠、硬盘关闭、休眠设置为“从不”，
    并禁用 USB 选择性暂停和 PCI Express 链接状态电源管理，防止无人值守主机断连。

.DESCRIPTION
    此脚本需要以管理员权限运行。
    它将获取当前活动的电源计划，并修改以下设置：
    - 睡眠: 从不 (AC & DC)
    - 硬盘关闭: 从不 (AC & DC)
    - 显示器关闭: 20 分钟 (AC & DC) - 如需不同值请修改脚本
    - 休眠: 从不 (AC & DC)
    - USB 选择性暂停: 已禁用 (AC & DC)
    - PCI Express 链接状态电源管理: 关闭 (AC & DC)

.NOTES
    文件名: power-tweak.ps1
    版本: 1.1
    运行方式: 以管理员身份打开 PowerShell，然后执行 .\power-tweak.ps1
#>

Write-Host "检查管理员权限..."
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "此脚本需要管理员权限才能运行。"
    Write-Warning "请右键点击 PowerShell 图标并选择 '以管理员身份运行'，然后重新执行此脚本。"
    Read-Host "按 Enter 键退出..."
    Exit 1
}
Write-Host "已获取管理员权限。" -ForegroundColor Green
Write-Host ""

# 获取当前活动的电源计划 GUID
Write-Host "正在获取当前活动的电源计划..."
try {
    $ActiveSchemeOutput = powercfg /getactivescheme
    $GuidPattern = '([a-f0-9]{8}-([a-f0-9]{4}-){3}[a-f0-9]{12})'
    if ($ActiveSchemeOutput -match $GuidPattern) {
        $SchemeGuid = $matches[0]
        Write-Host "当前活动的电源计划 GUID: $SchemeGuid" -ForegroundColor Cyan
    } else {
        Write-Error "无法从 '$ActiveSchemeOutput' 中提取有效的 GUID。"
        Read-Host "按 Enter 键退出..."
        Exit 1
    }
} catch {
    Write-Error "获取活动电源计划时出错: $($_.Exception.Message)"
    Read-Host "按 Enter 键退出..."
    Exit 1
}
Write-Host ""

# --- 开始配置电源设置 ---
Write-Host "开始配置电源设置..." -ForegroundColor Yellow

# 1. 设置使计算机进入睡眠状态：从不 (0 分钟)
Write-Host "设置 '在此时间后使计算机进入睡眠状态' 为 '从不'..."
powercfg /change -standby-timeout-ac 0
Write-Host "  - 交流电源 (AC): 已设置为 从不"
powercfg /change -standby-timeout-dc 0
Write-Host "  - 直流电源 (DC): 已设置为 从不"
Write-Host ""

# 2. 在此时间后关闭硬盘：从不 (0 分钟)
Write-Host "设置 '在此时间后关闭硬盘' 为 '从不'..."
powercfg /change -disk-timeout-ac 0
Write-Host "  - 交流电源 (AC): 已设置为 从不"
powercfg /change -disk-timeout-dc 0
Write-Host "  - 直流电源 (DC): 已设置为 从不"
Write-Host ""

# 3. 在此时间后关闭显示器 (默认 20 分钟，设为 0 代表从不)
$MonitorTimeoutMinutes = 20
$MonitorDesc = if ($MonitorTimeoutMinutes -eq 0) { '从不' } else { "$MonitorTimeoutMinutes 分钟" }
Write-Host "设置 '在此时间后关闭显示器' 为 '$MonitorDesc'..."
powercfg /change -monitor-timeout-ac $MonitorTimeoutMinutes
Write-Host "  - 交流电源 (AC): 已设置为 $MonitorDesc"
powercfg /change -monitor-timeout-dc $MonitorTimeoutMinutes
Write-Host "  - 直流电源 (DC): 已设置为 $MonitorDesc"
Write-Host ""

# 4. 在此时间后休眠：从不 (0 分钟)
Write-Host "设置 '在此时间后休眠' 为 '从不'..."
powercfg /change -hibernate-timeout-ac 0
Write-Host "  - 交流电源 (AC): 已设置为 从不"
powercfg /change -hibernate-timeout-dc 0
Write-Host "  - 直流电源 (DC): 已设置为 从不"
Write-Host ""

# 5. 禁用 USB 选择性暂停设置
Write-Host "设置 'USB 选择性暂停设置' 为 '已禁用'..."
$UsbSubgroupGuid = "2a737441-1930-4402-8d77-b2bebba308a3"
$UsbSelectiveSuspendGuid = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"
$ValueDisabled = "0"
powercfg /setacvalueindex $SchemeGuid $UsbSubgroupGuid $UsbSelectiveSuspendGuid $ValueDisabled
Write-Host "  - 交流电源 (AC): 已设置为 已禁用"
powercfg /setdcvalueindex $SchemeGuid $UsbSubgroupGuid $UsbSelectiveSuspendGuid $ValueDisabled
Write-Host "  - 直流电源 (DC): 已设置为 已禁用"
Write-Host ""

# 6. 关闭 PCI Express 链接状态电源管理
Write-Host "设置 'PCI Express - 链接状态电源管理' 为 '关闭'..."
$PciSubgroupGuid = "501a4d13-42af-4429-9fd1-a8218c268e20"
$PciLinkStateGuid = "ee12f90f-d277-404b-b6da-e5fa1a576df5"
$ValueOff = "0"
powercfg /setacvalueindex $SchemeGuid $PciSubgroupGuid $PciLinkStateGuid $ValueOff
Write-Host "  - 交流电源 (AC): 已设置为 关闭"
powercfg /setdcvalueindex $SchemeGuid $PciSubgroupGuid $PciLinkStateGuid $ValueOff
Write-Host "  - 直流电源 (DC): 已设置为 关闭"
Write-Host ""

powercfg /setactive $SchemeGuid
Write-Host "电源设置配置完成。" -ForegroundColor Green
Write-Host "请注意：某些更改可能需要重启计算机才能完全生效。"
Read-Host "按 Enter 键退出..."
