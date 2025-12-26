# Fix for OutlookAlertReporter.ps1 Split-Path Error

## Problem
The script is failing with the error:
```
Split-Path : Cannot bind argument to parameter 'Path' because it is null.
At 482 char:41
+         $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
+                                         ~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

## Root Cause
The `$MyInvocation.MyCommand.Path` automatic variable is null in certain execution contexts, particularly when:
- Script is run from certain PowerShell environments
- Script is called in specific ways (e.g., dot-sourced, piped input, etc.)

## Solution
Create a robust function to get the script directory that works in all execution contexts by trying multiple methods in order of reliability:

1. `$PSScriptRoot` - Most reliable (PowerShell 3.0+)
2. `$script:MyInvocation.MyCommand.Path` - Current method (can be null)
3. `$PSCommandPath` - Alternative automatic variable
4. `Get-Location` - Final fallback to current directory

## Implementation Details

### New Function to Add
```powershell
function Get-ScriptDirectory {
    # Robust function to get script directory in all execution contexts
    # Try multiple methods in order of reliability
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }
    
    if ($script:MyInvocation.MyCommand.Path) {
        return Split-Path -Parent $script:MyInvocation.MyCommand.Path
    }
    
    if ($PSCommandPath) {
        return Split-Path -Parent $PSCommandPath
    }
    
    # Final fallback to current directory
    return Get-Location
}
```

### Changes to Load-AlertRules Function
Replace line 482:
```powershell
# OLD:
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# NEW:
$scriptDir = Get-ScriptDirectory
```

## Testing Scenarios
The fix should work in:
1. Normal script execution: `.\OutlookAlertReporter.ps1`
2. Non-interactive mode: `.\OutlookAlertReporter.ps1 -NonInteractive`
3. With parameters: `.\OutlookAlertReporter.ps1 -WhatIf -Verbose`
4. From different directories
5. From PowerShell ISE
6. From VS Code PowerShell terminal
7. From other PowerShell hosts

## Benefits
1. More robust script that works in all execution contexts
2. Better error handling with fallbacks
3. Maintains backward compatibility
4. No breaking changes to existing functionality