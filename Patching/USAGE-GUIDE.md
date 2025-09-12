# Patching Automation Scripts - Usage Guide

## 📁 Files in This Directory

### 🚀 **PRODUCTION SCRIPTS**

#### `interactive-patching-automation.ps1` ⭐ **RECOMMENDED**
**The ultimate solution for your use case**
- **Interactive paste mode** - Perfect for copy/pasting server lists from multiple sources
- **Intelligent parsing** - Handles any format (hostnames, IPs, mixed text, CSV, reports)
- **Domain authentication** - Single credential prompt for all servers
- **Continuous operation** - Keeps running until ALL systems are clean
- **Comprehensive reporting** - Detailed logs and CSV exports

**Usage:**
```powershell
.\interactive-patching-automation.ps1
# Then paste your server list when prompted
# Enter domain credentials once
# Script handles everything else automatically
```

**Unattended usage (`-Auto`):**
```powershell
# Inline servers
.\interactive-patching-automation.ps1 -Auto -Servers 'srv1','srv2' -Username 'CONTOSO\\svc_patch' -Password 'P@ssw0rd!'

# Servers from file
.\interactive-patching-automation.ps1 -Auto -Servers .\servers-example.txt -Username 'CONTOSO\\svc_patch' -Password 'P@ssw0rd!'
```
Notes:
- Auto mode skips prompts and final pause; suitable for scheduled runs.
- Auto mode enables Windows Update repair on failure automatically.
- With `-AutoRebootOnHang`, the script reboots targets that show no Windows Update progress for the threshold window (default 45 minutes). You can tune with `-HangThresholdMinutes`.

#### `simple-patching-automation.ps1` 
**Streamlined version for direct server list input**
- **Command-line parameters** - Specify servers directly
- **Single domain login** - Same credentials for all servers
- **Continuous retry** - Runs until systems are clean
- **Clean reporting** - CSV and log outputs

**Usage:**
```powershell
.\simple-patching-automation.ps1 -ComputerList "server1","server2","192.168.1.100" -Username "domain\user" -Password "password"
```

#### `needs-attention-fix.ps1`
**Original enhanced script** (preserved for compatibility)
- **Paste mode** - Traditional "needs attention" report processing
- **Manual credential prompts** - Interactive authentication
- **Comprehensive analysis** - Detailed system checking
- **CSV export** - Results and logging

### 📋 **REFERENCE FILES**

#### `servers-example.txt`
Example server list format for testing

#### `README.md` 
Detailed documentation for all features and options

#### `USAGE-GUIDE.md`
This file - quick reference guide

---

## 🎯 **Recommended Workflow**

### For Your Scenario (Multiple paste operations, domain environment):

1. **Use `interactive-patching-automation.ps1`**
2. **Run the script:**
   ```powershell
   .\interactive-patching-automation.ps1
   ```
3. **Paste your server data** (any format):
   - Copy from "needs attention" reports
   - Copy from spreadsheets
   - Copy mixed hostname/IP lists
   - Multiple paste operations supported
4. **Enter domain credentials once**
5. **Let it run continuously until all systems are clean**

### Quick Test Mode:
```powershell
.\interactive-patching-automation.ps1 -QuickTest
```

### Safe Testing:
```powershell  
.\interactive-patching-automation.ps1 -TestMode
```

---

## 🔧 **What The Scripts Do Automatically**

✅ **System Analysis:**
- Health scoring (0-100)
- Windows Update status
- Pending reboot detection
- Disk space checking
- Service status validation

✅ **Automatic Remediation:**
- Windows Update installation
- System reboots when required
- Disk space cleanup (temp files, logs, WU cache)
- Windows Update service repair
- Error detection and resolution

✅ **Continuous Operation:**
- Runs multiple cycles until ALL systems are healthy
- Configurable retry intervals
- Progress tracking and reporting
- Automatic retry of failed operations

✅ **Comprehensive Reporting:**
- Real-time console logging with color coding
- Detailed log files with timestamps
- CSV exports for analysis and documentation
- Final summary reports with statistics

---

## 🎉 **Success Criteria**

The scripts will keep running until all reachable servers show:
- **Status:** "Excellent", "VeryGood", or "Good"
- **Health Score:** 70+ out of 100
- **Updates:** All available updates installed
- **Reboot:** No pending reboots
- **Disk Space:** Adequate free space
- **Services:** All critical services running

---

## 💡 **Pro Tips**

1. **Always test first:** Use `-TestMode` to validate without making changes
2. **Use domain credentials:** Most efficient for multiple servers
3. **Let it run overnight:** Set high MaxCycles for large environments
4. **Check the logs:** Detailed execution information in log files
5. **Save the CSV:** Perfect for management reporting and documentation

---

*Created by Claude Code Assistant - Automated Patching Remediation Solution*
