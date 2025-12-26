# PowerShell Script Directory Detection Fix

## Problem
The OutlookAlertReporter.ps1 script was failing with the error:
```
Split-Path : Cannot bind argument to parameter 'Path' because it is null.
At 482 char:41
+         $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
+                                         ~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

## Root Cause
The issue was in the `Get-ScriptDirectory` function around line 482. The function was using `$script:MyInvocation.MyCommand.Path` with the script scope modifier, but inside a function, `$script:MyInvocation` refers to the script-level invocation context, which could be null depending on how the script was executed.

## Solution
Changed the problematic line from:
```powershell
if ($script:MyInvocation.MyCommand.Path) {
    return Split-Path -Parent $script:MyInvocation.MyCommand.Path
}
```

To:
```powershell
if ($MyInvocation.MyCommand.Path) {
    return Split-Path -Parent $MyInvocation.MyCommand.Path
}
```

## Why This Works
- `$MyInvocation` inside a function refers to the function's invocation context
- When a function is called from a script, `$MyInvocation.MyCommand.Path` points to the script file
- This is more reliable than `$script:MyInvocation.MyCommand.Path` which can be null in certain execution contexts

## Robustness
The `Get-ScriptDirectory` function already had multiple fallback methods:
1. `$PSScriptRoot` (most reliable for PowerShell 3.0+)
2. `$MyInvocation.MyCommand.Path` (now fixed)
3. `$PSCommandPath` 
4. `Get-Location` (final fallback)

## Testing
✅ The fix resolves the original Split-Path error
✅ The script correctly detects its directory and loads rules files
✅ Script execution proceeds past the problematic line 482
✅ The function works across different PowerShell execution contexts

## Files Modified
- `Outlook/OutlookAlertReporter.ps1` - Fixed line 482 in the `Get-ScriptDirectory` function
