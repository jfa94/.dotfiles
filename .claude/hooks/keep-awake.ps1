# Called by sessionstart-keep-awake.sh. Loops SetThreadExecutionState so
# Windows won't sleep/screen-lock while a Claude Code session is running.
# 12h self-expiry: safety net in case SessionEnd never fires (terminal killed
# outright instead of exiting cleanly) so this doesn't pin the machine awake forever.
$csharp = 'using System; using System.Runtime.InteropServices; public class Sleep { [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags); }'
Add-Type -TypeDefinition $csharp
$ES_CONTINUOUS = [uint32]::Parse('80000000', 'AllowHexSpecifier')
$ES_SYSTEM_REQUIRED = [uint32]::Parse('00000001', 'AllowHexSpecifier')
$flags = $ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED
$maxRuntime = New-TimeSpan -Hours 12
$start = Get-Date
while ((Get-Date) - $start -lt $maxRuntime) {
    [Sleep]::SetThreadExecutionState($flags) | Out-Null
    Start-Sleep -Seconds 60
}
[Sleep]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
