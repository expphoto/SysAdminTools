#!/bin/bash

set -e

USER_HOME="$HOME"
ONEDRIVE_PATH="$USER_HOME/OneDrive"
BACKUP_DIR="$USER_HOME/onedrive_migration_backup_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$USER_HOME/onedrive_migration_$(date +%Y%m%d_%H%M%S).log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

check_onedrive() {
    if [ ! -d "$ONEDRIVE_PATH" ]; then
        log "OneDrive directory not found at $ONEDRIVE_PATH"
        exit 1
    fi
    log "OneDrive found at $ONEDRIVE_PATH"
}

stop_onedrive() {
    log "Stopping OneDrive..."
    pkill -x "OneDrive" 2>/dev/null || true
    pkill -x "OneDrive Finder Integration" 2>/dev/null || true
    sleep 2
    log "OneDrive stopped"
}

disable_onedrive() {
    log "Disabling OneDrive..."
    
    defaults write com.microsoft.OneDrive HasOptedInToOneDrive -bool false 2>/dev/null || true
    defaults write com.microsoft.OneDrive FilesOnDemandEnabled -bool false 2>/dev/null || true
    
    log "OneDrive preferences disabled"
}

backup_config() {
    log "Creating configuration backup at $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    
    if [ -d "$USER_HOME/Library/Application Support/OneDrive" ]; then
        cp -r "$USER_HOME/Library/Application Support/OneDrive" "$BACKUP_DIR/" 2>/dev/null || true
    fi
    
    if [ -d "$USER_HOME/Library/Preferences/com.microsoft.OneDrive.plist" ]; then
        cp "$USER_HOME/Library/Preferences/com.microsoft.OneDrive.plist" "$BACKUP_DIR/" 2>/dev/null || true
    fi
    
    log "Configuration backed up"
}

move_files() {
    log "Moving files from OneDrive to home directory..."
    
    for item in "$ONEDRIVE_PATH"/*; do
        if [ -e "$item" ]; then
            item_name=$(basename "$item")
            target_path="$USER_HOME/$item_name"
            
            if [ -e "$target_path" ]; then
                log "Skipping $item_name - already exists in home directory"
                continue
            fi
            
            log "Moving $item_name..."
            mv "$item" "$target_path"
            
            if [ $? -eq 0 ]; then
                log "Successfully moved $item_name"
            else
                log "Failed to move $item_name"
            fi
        fi
    done
    
    log "File move completed"
}

verify_moves() {
    log "Verifying file moves..."
    
    remaining_count=$(find "$ONEDRIVE_PATH" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
    
    if [ "$remaining_count" -eq 0 ]; then
        log "All files successfully moved from OneDrive"
    else
        log "Warning: $remaining_count items remain in OneDrive"
    fi
}

cleanup_onedrive() {
    log "Cleaning up OneDrive..."
    
    rmdir "$ONEDRIVE_PATH" 2>/dev/null || log "Could not remove OneDrive directory - may still contain files"
    
    log "Cleanup completed"
}

final_summary() {
    log ""
    log "=== MIGRATION SUMMARY ==="
    log "OneDrive has been disabled and files moved to home directory"
    log "Backup location: $BACKUP_DIR"
    log "Log file: $LOG_FILE"
    log ""
    log "Next steps:"
    log "1. Verify all your files are in the correct locations"
    log "2. Remove OneDrive from login items in System Preferences"
    log "3. Uninstall OneDrive if desired"
}

main() {
    log "Starting OneDrive migration..."
    log ""
    
    check_onedrive
    stop_onedrive
    disable_onedrive
    backup_config
    move_files
    verify_moves
    cleanup_onedrive
    final_summary
    
    log ""
    log "Migration completed successfully!"
}

main "$@"