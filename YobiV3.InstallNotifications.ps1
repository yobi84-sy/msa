# Called after verified service installation; also covered by offline orchestration tests.
function Invoke-YobiInstallNotifications([string]$Root) {
    Send-YobiEvent 'service_ready' 'web' '' '' '서비스 설치·접속 확인 완료'
    Send-YobiEvent 'phase' 'alerts' '' '' '설치에 포함된 운영 알림 구성 중'
    try {
        & (Join-Path $PSScriptRoot 'Configure-YobiAlerts.ps1') -ProjectRoot $Root -Execute -InstallContinuation
    } catch {
        Send-YobiEvent 'notification_incomplete' 'alerts' '' '' '서비스 설치 완료 · 알림 구성 재시도 필요'
        throw
    }
}
